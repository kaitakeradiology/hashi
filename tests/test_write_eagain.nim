## A large response survives a client that half-closes its end, without
## costing a thread or a spin per stalled client.
##
## On io_uring a ring write on an `O_NONBLOCK` socket completes with -EAGAIN
## once the peer has half-closed and the send buffer is full; a caller that
## reads that as "peer gone" truncates the response and ends it with a clean
## EOF. `waitWrite` instead waits for writability and retries. A poll on such
## a socket can wake at once with only the peer's half-close, no writability,
## so the retry backs off (1 ms doubling to 1 s) rather than spinning.
##
## Each scenario runs real `serve` on a loopback port, with the client as the
## boot task on the same loop. The client reads until the server closes and
## checks that every byte arrived. The HTTP scenarios send a GET for a 32 MiB
## body, half-closing after the request or not; the WebSocket scenario sends
## one message, half-closes, and expects one 8 MiB binary message back.
##
## The stall scenario half-closes and then does not read for 3 s. Over the
## stall it bounds the write retries (`writeRetriesTotal`), which a retry loop
## that does not back off would run up, and reports the process's CPU time.
##
## The thread scenario half-closes 48 clients that do not read, waits, and
## counts the process's `iou-wrk` threads: a blocking socket's write is handed
## to an io-wq kernel thread that waits as long as the peer does, one thread
## per stalled client. The count must stay within one per ring, however many
## clients stall. Then every
## client reads to the end and gets its whole body.
##
## The socket-mode scenario asks the server's accepted socket for its
## `O_NONBLOCK` flag: set on both backends. The pipe scenario runs
## `readNow`, `writeNow` and `writevNow` on a non-socket fd.
##
## The contention scenarios make the ring complete an op with -EAGAIN
## without any half-close: two reads parked on one pipe are both woken by
## one byte, and the one that loses the race finds nothing; two writes
## parked on a full pipe are both woken by one page of room, and the loser
## finds none. `waitRead` and `waitWrite` must each return the byte count
## from the next wake, never the -EAGAIN.
import std/[syncio, strutils, atomics]
from std/posix/posix import Sockaddr_in, SockLen
import hashi
import hashi/buffer
import hashi/ws/frame
import testkit

proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
proc cFcntl(fd, cmd: cint; arg: cint): cint {.importc: "fcntl", header: "<fcntl.h>".}
proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cBind(fd: cint; sa: pointer; len: SockLen): cint {.importc: "bind", header: "<sys/socket.h>".}
proc cGetsockname(fd: cint; sa: pointer; len: ptr SockLen): cint {.
  importc: "getsockname", header: "<sys/socket.h>".}
proc cShutdown(fd: cint; how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
proc cHtons(x: uint16): uint16 {.importc: "htons", header: "<arpa/inet.h>".}
proc cNtohs(x: uint16): uint16 {.importc: "ntohs", header: "<arpa/inet.h>".}
proc cHtonl(x: uint32): uint32 {.importc: "htonl", header: "<arpa/inet.h>".}
proc cPipe(fds: pointer): cint {.importc: "pipe", header: "<unistd.h>".}
proc cOpen(path: cstring; flags: cint): cint {.importc: "open", header: "<fcntl.h>".}
proc cRead(fd: cint; buf: pointer; n: csize_t): int {.importc: "read", header: "<unistd.h>".}
proc cReadlink(path: cstring; buf: pointer; n: csize_t): int {.importc: "readlink", header: "<unistd.h>".}
proc cGetpeername(fd: cint; sa: pointer; len: ptr SockLen): cint {.
  importc: "getpeername", header: "<sys/socket.h>".}
proc cGetrusage(who: cint; ru: pointer): cint {.importc: "getrusage", header: "<sys/resource.h>".}
proc cOpendir(path: cstring): pointer {.importc: "opendir", header: "<dirent.h>".}
proc cReaddir(d: pointer): pointer {.importc: "readdir", header: "<dirent.h>".}
proc cClosedir(d: pointer): cint {.importc: "closedir", header: "<dirent.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a scenario that never sees its EOF fails the run instead
  ## of hanging it.

const ShutWr = 1.cint
const AfInet = 2.cint
const SockStream = 1.cint
const IpprotoTcp = 6.cint
const FGetfl = 3.cint
const FSetfl = 4.cint
const ONonblock = 0o4000.cint
const Loopback = 0x7F000001'u32

const HttpBody = 32 * 1024 * 1024   ## the 32 MiB response body
const WsBody = 8 * 1024 * 1024      ## the 8 MiB binary message
const MidBody = 8 * 1024 * 1024     ## the thread scenario's response body
const StallMs = 3000                ## how long the stall client does not read
const StallRetryCap = 20            ## write retries allowed over the stall
const Clients = 48                  ## stalled clients in the thread scenario
const ThreadSettleMs = 1500         ## how long they stall before the count
const ThreadSlack = 2               ## `iou-wrk` threads allowed beyond one per ring

proc loopbackAddr(port: uint16): Sockaddr_in =
  result = default(Sockaddr_in)
  result.sin_family = uint16(AfInet)
  result.sin_port = cHtons(port)
  result.sin_addr.s_addr = cHtonl(Loopback)

proc freePort(): uint16 =
  result = 0'u16
  let fd = cSocket(AfInet, SockStream, IpprotoTcp)
  if fd >= 0:
    var a = loopbackAddr(0'u16)
    if cBind(fd, addr a, SockLen(sizeof(a))) == 0:
      var got = default(Sockaddr_in)
      var len = SockLen(sizeof(got))
      if cGetsockname(fd, addr got, addr len) == 0:
        result = cNtohs(got.sin_port)
    discard cClose(fd)

var gPort = 0'u16

proc dial(): cint =
  ## A blocking client socket connected to the server.
  result = cSocket(AfInet, SockStream, IpprotoTcp)
  if result >= 0:
    var a = loopbackAddr(gPort)
    if cConnect(result, addr a, SockLen(sizeof(a))) != 0:
      discard cClose(result)
      result = -1

proc filled(n: int; c: char): string =
  result = newString(n)
  var i = 0
  while i < n:
    result[i] = c
    i = i + 1

type Client = ref object
  fd: cint
  acc: string
  rbuf: array[65536, byte]

proc readAll(c: Client) {.passive.} =
  ## Read into `c.acc` until the server closes or the read fails.
  var more = true
  while more:
    let n = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
    if n > 0: appendBytes(c.acc, addr c.rbuf[0], n)
    else: more = false

proc clientFrame(op: Opcode; payload: string): string =
  ## A masked client frame with a zero mask key, payload under 126 bytes.
  result = ""
  result.add char(0x80 or ord(op))
  result.add char(0x80 or payload.len)
  var k = 0
  while k < 4:
    result.add char(0)
    k = k + 1
  result.add payload

proc contentLengthOf(head: string): int =
  ## The `Content-Length` value in `head`, or -1.
  result = -1
  let at = find(head, "\r\nContent-Length: ")
  if at >= 0:
    var i = at + 18
    result = 0
    while i < head.len and head[i] >= '0' and head[i] <= '9':
      result = result * 10 + (ord(head[i]) - ord('0'))
      i = i + 1

proc readBody(c: Client) {.passive.} =
  ## Read into `c.acc` until the response head and its `Content-Length` body
  ## are all in, or the read fails: a keep-alive connection sends no EOF.
  var more = true
  while more:
    let n = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
    if n > 0:
      appendBytes(c.acc, addr c.rbuf[0], n)
      let e = find(c.acc, "\r\n\r\n")
      if e >= 0:
        let want = contentLengthOf(substr(c.acc, 0, e + 3))
        if want >= 0 and c.acc.len - (e + 4) >= want: more = false
    else: more = false

proc checkBody(c: Client) =
  let e = find(c.acc, "\r\n\r\n")
  check e >= 0 and startsWith(c.acc, "HTTP/1.1 200"), "answered 200"
  let want = contentLengthOf(if e >= 0: substr(c.acc, 0, e + 3) else: "")
  check want == HttpBody, "Content-Length is " & $want
  let got = if e >= 0: c.acc.len - (e + 4) else: 0
  check got == HttpBody, "received " & $got & " of " & $HttpBody & " body bytes"

proc httpScenario(what: string; halfClose: bool) {.passive.} =
  section what
  let c = Client(fd: dial(), acc: "")
  discard writeAll(c.fd, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
  if halfClose:
    discard cShutdown(c.fd, ShutWr)
    # Not reading yet lets the server fill the socket buffers and park its
    # write with the FIN already in.
    sleepMs(300)
    readAll(c)
  else:
    readBody(c)
    discard cShutdown(c.fd, ShutWr)
  discard cClose(c.fd)
  checkBody(c)

proc slurp(path: string): string =
  ## The bytes of a small procfs file, or "".
  result = ""
  var p = path
  let fd = cOpen(toCString(p), 0.cint)
  if fd >= 0:
    var buf {.noinit.}: array[4096, byte]
    let n = cRead(fd, addr buf[0], csize_t(buf.len))
    if n > 0: appendBytes(result, addr buf[0], n)
    discard cClose(fd)

const DirentName = 19  ## offset of `d_name` in Linux's `struct dirent`

proc ringCount(): int =
  ## How many io_uring instances this process holds open: 0 on the epoll backend.
  result = 0
  var fd = 3
  while fd < 256:
    var link {.noinit.}: array[64, char]
    var lp = "/proc/self/fd/" & $fd
    let n = cReadlink(toCString(lp), addr link[0], csize_t(link.len))
    if n == 21:
      var name = ""
      appendBytes(name, addr link[0], n)
      if name == "anon_inode:[io_uring]": result = result + 1
    fd = fd + 1

proc ioWqThreads(): int =
  ## How many of this process's threads are io-wq kernel workers (`iou-wrk`).
  result = 0
  var dir = "/proc/self/task"
  let d = cOpendir(toCString(dir))
  if d != nil:
    var e = cReaddir(d)
    while e != nil:
      let nm = cast[ptr UncheckedArray[char]](e)
      var tid = ""
      var i = DirentName
      while nm[i] != '\0' and nm[i] != '.':
        tid.add nm[i]
        i = i + 1
      if tid.len > 0:
        let comm = slurp("/proc/self/task/" & tid & "/comm")
        if startsWith(comm, "iou-wrk"): result = result + 1
      e = cReaddir(d)
    discard cClosedir(d)

proc cpuMicros(): int =
  ## User plus system CPU time of this process so far, in microseconds.
  ## `struct rusage` opens with two `struct timeval`s: utime, then stime.
  var ru {.noinit.}: array[18, int]
  result = 0
  if cGetrusage(0.cint, addr ru[0]) == 0:
    result = ru[0] * 1_000_000 + ru[1] + ru[2] * 1_000_000 + ru[3]

proc stallScenario() {.passive.} =
  section "a 32 MiB response to a client that half-closed and stalled"
  let c = Client(fd: dial(), acc: "")
  discard writeAll(c.fd, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
  discard cShutdown(c.fd, ShutWr)
  # Let the server fill the socket buffers and park its write first.
  sleepMs(500)
  let before = writeRetriesTotal()
  let cpuBefore = cpuMicros()
  sleepMs(StallMs)
  let retries = writeRetriesTotal() - before
  let cpu = cpuMicros() - cpuBefore
  check retries <= StallRetryCap,
        "write retries over a " & $StallMs & " ms stall: " & $retries &
        " (cap " & $StallRetryCap & ")"
  # Process CPU includes the worker pool's idle cost and the host's load, so
  # it is reported, not asserted; the retry count is what catches a spin.
  echo "  CPU over a ", StallMs, " ms stall: ", cpu, " us"
  readAll(c)
  discard cClose(c.fd)
  checkBody(c)

proc threadScenario() {.passive.} =
  section $Clients & " stalled half-closed clients"
  let base = ioWqThreads()
  var cs = newSeq[Client]()
  var i = 0
  while i < Clients:
    let c = Client(fd: dial(), acc: "")
    discard writeAll(c.fd, "GET /mid HTTP/1.1\r\nHost: localhost\r\n\r\n")
    discard cShutdown(c.fd, ShutWr)
    cs.add c
    i = i + 1
  sleepMs(ThreadSettleMs)
  let extra = ioWqThreads() - base
  let rings = ringCount()
  let total = base + extra
  # An io-wq keeps one idle worker resident per ring once it has run any
  # punted op, so the bound is the ring count; a stalled blocking write adds a
  # thread each, past it.
  let allowed = if rings > 0: rings + ThreadSlack else: 0
  writeLine(stdout, "  iou-wrk threads: " & $base & " before, " & $total &
            " with " & $Clients & " clients stalled (" & $rings & " rings)")
  check total <= allowed, "iou-wrk threads with " & $Clients & " clients stalled: " &
        $total & " (allowed " & $allowed & ")"
  i = 0
  while i < Clients:
    let c = cs[i]
    readAll(c)
    discard cClose(c.fd)
    let e = find(c.acc, "\r\n\r\n")
    let got = if e >= 0: c.acc.len - (e + 4) else: 0
    check e >= 0 and startsWith(c.acc, "HTTP/1.1 200") and got == MidBody,
          "client " & $i & " received " & $got & " of " & $MidBody & " body bytes"
    c.acc = ""
    i = i + 1

proc wsScenario() {.passive.} =
  section "a WebSocket message sent to a client that half-closed"
  let c = Client(fd: dial(), acc: "")
  discard writeAll(c.fd,
    "GET /ws HTTP/1.1\r\nHost: localhost\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n" & clientFrame(opText, "go"))
  discard cShutdown(c.fd, ShutWr)
  # Not reading yet lets the server fill the socket buffers and park its write
  # with the FIN already in.
  sleepMs(300)
  readAll(c)
  discard cClose(c.fd)
  let e = find(c.acc, "\r\n\r\n")
  check e >= 0 and startsWith(c.acc, "HTTP/1.1 101"), "upgraded"
  var f = default(Frame)
  let r = parseFrame(c.acc, e + 4, f, 1 shl 30)
  check r[0] == psOk, "the binary message arrived whole (" &
        $(c.acc.len - e - 4) & " bytes after the head)"
  check f.opcode == opBinary and f.payload.len == WsBody,
        "message is " & $f.payload.len & " of " & $WsBody & " bytes"

var gServerFlags = -1   ## the accepted socket's `fcntl(F_GETFL)`, from `/flags`

proc acceptedFlags(): int =
  ## `F_GETFL` of a connected socket whose local port is the server's: the
  ## accepted side of the request in flight. -1 when there is none.
  result = -1
  var fd = 3
  while fd < 256:
    var sa = default(Sockaddr_in)
    var len = SockLen(sizeof(sa))
    if cGetpeername(fd.cint, addr sa, addr len) == 0:
      var me = default(Sockaddr_in)
      var mlen = SockLen(sizeof(me))
      if cGetsockname(fd.cint, addr me, addr mlen) == 0 and
         cNtohs(me.sin_port) == gPort:
        result = int(cFcntl(fd.cint, FGetfl, 0.cint))
    fd = fd + 1

proc modeScenario() {.passive.} =
  section "the accepted socket's mode"
  let c = Client(fd: dial(), acc: "")
  discard writeAll(c.fd, "GET /flags HTTP/1.1\r\nHost: localhost\r\n\r\n")
  readBody(c)
  discard cClose(c.fd)
  check gServerFlags >= 0, "found the accepted socket"
  check (gServerFlags and int(ONonblock)) != 0, "accepted sockets are O_NONBLOCK"

proc pipeScenario() =
  section "readNow, writeNow and writevNow on a pipe"
  var fds = default(array[2, cint])
  check cPipe(addr fds[0]) == 0, "pipe"
  discard cFcntl(fds[0], FSetfl, cFcntl(fds[0], FGetfl, 0.cint) or ONonblock)
  discard cFcntl(fds[1], FSetfl, cFcntl(fds[1], FGetfl, 0.cint) or ONonblock)
  var buf {.noinit.}: array[64, byte]
  check readNow(fds[0], addr buf[0], buf.len) == ReadLater, "an empty pipe reads ReadLater"
  check writeNow(fds[1], "hello", 0) == 5, "writeNow writes to a pipe"
  var got = ""
  let n = readNow(fds[0], addr buf[0], buf.len)
  check n == 5, "readNow reads from a pipe"
  if n > 0: appendBytes(got, addr buf[0], n)
  check got == "hello", "the bytes match"
  var head = [byte('a'), byte('b')]
  check writevNow(fds[1], addr head[0], 2, "cdef") == 6, "writevNow writes to a pipe"
  let m = readNow(fds[0], addr buf[0], buf.len)
  var got2 = ""
  if m > 0: appendBytes(got2, addr buf[0], m)
  check got2 == "abcdef", "the gathered bytes match"
  discard cClose(fds[1])
  check readNow(fds[0], addr buf[0], buf.len) == 0, "a closed pipe reads 0"
  discard cClose(fds[0])
  check writeNow(fds[0], "x", 0) == -1, "a closed fd writes -1"

const ReadRaceSettleMs = 100   ## for both parked ops to be in the kernel
const RaceJoinMs = 5000        ## most time a contention scenario waits to join

var gRaceRes: array[2, int]    ## accessed atomically: each task's wait result
var gRaceByte: array[2, int]   ## accessed atomically: the byte each read got
var gRaceDone: int             ## accessed atomically: tasks finished

proc setNonBlock(fd: cint) =
  discard cFcntl(fd, FSetfl, cFcntl(fd, FGetfl, 0.cint) or ONonblock)

proc awaitRace() {.passive.} =
  ## Wait for both tasks of a contention scenario, up to `RaceJoinMs`.
  var waited = 0
  while atomicLoad(gRaceDone) < 2 and waited < RaceJoinMs:
    sleepMs(50)
    waited = waited + 50

proc pipeReader(fd: cint; i: int) {.passive.} =
  var b = 0'u8
  let n = waitRead(fd, addr b, 1)
  atomicStore(gRaceByte[i], int(b))
  atomicStore(gRaceRes[i], n)
  discard atomicFetchAdd(gRaceDone, 1)

proc readRaceScenario() {.passive.} =
  section "two reads parked on one pipe"
  var fds = default(array[2, cint])
  check cPipe(addr fds[0]) == 0, "pipe"
  setNonBlock(fds[0])
  setNonBlock(fds[1])
  atomicStore(gRaceDone, 0)
  atomicStore(gRaceRes[0], -99)
  atomicStore(gRaceRes[1], -99)
  spawnTask pipeReader(fds[0], 0)
  spawnTask pipeReader(fds[0], 1)
  sleepMs(ReadRaceSettleMs)
  check writeNow(fds[1], "a", 0) == 1, "the first byte is written"
  sleepMs(ReadRaceSettleMs)   # one read took it; the other was woken for nothing
  check atomicLoad(gRaceDone) == 1, "one read returned on the first byte"
  check writeNow(fds[1], "b", 0) == 1, "the second byte is written"
  awaitRace()
  let r0 = atomicLoad(gRaceRes[0])
  let r1 = atomicLoad(gRaceRes[1])
  check atomicLoad(gRaceDone) == 2, "both reads returned"
  check r0 == 1 and r1 == 1,
        "each read returned one byte, never -EAGAIN (" & $r0 & ", " & $r1 & ")"
  let b0 = atomicLoad(gRaceByte[0])
  let b1 = atomicLoad(gRaceByte[1])
  check (b0 == int('a') and b1 == int('b')) or (b0 == int('b') and b1 == int('a')),
        "the reads got one byte each (" & $b0 & ", " & $b1 & ")"
  closeFd(fds[0])
  closeFd(fds[1])

const RaceChunk = 4096   ## at most `PIPE_BUF`: a pipe takes it whole or not at all

proc pipeWriter(fd: cint; i: int) {.passive.} =
  var buf {.noinit.}: array[RaceChunk, char]
  var k = 0
  while k < RaceChunk:
    buf[k] = 'w'
    k = k + 1
  let n = waitWrite(fd, addr buf[0], RaceChunk)
  atomicStore(gRaceRes[i], n)
  discard atomicFetchAdd(gRaceDone, 1)

proc drainPipe(fd: cint): int =
  ## Read and count what the pipe holds, up to `n` bytes per read.
  result = 0
  var buf {.noinit.}: array[RaceChunk, byte]
  var going = true
  while going:
    let n = readNow(fd, addr buf[0], buf.len)
    if n > 0: result = result + n
    else: going = false

proc writeRaceScenario() {.passive.} =
  section "two writes parked on a full pipe"
  var fds = default(array[2, cint])
  check cPipe(addr fds[0]) == 0, "pipe"
  setNonBlock(fds[0])
  setNonBlock(fds[1])
  # Fill the pipe to its capacity, whatever that is here.
  let filler = filled(1 shl 20, 'f')
  let filledBytes = writeNow(fds[1], filler, 0)
  check filledBytes > 0 and filledBytes < filler.len, "the pipe is full at " & $filledBytes & " bytes"
  check writeNow(fds[1], "x", 0) == 0, "a full pipe takes nothing"
  atomicStore(gRaceDone, 0)
  atomicStore(gRaceRes[0], -99)
  atomicStore(gRaceRes[1], -99)
  let before = writeRetriesTotal()
  spawnTask pipeWriter(fds[1], 0)
  spawnTask pipeWriter(fds[1], 1)
  sleepMs(ReadRaceSettleMs)
  check atomicLoad(gRaceDone) == 0, "both writes are parked on the full pipe"
  var buf {.noinit.}: array[RaceChunk, byte]
  var got = readNow(fds[0], addr buf[0], buf.len)   # one page of room: one write fits
  check got == RaceChunk, "read one page from the pipe"
  sleepMs(ReadRaceSettleMs)   # one write took the room; the other was woken for nothing
  check atomicLoad(gRaceDone) == 1, "one write returned on the first page of room"
  got = got + readNow(fds[0], addr buf[0], buf.len)  # room for the other
  awaitRace()
  let r0 = atomicLoad(gRaceRes[0])
  let r1 = atomicLoad(gRaceRes[1])
  check atomicLoad(gRaceDone) == 2, "both writes returned"
  check r0 == RaceChunk and r1 == RaceChunk,
        "each write returned its " & $RaceChunk & " bytes, never -EAGAIN (" & $r0 & ", " & $r1 & ")"
  got = got + drainPipe(fds[0])
  check got == filledBytes + 2 * RaceChunk,
        "the pipe delivered " & $got & " of " & $(filledBytes + 2 * RaceChunk) & " bytes"
  echo "  write retries: ", writeRetriesTotal() - before
  closeFd(fds[0])
  closeFd(fds[1])

proc runAll() {.passive.} =
  pipeScenario()
  readRaceScenario()
  writeRaceScenario()
  modeScenario()
  httpScenario("a 32 MiB response to a client that half-closed", true)
  stallScenario()
  threadScenario()
  httpScenario("a 32 MiB response to a client that did not (control)", false)
  wsScenario()
  finish()

proc big(req: Request): Response {.nimcall, raises.} =
  newResponse(200, filled(HttpBody, 'x'))

proc mid(req: Request): Response {.nimcall, raises.} =
  newResponse(200, filled(MidBody, 'x'))

proc flagsRoute(req: Request): Response {.nimcall, raises.} =
  gServerFlags = acceptedFlags()
  newResponse(200, "ok")

proc onWs(ws: WsConn) {.passive.} =
  discard wsRecv(ws)
  discard wsSend(ws, filled(WsBody, 'y'), true)

discard cAlarm(120)
gPort = freePort()
if gPort == 0'u16:
  writeLine(stderr, "test_write_eagain: no free loopback port")
  quit(1)
get("/big", big)
get("/mid", mid)
get("/flags", flagsRoute)
setWsHandler(onWs)
setBootTask(runAll)
serve(gPort, defaultServerConfig(), bindAddr = "127.0.0.1")

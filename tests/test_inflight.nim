## The in-flight byte count (`hashi/http/connreg`'s `inflightBytes`) returns
## to where it started after every way a connection can end.
##
## The acceptor refuses new connections once the count reaches
## `ServerConfig.maxInflightBytes`, so a path that adds bytes and never
## subtracts them drifts the count up until the server refuses everything.
## Each scenario below drives the real server end to end: `serve` runs on a
## loopback port, and the client half runs as the boot task on the same
## loop, one connection at a time. A scenario reads until the server closes
## the connection (EOF) before checking the count, because the driver
## subtracts before it closes.
##
## A WebSocket message arriving in fragments is counted while it is being
## assembled: after its first fragment the count stands at the payload
## buffered so far, and it drops back once the message is delivered, refused
## or abandoned.
##
## A rejection the client may still be sending into (413, 431, the origin
## 403, a claimed upgrade with bytes behind it) is followed by a lingering
## close: the client reads the whole response and then EOF, never a reset.
## The linger scenarios watch `lingeringNow` and `lingerClosedTotal` to time
## how long the server lingers against a trickling, a silent and a flooding
## client, and that the cap on lingering connections holds.
import std/[syncio, strutils, opt, monotimes, times, atomics]
from std/posix/posix import Sockaddr_in, SockLen
import hashi
import hashi/buffer
import hashi/http/connreg
import hashi/net             # openFileLimit
import hashi/http/request    # ParseStatus
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
proc cWrite(fd: cint; buf: pointer; n: csize_t): int {.importc: "write", header: "<unistd.h>".}
var cErrno {.importc: "errno", header: "<errno.h>".}: cint
const EAGAIN = 11.cint
const EINTR = 4.cint
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

const MaxBody = 1024        ## `maxBodySize` for the run: the 413 scenario's cap
const MaxHead = 2048        ## `maxRequestHead`: the 431 scenario's cap
const MaxMessage = 4096     ## `maxWsMessage`: the 1009 scenario's cap
const LingerMs = 600        ## `lingerMs`: the longest a rejected connection lingers
const LingerIdleMs = 200    ## `lingerIdleMs`: the longest it waits on a silent client
const Slack = 250           ## timing tolerance on a loaded machine, in ms
const ECONNRESET = 104

# ── sockets ─────────────────────────────────────────────────────────────

proc loopbackAddr(port: uint16): Sockaddr_in =
  result = default(Sockaddr_in)
  result.sin_family = uint16(AfInet)
  result.sin_port = cHtons(port)
  result.sin_addr.s_addr = cHtonl(Loopback)

proc freePort(): uint16 =
  ## A loopback port the kernel just handed out, for `serve` to bind.
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
  ## A non-blocking client socket connected to the server. Loopback connects
  ## complete in the kernel's backlog, so the blocking connect cannot stall.
  result = cSocket(AfInet, SockStream, IpprotoTcp)
  if result >= 0:
    var a = loopbackAddr(gPort)
    if cConnect(result, addr a, SockLen(sizeof(a))) != 0:
      discard cClose(result)
      result = -1
    else:
      let flags = cFcntl(result, FGetfl, 0.cint)
      discard cFcntl(result, FSetfl, flags or ONonblock)

# ── the client half ─────────────────────────────────────────────────────

type Client = ref object
  fd: cint
  acc: string                ## bytes read and not yet taken
  eof: bool                  ## the server closed its end, or the read failed
  endErr: int                ## the read that set `eof`: 0 for EOF, else -errno
  sendErr: int               ## the first failed `sendAll` write's -errno, else 0
  frame: Frame               ## the frame `nextFrame` last took
  rbuf: array[4096, byte]
  wbuf: array[4096, byte]

proc noFrame(): Frame =
  ## What `readFrame` answers when the server closed first.
  result = Frame(fin: true, opcode: opClose, masked: false, payload: "")

proc newClient(): Client =
  result = Client(fd: dial(), acc: "", eof: false, endErr: 0, sendErr: 0,
                  frame: noFrame())

proc readSome(c: Client): bool {.passive.} =
  ## One read into `c.acc`; false once the server has closed or the read
  ## failed, with the read's result in `c.endErr`.
  let n = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
  if n > 0:
    appendBytes(c.acc, addr c.rbuf[0], n)
    result = true
  else:
    c.eof = true
    c.endErr = n
    result = false

proc readToEof(c: Client) {.passive.} =
  ## Read until the server closes the connection.
  while not c.eof:
    discard readSome(c)

proc readHead(c: Client): string {.passive.} =
  ## Read one response head (through its blank line) and take it from
  ## `c.acc`; "" when the server closed first.
  result = ""
  var at = find(c.acc, "\r\n\r\n")
  while at < 0 and not c.eof:
    discard readSome(c)
    at = find(c.acc, "\r\n\r\n")
  if at >= 0:
    result = substr(c.acc, 0, at + 3)
    dropPrefix(c.acc, at + 4)

proc nextFrame(c: Client): bool =
  ## Take one complete server frame off `c.acc` into `c.frame`.
  var g = default(Frame)
  let r = parseFrame(c.acc, 0, g, 1 shl 30)
  result = r[0] == psOk
  if result:
    dropPrefix(c.acc, r[1])
    c.frame = g

proc readFrame(c: Client): Frame {.passive.} =
  ## The next server frame; `noFrame()` when the server closed first.
  var got = nextFrame(c)
  while not got and not c.eof:
    discard readSome(c)
    got = nextFrame(c)
  result = if got: c.frame else: noFrame()

proc send(c: Client; s: string) {.passive.} =
  discard writeAll(c.fd, s)

proc writeOnce(c: Client; s: string; off: int): int =
  ## One write(2) of `s[off ..]`: the bytes taken, 0 when the socket buffer
  ## is full, or -errno.
  let n = min(s.len - off, c.wbuf.len)
  copyOut(addr c.wbuf[0], s, off, n)
  let r = cWrite(c.fd, addr c.wbuf[0], csize_t(n))
  result = if r >= 0: int(r)
           elif cErrno == EAGAIN or cErrno == EINTR: 0
           else: -int(cErrno)

proc sendAll(c: Client; s: string) {.passive.} =
  ## Write all of `s` with plain write(2), keeping the first failure's -errno
  ## in `c.sendErr`. The kernel reports a reset once, to whichever call meets
  ## it first, so a write can take the ECONNRESET a later read would
  ## otherwise see. Not through the ring: a write parked there for buffer
  ## space can surface the reset as EPIPE instead.
  var off = 0
  while off < s.len and c.sendErr == 0:
    let r = writeOnce(c, s, off)
    if r < 0: c.sendErr = r
    elif r == 0: sleepMs(1)
    else: off = off + r

proc finishClient(c: Client) {.passive.} =
  ## Half-close our end, read until the server closes its own, then close.
  discard cShutdown(c.fd, ShutWr)
  readToEof(c)
  discard cClose(c.fd)

proc settle(want: int64): int64 {.passive.} =
  ## `inflightBytes()` once it equals `want`, or its value after 2 s of
  ## waiting: the server parses what the client sent on its own task.
  result = inflightBytes()
  var waited = 0
  while result != want and waited < 2000:
    sleepMs(5)
    waited = waited + 5
    result = inflightBytes()

# ── messages ────────────────────────────────────────────────────────────

proc clientFrame(op: Opcode; payload: string; fin = true): string =
  ## A masked client frame. The mask key is zero, so the payload goes out as
  ## is; the server still sees MASK set, as RFC 6455 requires.
  result = ""
  let b0 = (if fin: 0x80 else: 0x00) or ord(op)
  result.add char(b0)
  if payload.len < 126:
    result.add char(0x80 or payload.len)
  else:
    result.add char(0x80 or 126)
    result.add char((payload.len shr 8) and 0xFF)
    result.add char(payload.len and 0xFF)
  var k = 0
  while k < 4:
    result.add char(0)
    k = k + 1
  result.add payload

proc upgradeRequest(path: string; origin = ""): string =
  result = "GET " & path & " HTTP/1.1\r\nHost: localhost\r\n" &
           "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
           "Sec-WebSocket-Version: 13\r\n"
  if origin.len > 0: result.add "Origin: " & origin & "\r\n"
  result.add "\r\n"

proc filled(n: int; c: char): string =
  result = newString(n)
  var i = 0
  while i < n:
    result[i] = c
    i = i + 1

proc sizedHead(lines: string; total: int): string =
  ## A request head of exactly `total` bytes, terminating CRLFCRLF included:
  ## `lines` (a request line and field lines, each ending in CRLF), then an
  ## `X-Fill` field padding it out, then the blank line.
  const Name = "X-Fill: "
  result = lines & Name & filled(total - lines.len - Name.len - 4, 'f') & "\r\n\r\n"

proc getHead(total: int): string =
  ## A `GET /ok` head of exactly `total` bytes.
  result = sizedHead("GET /ok HTTP/1.1\r\nHost: localhost\r\n", total)

proc statusOf(resp: string): int =
  ## The status code of the first response in `resp`, or 0.
  result = 0
  if resp.len >= 12 and startsWith(resp, "HTTP/1.1 "):
    var i = 9
    while i < 12:
      let d = resp[i]
      if d >= '0' and d <= '9': result = result * 10 + (ord(d) - ord('0'))
      i = i + 1

proc closesConn(resp: string): bool =
  ## Whether the first response's header section carries `Connection: close`.
  let e = find(resp, "\r\n\r\n")
  result = e >= 0 and find(substr(resp, 0, e + 1), "\r\nConnection: close\r\n") >= 0

proc countOf(hay, needle: string): int =
  result = 0
  var at = find(hay, needle)
  while at >= 0:
    result = result + 1
    at = find(hay, needle, at + needle.len)

proc closeCodeOf(f: Frame): int =
  result = 0
  if f.opcode == opClose and f.payload.len >= 2:
    result = (uint8(f.payload[0]).int shl 8) or uint8(f.payload[1]).int

proc countMsg(what: string; got, want: int64): string =
  what & ": " & $got & " in flight, want " & $want

# ── the scenarios ───────────────────────────────────────────────────────

proc plainRequest() {.passive.} =
  section "a plain request and response"
  let start = inflightBytes()
  check start == 0'i64, countMsg("idle server", start, 0'i64)
  let c = newClient()
  send(c, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
  finishClient(c)
  check statusOf(c.acc) == 200, "answered 200"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc pipelinedPair() {.passive.} =
  section "a pipelined pair on one connection"
  let start = inflightBytes()
  let c = newClient()
  send(c, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n" &
          "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
  finishClient(c)
  check countOf(c.acc, "HTTP/1.1 200") == 2, "both answered 200"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc chunkedInPieces() {.passive.} =
  section "a chunked body arriving in separate writes"
  let start = inflightBytes()
  let c = newClient()
  let head = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
  let first = "5\r\nhello\r\n"
  send(c, head)
  sleepMs(20)
  send(c, first)
  let mid = settle(start + int64(head.len + first.len))
  check mid == start + int64(head.len + first.len),
        countMsg("part-way through the body", mid, start + int64(head.len + first.len))
  sleepMs(20)
  send(c, "6\r\n world\r\n")
  sleepMs(20)
  send(c, "0\r\n\r\n")
  finishClient(c)
  check statusOf(c.acc) == 200 and endsWith(c.acc, "hello world"), "echoed the body"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc answered(what, request: string; status: int) {.passive.} =
  section what
  let start = inflightBytes()
  let c = newClient()
  send(c, request)
  finishClient(c)
  check statusOf(c.acc) == status, "answered " & $status & " (got " & $statusOf(c.acc) & ")"
  if status >= 400:
    check closesConn(c.acc), "the rejection says Connection: close"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc headSplitOverCap() {.passive.} =
  section "a complete head over maxRequestHead, split across reads: 431"
  # The first write stays under the cap, so the driver reads on; the second
  # completes the head well past it. The second write waits until the
  # server has buffered the first, so the head arrives as two reads.
  let start = inflightBytes()
  let c = newClient()
  let head = getHead(MaxHead + 4038)
  let first = MaxHead - 8
  send(c, substr(head, 0, first - 1))
  let mid = settle(start + int64(first))
  check mid == start + int64(first), countMsg("first part buffered", mid, start + int64(first))
  send(c, substr(head, first, head.len - 1))
  finishClient(c)
  check statusOf(c.acc) == 431, "answered 431 (got " & $statusOf(c.acc) & ")"
  check closesConn(c.acc), "the rejection says Connection: close"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc pipelinedUnderCap() {.passive.} =
  section "a pipelined pair, each head under maxRequestHead, together over it"
  let start = inflightBytes()
  let c = newClient()
  let head = getHead(MaxHead - 548)
  send(c, head & head)
  finishClient(c)
  check countOf(c.acc, "HTTP/1.1 200") == 2, "both answered 200"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc upgradeThenClose() {.passive.} =
  section "a WebSocket upgrade with a frame in the same write, then a close"
  let start = inflightBytes()
  let c = newClient()
  send(c, upgradeRequest("/ws") & clientFrame(opText, "pipelined"))
  let head = readHead(c)
  check statusOf(head) == 101, "upgraded"
  let echo = readFrame(c)
  check echo.opcode == opText and echo.payload == "pipelined",
        "the frame sent with the upgrade was echoed"
  send(c, clientFrame(opClose, "\x03\xE8"))
  let bye = readFrame(c)
  check closeCodeOf(bye) == 1000, "the close was answered"
  finishClient(c)
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc upgradeRefused(what, request: string; status: int) {.passive.} =
  section what
  let start = inflightBytes()
  let c = newClient()
  send(c, request)
  finishClient(c)
  check statusOf(c.acc) == status, "answered " & $status & " (got " & $statusOf(c.acc) & ")"
  check closesConn(c.acc), "the refusal says Connection: close"
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc openWs(c: Client): bool {.passive.} =
  send(c, upgradeRequest("/ws"))
  result = statusOf(readHead(c)) == 101

proc fragmentedMessage() {.passive.} =
  section "a fragmented WebSocket message is counted while it is assembled"
  let start = inflightBytes()
  let c = newClient()
  check openWs(c), "upgraded"
  # The driver writes the 101 before it hands the buffered bytes over.
  let base = settle(start)
  check base == start, countMsg("after the upgrade", base, start)
  let a = filled(1000, 'a')
  let b = filled(500, 'b')
  send(c, clientFrame(opText, a, fin = false))
  let open = settle(base + int64(a.len))
  check open == base + int64(a.len), countMsg("first fragment buffered", open, base + int64(a.len))
  send(c, clientFrame(opContinuation, b))
  let msg = readFrame(c)
  check msg.opcode == opText and msg.payload == a & b, "the assembled message was delivered"
  check inflightBytes() == base, countMsg("once delivered", inflightBytes(), base)
  send(c, clientFrame(opClose, "\x03\xE8"))
  discard readFrame(c)
  finishClient(c)
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc fragmentAbandoned() {.passive.} =
  section "a fragmented message abandoned when the connection closes"
  let start = inflightBytes()
  let c = newClient()
  check openWs(c), "upgraded"
  let a = filled(700, 'a')
  send(c, clientFrame(opBinary, a, fin = false))
  let open = settle(start + int64(a.len))
  check open == start + int64(a.len), countMsg("first fragment buffered", open, start + int64(a.len))
  finishClient(c)
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc fragmentTooBig() {.passive.} =
  section "a fragmented message over maxWsMessage is refused with 1009"
  let start = inflightBytes()
  let c = newClient()
  check openWs(c), "upgraded"
  let a = filled(3000, 'a')
  send(c, clientFrame(opText, a, fin = false))
  let open = settle(start + int64(a.len))
  check open == start + int64(a.len), countMsg("first fragment buffered", open, start + int64(a.len))
  send(c, clientFrame(opContinuation, a))
  let bye = readFrame(c)
  check closeCodeOf(bye) == 1009, "closed with 1009 (got " & $closeCodeOf(bye) & ")"
  finishClient(c)
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

proc fragmentProtocolError() {.passive.} =
  section "a new data frame inside a fragmented message is refused with 1002"
  let start = inflightBytes()
  let c = newClient()
  check openWs(c), "upgraded"
  let a = filled(800, 'a')
  send(c, clientFrame(opText, a, fin = false))
  let open = settle(start + int64(a.len))
  check open == start + int64(a.len), countMsg("first fragment buffered", open, start + int64(a.len))
  send(c, clientFrame(opText, "again"))
  let bye = readFrame(c)
  check closeCodeOf(bye) == 1002, "closed with 1002 (got " & $closeCodeOf(bye) & ")"
  finishClient(c)
  check inflightBytes() == start, countMsg("after EOF", inflightBytes(), start)

# ── the lingering close ─────────────────────────────────────────────────

proc msSince(t0: MonoTime): int =
  int((getMonoTime() - t0).inMilliseconds)

proc settleLinger(want: int64): int64 {.passive.} =
  ## `lingeringNow()` once it equals `want`, or its value after 3 s.
  result = lingeringNow()
  var waited = 0
  while result != want and waited < 3000:
    sleepMs(5)
    waited = waited + 5
    result = lingeringNow()

proc lingerEnded(before: int64; t0: MonoTime; limitMs: int): int {.passive.} =
  ## Milliseconds from `t0` until `lingerClosedTotal()` passes `before`, or
  ## -1 when it does not within `limitMs`.
  result = -1
  while result < 0 and msSince(t0) < limitMs:
    if lingerClosedTotal() > before: result = msSince(t0)
    else: sleepMs(5)

proc tooBig(bodyLen: int): string =
  ## A POST head declaring a `bodyLen`-byte body.
  "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: " & $bodyLen & "\r\n\r\n"

proc settled(what: string; start, lstart: int64) {.passive.} =
  ## The counts are back where the scenario found them.
  check inflightBytes() == start, countMsg(what, inflightBytes(), start)
  let l = settleLinger(lstart)
  check l == lstart, what & ": " & $l & " lingering, want " & $lstart

proc completeReject(c: Client; status: int) =
  check statusOf(c.acc) == status, "answered " & $status & " (got " & $statusOf(c.acc) & ")"
  check closesConn(c.acc), "the rejection says Connection: close"
  check endsWith(c.acc, "\r\n\r\n"), "the whole response arrived"
  check c.sendErr == 0, "every write was taken, none reset (got " & $c.sendErr &
        (if c.sendErr == -ECONNRESET: ", ECONNRESET)" else: ")")
  check c.endErr == 0, "then EOF, not a reset (got " & $c.endErr &
        (if c.endErr == -ECONNRESET: ", ECONNRESET)" else: ")")

proc bodyOverCapStillSending() {.passive.} =
  section "linger: a 413 while the client is still sending its body"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  const total = 3 * 65536
  const first = 65536 + 1024
  sendAll(c, tooBig(total) & filled(first, 'x'))
  # The rest of the body goes after the 413 has arrived. It fits the socket
  # buffer, so a reset reaches a write that is not parked waiting for room.
  let head = readHead(c)
  sendAll(c, filled(32768, 'x'))
  readToEof(c)
  c.acc = head & c.acc
  completeReject(c, 413)
  discard cClose(c.fd)
  check lingerEnded(closed0, getMonoTime(), 3000) >= 0, "the connection lingered"
  settled("after the 413", start, lstart)

proc headOverCapStillSending() {.passive.} =
  section "linger: a 431 with kilobytes still unread behind the head"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  sendAll(c, getHead(MaxHead + 8192))
  let head = readHead(c)
  # The server half-closes before it drains, so EOF follows the response at
  # once; without that it would come only when the idle linger ends.
  let t = getMonoTime()
  readToEof(c)
  let eofMs = msSince(t)
  c.acc = head & c.acc
  completeReject(c, 431)
  check eofMs < LingerIdleMs - 50, "EOF came straight after the response (" & $eofMs & " ms)"
  discard cClose(c.fd)
  check lingerEnded(closed0, getMonoTime(), 3000) >= 0, "the connection lingered"
  settled("after the 431", start, lstart)

proc tricklingClient() {.passive.} =
  section "linger: a client trickling a byte every 100 ms is cut off at lingerMs"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  send(c, tooBig(5000))
  let head = readHead(c)
  let t0 = getMonoTime()
  check statusOf(head) == 413, "answered 413"
  var ended = -1
  var next = 0
  var seen = false
  while ended < 0 and msSince(t0) < LingerMs + 2000:
    if msSince(t0) >= next:
      discard writeNow(c.fd, "x", 0)
      next = next + 100
    if lingeringNow() > lstart: seen = true
    sleepMs(5)
    if lingerClosedTotal() > closed0: ended = msSince(t0)
  check seen, "the connection was counted as lingering"
  check ended > LingerIdleMs + 100,
        "the trickle kept it past lingerIdleMs (ended at " & $ended & " ms)"
  check ended >= 0 and ended <= LingerMs + Slack,
        "ended by lingerMs + slack (ended at " & $ended & " ms)"
  discard cClose(c.fd)
  settled("after the trickle", start, lstart)

proc silentClient() {.passive.} =
  section "linger: a silent client that never closes is cut off at lingerIdleMs"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  send(c, tooBig(5000))
  let head = readHead(c)
  let t0 = getMonoTime()
  check statusOf(head) == 413, "answered 413"
  let ended = lingerEnded(closed0, t0, LingerMs + 2000)
  check ended >= 0 and ended <= LingerIdleMs + Slack,
        "ended by lingerIdleMs + slack (ended at " & $ended & " ms)"
  check ended < LingerMs, "ended before lingerMs: the idle bound fired"
  readToEof(c)
  check c.endErr == 0, "EOF (got " & $c.endErr & ")"
  discard cClose(c.fd)
  settled("after the silent client", start, lstart)

var gFloodFd: cint = -1
var gFloodStop: int
var gFloodDone: int
var gFloodBuf: array[16384, byte]

proc floodOnce(): int =
  ## One write(2) of `gFloodBuf`: 1 when bytes went, 0 when the socket
  ## buffer is full, -1 once the connection is gone.
  let r = cWrite(gFloodFd, addr gFloodBuf[0], csize_t(gFloodBuf.len))
  result = if r > 0: 1
           elif r < 0 and (cErrno == EAGAIN or cErrno == EINTR): 0
           else: -1

proc flooder() {.passive.} =
  ## Write to `gFloodFd` without pause until a write fails or the scenario
  ## says stop. Plain write(2), not the ring: the server's drain is under
  ## test, so the client's writes stay as simple as they can be.
  var going = true
  while going and atomicLoad(gFloodStop) == 0:
    let r = floodOnce()
    if r > 0: yieldTask()
    elif r == 0: sleepMs(1)
    else: going = false
  atomicStore(gFloodDone, 1)

proc floodingClient() {.passive.} =
  section "linger: a flooding client is cut off at lingerMs; others are served meanwhile"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  send(c, tooBig(5000))
  let head = readHead(c)
  let t0 = getMonoTime()
  check statusOf(head) == 413, "answered 413"
  gFloodFd = c.fd
  atomicStore(gFloodStop, 0)
  atomicStore(gFloodDone, 0)
  spawnTask flooder()
  sleepMs(100)
  let t1 = getMonoTime()
  let n = newClient()
  send(n, "GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  readToEof(n)
  let took = msSince(t1)
  discard cClose(n.fd)
  check statusOf(n.acc) == 200, "a request on another connection answered 200"
  check took < LingerMs div 2, "and promptly (" & $took & " ms)"
  let ended = lingerEnded(closed0, t0, LingerMs + 2000)
  check ended > LingerIdleMs + 100,
        "the flood kept it past lingerIdleMs (ended at " & $ended & " ms)"
  check ended >= 0 and ended <= LingerMs + Slack,
        "ended by lingerMs + slack (ended at " & $ended & " ms)"
  atomicStore(gFloodStop, 1)
  var w = 0
  while atomicLoad(gFloodDone) == 0 and w < 3000:
    sleepMs(5)
    w = w + 5
  check atomicLoad(gFloodDone) == 1, "the flooder stopped"
  discard cClose(c.fd)
  settled("after the flood", start, lstart)

proc lingerCapHolds() {.passive.} =
  section "linger: past the cap, a rejected connection closes at once"
  const Cap = 2
  const Conns = 4
  let saved = lingerCap()
  let nofile = openFileLimit()
  check nofile > 0, "RLIMIT_NOFILE is readable (" & $nofile & ")"
  check saved == int64(min(MaxFds, nofile) div 4),
        "serve set the cap to a quarter of min(MaxFds, RLIMIT_NOFILE) (" & $saved & ")"
  setLingerCap(Cap)
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  var cs: seq[Client] = @[]
  var i = 0
  while i < Conns:
    cs.add newClient()
    i = i + 1
  i = 0
  while i < Conns:
    send(cs[i], tooBig(5000))
    i = i + 1
  var most = lstart
  i = 0
  while i < Conns:
    readToEof(cs[i])
    check statusOf(cs[i].acc) == 413 and cs[i].endErr == 0, "answered 413, then EOF"
    most = max(most, lingeringNow())
    i = i + 1
  let now = lingeringNow()
  most = max(most, now)
  check now == lstart + Cap, "the cap's worth linger (" & $(now - lstart) & ")"
  # A peer that has closed answers a write with a reset, which fails the
  # next write; one that lingers drains it.
  i = 0
  while i < Conns:
    discard writeNow(cs[i].fd, "p", 0)
    i = i + 1
  sleepMs(30)
  var gone = 0
  i = 0
  while i < Conns:
    if writeNow(cs[i].fd, "q", 0) < 0: gone = gone + 1
    most = max(most, lingeringNow())
    i = i + 1
  check gone == Conns - Cap, "those past the cap closed at once (" & $gone & " closed)"
  check most <= lstart + Cap, "never more than the cap lingering (" & $(most - lstart) & ")"
  i = 0
  while i < Conns:
    discard cClose(cs[i].fd)
    i = i + 1
  settled("after the cap", start, lstart)
  check lingerClosedTotal() - closed0 == Cap,
        "only the cap's worth counted as lingered (" & $(lingerClosedTotal() - closed0) & ")"
  setLingerCap(int(saved))

proc lingerEqualsIdle() {.passive.} =
  section "linger: lingerMs equal to lingerIdleMs ends at the bound"
  let savedMs = gServerConfig.lingerMs
  gServerConfig.lingerMs = LingerIdleMs
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let c = newClient()
  send(c, tooBig(5000))
  let head = readHead(c)
  let t0 = getMonoTime()
  check statusOf(head) == 413, "answered 413"
  var ended = -1
  var next = 0
  while ended < 0 and msSince(t0) < LingerIdleMs + 2000:
    if msSince(t0) >= next:
      discard writeNow(c.fd, "x", 0)
      next = next + 50
    sleepMs(5)
    if lingerClosedTotal() > closed0: ended = msSince(t0)
  check ended >= 0 and ended <= LingerIdleMs + Slack,
        "ended by lingerMs + slack (ended at " & $ended & " ms)"
  discard cClose(c.fd)
  gServerConfig.lingerMs = savedMs
  settled("after the bound", start, lstart)

proc lingeringRefusals() {.passive.} =
  section "linger: a cross-site 403 and a claimed upgrade with bytes behind it"
  let start = inflightBytes()
  let lstart = lingeringNow()
  var closed0 = lingerClosedTotal()
  let o = newClient()
  send(o, upgradeRequest("/ws", "http://evil.example"))
  finishClient(o)
  check statusOf(o.acc) == 403 and o.endErr == 0, "answered 403, then EOF"
  check lingerEnded(closed0, getMonoTime(), 3000) >= 0, "the 403 lingered"
  closed0 = lingerClosedTotal()
  let d = newClient()
  send(d, upgradeRequest("/deny") & clientFrame(opText, "behind the upgrade"))
  finishClient(d)
  check statusOf(d.acc) == 401 and d.endErr == 0, "answered 401, then EOF"
  check lingerEnded(closed0, getMonoTime(), 3000) >= 0,
        "the claim lingered: the client had sent more than the request"
  settled("after the refusals", start, lstart)

proc noLinger() {.passive.} =
  section "no linger after a response, a 400, a WebSocket session or a bare claim"
  let start = inflightBytes()
  let lstart = lingeringNow()
  let closed0 = lingerClosedTotal()
  let k = newClient()
  send(k, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
  check statusOf(readHead(k)) == 200, "first keep-alive response"
  send(k, "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
  finishClient(k)
  check countOf(k.acc, "HTTP/1.1 200") == 1, "second keep-alive response"
  let b = newClient()
  send(b, "GET /ok HTTP/1.1\r\nHost: localhost\r\nno colon here\r\n\r\ntrailing")
  finishClient(b)
  check statusOf(b.acc) == 400, "answered 400"
  let w = newClient()
  check openWs(w), "upgraded"
  send(w, clientFrame(opClose, "\x03\xE8"))
  discard readFrame(w)
  finishClient(w)
  let d = newClient()
  send(d, upgradeRequest("/deny"))
  finishClient(d)
  check statusOf(d.acc) == 401, "a claim with nothing behind it answered 401"
  sleepMs(LingerIdleMs + 100)
  check lingerClosedTotal() == closed0,
        "nothing lingered (" & $(lingerClosedTotal() - closed0) & " did)"
  settled("after the non-lingering ends", start, lstart)

proc runAll() {.passive.} =
  plainRequest()
  pipelinedPair()
  chunkedInPieces()
  answered("a malformed request: 400",
           "GET /ok HTTP/1.1\r\nHost: localhost\r\nno colon here\r\n\r\ntrailing bytes", 400)
  answered("a body over maxBodySize: 413",
           "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5000\r\n\r\n" &
           filled(100, 'x'), 413)
  # Unterminated: the driver answers 431 once it holds `maxRequestHead`
  # bytes with no end of head in them.
  answered("an unterminated head over maxRequestHead: 431",
           "GET /ok HTTP/1.1\r\nHost: localhost\r\nX-Big: " & filled(MaxHead + 200, 'h'), 431)
  # Exactly `maxRequestHead` bytes and no end of head: already over the cap,
  # so 431 without waiting for more. A driver that read on would see only
  # the client's EOF and close without an answer.
  const unterminated = "GET /ok HTTP/1.1\r\nHost: localhost\r\nX-Big: "
  answered("an unterminated head of exactly maxRequestHead: 431",
           unterminated & filled(MaxHead - unterminated.len, 'h'), 431)
  # Terminated: the cap counts the head through its CRLFCRLF.
  answered("a head of exactly maxRequestHead: 200", getHead(MaxHead), 200)
  answered("a head one byte over maxRequestHead: 431", getHead(MaxHead + 1), 431)
  answered("a complete head over maxRequestHead in one read: 431",
           getHead(MaxHead + 1998), 431)
  headSplitOverCap()
  pipelinedUnderCap()
  upgradeThenClose()
  upgradeRefused("a cross-site upgrade: origin 403",
                 upgradeRequest("/ws", "http://evil.example"), 403)
  upgradeRefused("an upgrade claimed by before-middleware",
                 upgradeRequest("/deny"), 401)
  let up = upgradeRequest("/ws")
  upgradeRefused("an upgrade head over maxRequestHead: 431, not 101",
                 sizedHead(substr(up, 0, up.len - 3), MaxHead + 1998), 431)
  fragmentedMessage()
  fragmentAbandoned()
  fragmentTooBig()
  fragmentProtocolError()
  bodyOverCapStillSending()
  headOverCapStillSending()
  tricklingClient()
  silentClient()
  floodingClient()
  lingerCapHolds()
  lingerEqualsIdle()
  lingeringRefusals()
  noLinger()
  finish()

# ── the server ──────────────────────────────────────────────────────────

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

proc echoBody(req: Request): Response {.nimcall, raises.} =
  newResponse(200, req.body)

proc denyGate(req: Request): Opt[Response] {.nimcall.} =
  ## Claims `/deny…`, which the upgrade scenario uses; passes the rest.
  if startsWith(path(req), "/deny"): result = some(newResponse(401))
  else: result = none[Response]()

discard cAlarm(90)
gPort = freePort()
if gPort == 0'u16:
  writeLine(stderr, "test_inflight: no free loopback port")
  quit(1)
var cfg = defaultServerConfig()
cfg.maxBodySize = MaxBody
cfg.maxRequestHead = MaxHead
cfg.maxWsMessage = MaxMessage
cfg.lingerMs = LingerMs
cfg.lingerIdleMs = LingerIdleMs
get("/ok", ok)
post("/echo", echoBody)
addBeforeMiddleware(denyGate)
setBootTask(runAll)
serve(gPort, cfg, bindAddr = "127.0.0.1")

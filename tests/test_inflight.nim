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
import std/[syncio, strutils, opt]
from std/posix/posix import Sockaddr_in, SockLen
import hashi
import hashi/buffer
import hashi/http/connreg
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
  eof: bool                  ## the server closed its end
  frame: Frame               ## the frame `nextFrame` last took
  rbuf: array[4096, byte]

proc noFrame(): Frame =
  ## What `readFrame` answers when the server closed first.
  result = Frame(fin: true, opcode: opClose, masked: false, payload: "")

proc newClient(): Client =
  result = Client(fd: dial(), acc: "", eof: false, frame: noFrame())

proc readSome(c: Client): bool {.passive.} =
  ## One read into `c.acc`; false once the server has closed or the read
  ## failed.
  let n = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
  if n > 0:
    appendBytes(c.acc, addr c.rbuf[0], n)
    result = true
  else:
    c.eof = true
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

discard cAlarm(60)
gPort = freePort()
if gPort == 0'u16:
  writeLine(stderr, "test_inflight: no free loopback port")
  quit(1)
var cfg = defaultServerConfig()
cfg.maxBodySize = MaxBody
cfg.maxRequestHead = MaxHead
cfg.maxWsMessage = MaxMessage
get("/ok", ok)
post("/echo", echoBody)
addBeforeMiddleware(denyGate)
setBootTask(runAll)
serve(gPort, cfg, bindAddr = "127.0.0.1")

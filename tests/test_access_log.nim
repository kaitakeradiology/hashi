## The access log's target: verbatim by default, and with an
## `AccessLogTarget` installed, the classifier's word on every line the real
## server writes: 200, 404 and 500 from a route, 403 (cross-site origin), 401
## (middleware claim) and 101 on a WebSocket upgrade, 429 (middleware claim)
## and 200 (handoff) on an SSE stream. Every target carries an identifier in
## a path segment and in the query; it must appear in no captured record.

import std/[syncio, strutils, opt, atomics, ticketlocks]
import hashi
import hashi/buffer
import hashi/http/httplog
import hashi/sse/session
from std/posix/posix import close, SockLen
import testkit

proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cShutdown(fd: cint; how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
proc cFcntl(fd: cint; cmd: cint; arg: cint): cint {.importc: "fcntl", header: "<fcntl.h>".}

const
  AfInet = 2.cint
  SockStream = 1.cint
  ShutWr = 1.cint
  FGetfl = 3.cint
  FSetfl = 4.cint
  ONonblock = 0o4000.cint
  Secret = "K9Q7731"   ## the identifier every target carries
  Word = "family-q"    ## the classifier's answer for a target with a query

# ── the captured log ────────────────────────────────────────────────────

var capLock: TicketLock
var captured: seq[string] = @[]   ## every record's message, guarded by capLock

proc capture(level: LogLevel; file: string; line: int; msg: string) {.nimcall.} =
  acquire(capLock)
  {.cast(assumeSync).}:   # under capLock
    captured.add msg
  release(capLock)

proc records(): seq[string] =
  acquire(capLock)
  {.cast(assumeSync).}:   # under capLock
    result = captured
  release(capLock)

proc isAccessLine(msg: string): bool =
  ## `<ip> <status> <METHOD> <target> <timing>`.
  let f = split(msg, ' ')
  result = f.len == 5 and f[1].len == 3 and allCharsInSet(f[1], {'0'..'9'})

proc accessLines(): seq[string] =
  result = @[]
  for m in records():
    if isAccessLine(m): result.add m

proc classify(target: string): string {.nimcall.} =
  ## A word, never the target; `Word` when the query reached the classifier.
  result = if find(target, '?') >= 0: Word else: "family"

# ── the default: verbatim ───────────────────────────────────────────────

setLogCallback(capture)
setLogLevel(LogLevel.trace)

section "accessLog with no AccessLogTarget installed"
accessLog("203.0.113.5", 200, "GET", "/rec/" & Secret & "?id=" & Secret, 87)
block:
  let lines = accessLines()
  check lines.len == 1, "one access line"
  if lines.len == 1:
    check lines[0] == "203.0.113.5 200 GET /rec/" & Secret & "?id=" & Secret & " 87us",
          "the target is logged verbatim"
acquire(capLock)
{.cast(assumeSync).}:   # under capLock
  captured = @[]
release(capLock)

# ── the server ──────────────────────────────────────────────────────────

var gPort: int   # onBound's port (atomic)

proc onBound(port: uint16) {.nimcall, gcsafe.} =
  atomicStore(gPort, int(port), moRelease)

proc connectTo(port: uint16): cint =
  ## A non-blocking client socket connected to 127.0.0.1:`port`, or -1.
  var sa = default(array[16, uint8])
  var f = uint16(AfInet)
  copyMem(addr sa[0], addr f, 2)
  sa[2] = uint8(port shr 8)
  sa[3] = uint8(port and 0xff'u16)
  sa[4] = 127'u8
  sa[7] = 1'u8
  result = cSocket(AfInet, SockStream, 0.cint)
  if result < 0: return -1
  if cConnect(result, addr sa, SockLen(16)) != 0:
    discard close(result)
    result = -1
  else:
    discard cFcntl(result, FSetfl, cFcntl(result, FGetfl, 0.cint) or ONonblock)

proc exchange(request: string): string {.passive.} =
  ## Send `request`, half-close, and read until the server closes.
  result = ""
  let fd = connectTo(uint16(atomicLoad(gPort, moAcquire)))
  if fd < 0: return
  discard writeAll(fd, request)
  discard cShutdown(fd, ShutWr)
  var buf = default(array[1024, char])
  while true:
    let n = waitRead(fd, addr buf[0], buf.len)
    if n <= 0: break
    appendBytes(result, addr buf[0], n)
  discard close(fd)

proc nextAccessLine(seen: int): string {.passive.} =
  ## The first access line after the `seen` already taken, or "" after 2 s.
  result = ""
  var waited = 0
  var lines = accessLines()
  while lines.len <= seen and waited < 2000:
    sleepMs(5)
    waited = waited + 5
    lines = accessLines()
  if lines.len > seen: result = lines[seen]

proc target(prefix: string): string =
  result = prefix & "/" & Secret & "?id=" & Secret & "&x=1"

proc plain(path: string): string =
  result = "GET " & target(path) & " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

proc upgrade(path: string; origin = ""): string =
  result = "GET " & target(path) & " HTTP/1.1\r\nHost: localhost\r\n" &
           "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
           "Sec-WebSocket-Version: 13\r\n"
  if origin.len > 0: result.add "Origin: " & origin & "\r\n"
  result.add "\r\n"

var gSeen = 0   # access lines already taken; the boot task alone touches it

proc scenario(what, request: string; status: int) {.passive.} =
  section what
  let resp = exchange(request)
  check startsWith(resp, "HTTP/1.1 " & $status), "answered " & $status
  var line = ""
  {.cast(assumeSync).}:   # only the boot task reads or writes gSeen
    line = nextAccessLine(gSeen)
    if line.len > 0: gSeen = gSeen + 1
  check line.len > 0, "an access line was written"
  let f = split(line, ' ')
  if f.len == 5:
    check f[1] == $status, "the line's status is " & $status & " (got " & f[1] & ")"
    check f[3] == Word, "the target is the classifier's word (got " & f[3] & ")"
  check find(line, Secret) < 0 and find(line, '?') < 0, "the raw target is not in the line"

proc runAll() {.passive.} =
  scenario("a routed request: 200", plain("/rec"), 200)
  scenario("no route: 404", plain("/none"), 404)
  scenario("a handler's 500", plain("/boom"), 500)
  scenario("a cross-site WebSocket upgrade: 403", upgrade("/ws", "http://evil.example"), 403)
  scenario("a WebSocket upgrade claimed by middleware: 401", upgrade("/deny"), 401)
  scenario("a WebSocket upgrade: 101", upgrade("/ws"), 101)
  scenario("an SSE stream claimed by middleware: 429", plain("/deny-sse"), 429)
  scenario("an SSE stream handed off: 200", plain("/sse"), 200)
  section "the whole captured log"
  var leaked = 0
  for m in records():
    if find(m, Secret) >= 0: leaked = leaked + 1
  check leaked == 0, "no record names the identifier (" & $leaked & " did)"
  check accessLines().len == 8, "one access line per request"
  finish()

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

proc boom(req: Request): Response {.nimcall, raises.} =
  newResponse(500, "boom")

proc gate(req: Request): Opt[Response] {.nimcall.} =
  if startsWith(path(req), "/deny-sse"): result = some(newResponse(429))
  elif startsWith(path(req), "/deny"): result = some(newResponse(401))
  else: result = none[Response]()

proc isSse(req: Request): bool {.nimcall.} =
  startsWith(path(req), "/sse") or startsWith(path(req), "/deny-sse")

proc sseOnce(req: Request; fd: cint) {.passive.} =
  discard writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: x\n\n")

proc wsDone(ws: WsConn) {.passive.} =
  discard

discard cAlarm(30)
setAccessLogTarget(classify)
get("/rec/:id", ok)
get("/boom/:id", boom)
addBeforeMiddleware(gate)
setSseHandler(isSse, sseOnce)
setWsHandler(wsDone)
setBootTask(runAll)
serve(0'u16, bindAddr = "127.0.0.1", onBound = onBound)

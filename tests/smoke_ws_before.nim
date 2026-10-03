## Before-middleware on WebSocket upgrades, end to end: the server half.
##
##   smoke_ws_before <main-port> <secondary-port>
##
## A before-middleware answers 403 with the client address as the body for
## any request whose path starts with `/deny`, and passes everything else.
## The main WebSocket handler sends one text message "main-handler"; a
## secondary listener (`addWsListener`) on the second port sends
## "extra-handler". `GET /ok` is a plain route. Prints "ready" on stdout once
## every listener is up. Driven by `tests/conformance/ws_before.py`, which
## asserts that the main listener's upgrades pass through the chain and the
## secondary listener's do not.

import std/[syncio, opt, strutils, cmdline]
import hashi

proc portArg(i: int): uint16 =
  ## Argument `i` as a TCP port; exits 2 when absent or not a port.
  if paramCount() < i:
    writeLine(stderr, "usage: smoke_ws_before <main-port> <secondary-port>")
    quit(2)
  let s = paramStr(i)
  var n = 0
  var ok = s.len > 0 and s.len <= 5
  var k = 0
  while ok and k < s.len:
    if s[k] in {'0'..'9'}: n = n * 10 + (ord(s[k]) - ord('0'))
    else: ok = false
    inc k
  if not ok or n < 1 or n > 65535:
    writeLine(stderr, "smoke_ws_before: bad port " & s)
    quit(2)
  result = uint16(n)

proc denyGate(req: Request): Opt[Response] {.nimcall.} =
  ## 403 for `/deny…`, with the attributed client address as the body.
  if startsWith(path(req), "/deny"): result = some(newResponse(403, req.remoteAddress))
  else: result = none[Response]()

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

proc mainWs(ws: WsConn) {.passive.} =
  if wsSend(ws, "main-handler"): discard wsClose(ws)

proc extraWs(ws: WsConn) {.passive.} =
  if wsSend(ws, "extra-handler"): discard wsClose(ws)

proc announce() =
  writeLine(stdout, "ready")
  flushFile(stdout)

proc ready() {.passive.} =
  announce()

let mainPort = portArg(1)
let extraPort = portArg(2)
addBeforeMiddleware(denyGate)
get("/ok", ok)
setWsHandler(mainWs)
if not addWsListener(extraPort, extraWs, "127.0.0.1"):
  writeLine(stderr, "smoke_ws_before: addWsListener refused")
  quit(1)
setBootTask(ready)
serve(mainPort, bindAddr = "127.0.0.1")

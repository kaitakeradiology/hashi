## HTTP/1.1 server: the connection driver and the public `serve` entry point.
##
## Register routes with `get`/`post`/`addRoute` (or a passive handler with
## `addAsyncHandler`), then call `serve`. Each accepted connection runs a
## keep-alive loop: read until a full request head, read the body
## (Content-Length or chunked), dispatch, write the response, repeat until
## the peer or the `Connection` header ends it. Malformed or ambiguous
## framing is answered with 400; an over-long head with 431; an over-long
## body with 413. A WebSocket upgrade hands the connection to the handler
## registered with `setWsHandler`, and a matching SSE request to the one
## registered with `setSseHandler`.
##
## Handlers resume on the reactor's worker pool, so several run at once on
## different threads. State local to a handler is safe; state shared between
## handlers needs a lock.

import std/[syncio, opt, strutils, monotimes, times]
from std/posix/posix import close
import hashi/net
import hashi/http/config
import hashi/http/connreg
import hashi/http/request
import hashi/http/router
import hashi/http/httplog
import hashi/http/forwarded
import hashi/ws/handshake
import hashi/ws/session
import hashi/ws/session_io
import hashi/sse/session
import hashi/log
import hashi/loop
import hashi/buffer

# ── registries ──────────────────────────────────────────────────────────

var appRouter = default(Router)
  ## The process-global `Router` the connection driver dispatches through.

proc addRoute*(meth, path: string; h: Handler) =
  ## Register `h` for `meth path`. See `hashi/http/router` for matching rules.
  addRoute(appRouter, meth, path, h)

proc get*(path: string; h: Handler) =
  ## Register `h` for `GET path`.
  get(appRouter, path, h)

proc post*(path: string; h: Handler) =
  ## Register `h` for `POST path`.
  post(appRouter, path, h)

proc put*(path: string; h: Handler) =
  ## Register `h` for `PUT path`.
  put(appRouter, path, h)

proc delete*(path: string; h: Handler) =
  ## Register `h` for `DELETE path`.
  delete(appRouter, path, h)

proc head*(path: string; h: Handler) =
  ## Register `h` for `HEAD path`. Without one, a GET route answers HEAD.
  head(appRouter, path, h)

proc options*(path: string; h: Handler) =
  ## Register `h` for `OPTIONS path`.
  options(appRouter, path, h)

proc patch*(path: string; h: Handler) =
  ## Register `h` for `PATCH path`.
  patch(appRouter, path, h)

proc setErrorHandler*(h: ErrorHandler) =
  ## Register the error handler: when a handler raises an `ErrorCode`, this
  ## maps it to the `Response` sent (default: `errorCodeToHttp`).
  setErrorHandler(appRouter, h)

proc setNotFoundHandler*(h: Handler) =
  ## Register the fallback handler, invoked when no route matches. It is tried
  ## last regardless of registration order, unlike a greedy `get("/**", …)`
  ## route, which would shadow every route registered after it.
  setNotFound(appRouter, h)

proc addBeforeMiddleware*(m: BeforeMiddleware) =
  ## Append a pre-dispatch middleware. See `hashi/http/router`.
  addBefore(appRouter, m)

proc addAfterMiddleware*(m: AfterMiddleware) =
  ## Append a post-dispatch middleware, e.g. one that adds security headers.
  addAfter(appRouter, m)

proc setBeforeMiddleware*(m: seq[BeforeMiddleware]) =
  ## Replace the whole pre-dispatch chain.
  setBefore(appRouter, m)

proc setAfterMiddleware*(m: seq[AfterMiddleware]) =
  ## Replace the whole post-dispatch chain.
  setAfter(appRouter, m)

type AsyncHandler* = proc (req: Request): Opt[Response] {.passive.}
  ## A request handler that may suspend on outbound I/O without blocking the
  ## reactor. Registered handlers run after the pre-dispatch middleware and
  ## before the synchronous routes: returning `some(resp)` claims the request,
  ## `none` falls through to route dispatch.

var gAsync: seq[AsyncHandler] = @[]

proc addAsyncHandler*(h: AsyncHandler) =
  ## Append a passive handler to the chain. Handlers are tried in registration
  ## order and the first to return `some` claims the request. Call before
  ## `serve`.
  gAsync.add h

proc hasAsyncHandler*(): bool =
  result = gAsync.len > 0

proc asyncHandlerCount*(): int =
  ## Number of registered passive handlers.
  ##
  ## Kept for tests and for a consumer that wants to assert its own wiring.
  ## `serve` used to log this at boot, back when the chain was a fixed-capacity
  ## array that DROPPED an over-limit handler in silence — the count was how you
  ## saw a handler go missing. The chain is an unbounded `seq` now and
  ## registration cannot fail, so the line was narrating a healthy boot and is
  ## gone; nothing here watches for a failure that no longer exists.
  result = gAsync.len

type BootTask* = proc () {.passive.}
  ## A one-shot `.passive` task run on the reactor once the listener is up,
  ## for startup work that needs the reactor (see `setBootTask`).
var gBootTask: nil BootTask

proc setBootTask*(t: BootTask) =
  ## Register a single `.passive` task to run once on the reactor right after the
  ## listener comes up. Replaces any prior task.
  gBootTask = t

proc hasBootTask*(): bool = gBootTask != nil

proc bootRunner() {.passive.} =
  ## Drives the registered boot task; spawned by `serve` when one is set.
  let t = gBootTask
  if t != nil: t()

const MaxExtraListeners* = 8
  ## Capacity of the secondary WebSocket-only listener table (`addWsListener`).

type Listener = object
  port: uint16
  bindAddr: string
  handler: WsHandler

var gExtra: seq[Listener] = @[]

proc addWsListener*(port: uint16; handler: WsHandler; bindAddr = ""): bool =
  ## Register an additional WebSocket-only listener on `port`/`bindAddr`, served
  ## on the same reactor with its own `handler`. The main listener's routes,
  ## WebSocket handler and SSE handler are not reachable on it (a non-WebSocket
  ## request gets 426), so a separate port or interface is its own trust
  ## domain. Call before `serve`. Returns false once `MaxExtraListeners` are
  ## registered. `bindAddr` takes the same literals as `serve`.
  if gExtra.len >= MaxExtraListeners: return false
  gExtra.add Listener(port: port, bindAddr: bindAddr, handler: handler)
  result = true

# ── the connection driver ───────────────────────────────────────────────

type
  Conn = ref object
    ## One accepted connection while its driver runs. A `ref` so the passive
    ## steps below mutate the buffers in place.
    fd: cint
    peer: string                ## the socket peer, as text
    acc: string                 ## inbound bytes not yet consumed
    rbuf: array[4096, byte]     ## the read buffer
    req: Request                ## the request being served

  HeadOutcome = enum
    hoOk        ## `c.req` holds a complete head
    hoClosed    ## the peer went away
    hoTooBig    ## no head within `maxRequestHead` bytes
    hoBad       ## malformed

  BodyOutcome = enum
    boOk        ## `c.req.body` is filled; `need` is the request's total length
    boClosed
    boBad       ## ambiguous framing or a malformed chunked body
    boTooBig    ## Content-Length over `maxBodySize`

proc timedRead(c: Conn): int {.passive.} =
  ## One read into `c.rbuf` with the idle deadline (`ServerConfig.idleTimeoutMs`)
  ## armed for the duration of the wait. Any inbound byte resets the window,
  ## so only a silent peer is reaped. Writes are deliberately untimed: under
  ## TCP flow control a slow-but-alive reader is indistinguishable from a
  ## stalled one, and dead-peer detection on the write side is
  ## `TCP_USER_TIMEOUT`'s job (see `setKeepalive`).
  let w = gServerConfig.idleTimeoutMs
  if w > 0: setDeadline(c.fd, getMonoTime().ticks + w.int64 * 1_000_000'i64)
  result = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
  if w > 0: setDeadline(c.fd, 0'i64)
  if result > 0: appendBytes(c.acc, addr c.rbuf[0], result)

proc reject(c: Conn; status: int) {.passive.} =
  ## Answer `status` with an empty body; the caller ends the connection.
  discard writeAll(c.fd, serialize(newResponse(status)))

proc awaitHead(c: Conn): HeadOutcome {.passive.} =
  ## Read until a full request head is buffered into `c.req`, or the peer
  ## closes, or the head exceeds `maxRequestHead` without terminating.
  c.req = default(Request)
  var st = parseRequestHead(c.acc, c.req)
  while st == psIncomplete and c.acc.len <= gServerConfig.maxRequestHead:
    if timedRead(c) <= 0: return hoClosed
    st = parseRequestHead(c.acc, c.req)
  case st
  of psOk: result = hoOk
  of psError: result = hoBad
  of psIncomplete: result = hoTooBig

proc awaitBody(c: Conn; need: var int): BodyOutcome {.passive.} =
  ## Read and decode the body `c.req`'s headers frame into `c.req.body`;
  ## `need` becomes how many bytes of `c.acc` the whole request occupies.
  let bi = bodyFraming(c.req)
  need = c.req.headBytes
  case bi.kind
  of bkError:
    result = boBad
  of bkNone:
    result = boOk
  of bkLength:
    if bi.length > gServerConfig.maxBodySize: return boTooBig
    need = c.req.headBytes + bi.length
    while c.acc.len < need:
      if timedRead(c) <= 0: return boClosed
    c.req.body = substr(c.acc, c.req.headBytes, need - 1)
    result = boOk
  of bkChunked:
    result = boClosed
    var done = false
    while not done:
      var decoded = ""
      let cr = decodeChunked(c.acc, c.req.headBytes, decoded, gServerConfig.maxBodySize)
      if cr[0] == psOk:
        c.req.body = decoded
        need = c.req.headBytes + cr[1]
        result = boOk
        done = true
      elif cr[0] == psError:
        result = boBad
        done = true
      elif timedRead(c) <= 0:
        done = true

proc shouldClose(req: Request): bool =
  ## An explicit `Connection` header wins; otherwise HTTP/1.1 keeps alive and
  ## HTTP/1.0 closes (RFC 9112 §9.3).
  for h in req.headers:
    if cmpIgnoreCase(h.name, "Connection") == 0:
      if cmpIgnoreCase(h.value, "close") == 0: return true
      if cmpIgnoreCase(h.value, "keep-alive") == 0: return false
  result = req.version == Http10

proc echoHandler(ws: WsConn) {.passive.} =
  ## The WebSocket handler used when none is registered: echoes every data
  ## message. Pings, the close handshake and protocol errors are `wsRecv`'s.
  ## This is what the Autobahn conformance run exercises.
  var running = true
  while running:
    let m = wsRecv(ws)
    if m.kind == wmClose:
      running = false
    elif not wsSend(ws, m.data, m.kind == wmBinary):
      running = false

proc dispatchAsync(req: Request): Response {.passive.} =
  ## The passive request pipeline: pre-dispatch middleware, then the registered
  ## passive handlers in order, then synchronous route dispatch if none claimed
  ## the request, then post-dispatch middleware. Mirrors `router.dispatchFull`.
  let sc = runBefore(appRouter, req)
  if sc.isSome:
    return runAfter(appRouter, req, sc.get(default(Response)))
  var i = 0
  while i < gAsync.len:
    let a = gAsync[i](req)
    if a.isSome:
      return runAfter(appRouter, req, a.get(default(Response)))
    inc i
  result = runAfter(appRouter, req, dispatch(appRouter, req))

proc upgradeToWs(c: Conn; req: Request; ip: string; extraIdx: int) {.passive.} =
  ## The WebSocket upgrade for a request `isWebSocketUpgrade` accepted:
  ## refuse a cross-site origin with 403, else answer 101 and hand the
  ## socket to the handler, the main one or secondary listener `extraIdx`'s.
  ## Returns once the handler returns; the caller closes the fd.
  let t0 = getMonoTime()
  let wsOrigin = header(req, "Origin")
  if not (originAllowed(wsOrigin) or originMatchesHost(wsOrigin, header(req, "Host"))):
    # Cross-site WebSocket hijack guard: refuse before the upgrade.
    reject(c, 403)
    accessLog(ip, 403, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
    return
  if not writeAll(c.fd, handshakeResponse(req)): return
  accessLog(ip, 101, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
  log(info, ip & " connected")
  let ws = newWsConn(c.fd, substr(c.acc, req.headBytes), ip,
                     header(req, "Cookie"), req.target)
  if extraIdx >= 0:
    if extraIdx < gExtra.len:
      # Through a local: a passive proc value called straight off a seq
      # element's field miscompiles (see doc/upstream.md).
      let h = gExtra[extraIdx].handler
      h(ws)
  elif hasWsHandler():
    gWsHandler(ws)
  else:
    echoHandler(ws)
  log(info, ip & " disconnected")

proc respond(c: Conn; req: Request; ip: string): bool {.passive.} =
  ## Dispatch one ordinary request and write its response, timed for the
  ## access log. False when the peer is gone.
  let t0 = getMonoTime()
  var resp = default(Response)
  if hasAsyncHandler():
    resp = dispatchAsync(req)
  else:
    resp = dispatchFull(appRouter, req)
  result = writeAll(c.fd, serialize(resp, req.httpMethod, closing = shouldClose(req)))
  if result:
    accessLog(ip, resp.status, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))

proc serveSse(c: Conn; req: Request; ip: string) {.passive.} =
  ## Hand a matching request to the SSE handler. The pre-dispatch middleware
  ## still runs, so the endpoint is gated like any route; a claim is a
  ## rejection and is sent as an ordinary response. Otherwise the handler
  ## owns the fd until it returns.
  let t0 = getMonoTime()
  let sc = runBefore(appRouter, req)
  if sc.isSome:
    let resp = runAfter(appRouter, req, sc.get(default(Response)))
    discard writeAll(c.fd, serialize(resp, req.httpMethod))
    accessLog(ip, resp.status, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
  else:
    # Logged as 200 at handoff: a stream has no single end status.
    accessLog(ip, 200, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
    gSseHandler(req, c.fd)

proc handleConn(fd: cint; extraIdx: int) {.passive.} =
  ## The keep-alive connection driver; see the module doc for the request
  ## lifecycle. `extraIdx` is -1 on the main listener, else the secondary
  ## WebSocket-only listener the connection arrived on, where only an
  ## upgrade is served and anything else gets 426. Every path ends at the
  ## close at the bottom.
  let c = Conn(fd: fd, peer: peerAddress(fd), acc: "", req: default(Request))
  var keepGoing = true
  while keepGoing:
    keepGoing = false
    case awaitHead(c)
    of hoClosed: discard
    of hoTooBig: reject(c, 431)
    of hoBad: reject(c, 400)
    of hoOk:
      let ip = clientIp(c.req, c.peer)
      if isWebSocketUpgrade(c.req):
        if extraIdx >= 0:
          # Socket peer and attributed client differ behind a proxy; if they
          # match when a proxy was expected, it is missing from
          # `setTrustedProxies`.
          log(debug, "ws-only accept peer=" & c.peer & " effective=" & ip)
        upgradeToWs(c, c.req, ip, extraIdx)
      elif extraIdx >= 0:
        log(info, ip & " ws-only: non-WebSocket " & c.req.httpMethod & " " & c.req.target & " → 426")
        reject(c, 426)
      else:
        var need = 0
        case awaitBody(c, need)
        of boClosed: discard
        of boBad: reject(c, 400)
        of boTooBig: reject(c, 413)
        of boOk:
          c.req.remoteAddress = ip
          c.req.startNanos = getMonoTime().ticks
          if hasSseHandler() and sseMatches(c.req):
            serveSse(c, c.req, ip)
          elif respond(c, c.req, ip):
            # Consume this request's bytes; carry any pipelined leftover.
            dropPrefix(c.acc, need)
            keepGoing = not shouldClose(c.req)
  clearConn(fd)
  closeFd(fd)

# ── listeners and the loop ──────────────────────────────────────────────

proc acceptLoop(listenFd: cint; extraIdx: int) {.passive.} =
  ## Accept on a listener and spawn `handleConn` per connection; `extraIdx`
  ## is -1 for the main listener.
  while true:
    let fd = waitAccept(listenFd)
    if fd >= 0:
      if fd >= MaxFds:
        # connreg's deadline table is indexed by fd, so an fd at or past MaxFds
        # cannot be tracked. Refuse it; this caps concurrent connections.
        log(warn, "refusing fd " & $fd.int & " >= MaxFds " & $MaxFds & " (at connection cap)")
        discard close(fd.cint)
      else:
        setNonBlocking(fd.cint)
        if gServerConfig.tcpNoDelay: setNoDelay(fd.cint)
        setKeepalive(fd.cint, gServerConfig.keepaliveIdleSec, gServerConfig.keepaliveIntvlSec,
                     gServerConfig.keepaliveCnt, gServerConfig.userTimeoutMs)
        spawnTask handleConn(fd.cint, extraIdx)

proc reaperLoop() {.passive.} =
  ## Periodic sweep that shuts down connections stalled past their armed
  ## deadline (`connreg`). Spawned only when an idle timeout is configured.
  var interval = gServerConfig.reapIntervalMs
  if interval <= 0: interval = 1000
  while true:
    sleepMs(interval)
    discard reapExpired(getMonoTime().ticks)

proc listenOrQuit(port: uint16; bindAddr, what: string): cint =
  ## A listening fd for `port`, or a message on stderr and exit 1. Written
  ## synchronously: the log may not have flushed by `quit`.
  let lr = tryListenTcp(port, bindAddr = bindAddr)
  if not lr.ok:
    writeLine(stderr, "hashi http: cannot listen — " & listenError(lr, port))
    quit(1)
  let shown = if bindAddr.len > 0: bindAddr else: "::"
  log(info, "hashi http" & what & " listening on " & shown & ":" & $port.int &
            " (fd=" & $lr.fd.int & ")")
  result = lr.fd

proc serve*(port: uint16; config = gServerConfig; bindAddr = "") =
  ## Serve HTTP/1.1 on `port`: start the loop and block, dispatching each
  ## request through the registered routes (unmatched: 404). Register routes
  ## and handlers before calling it. `config` sets the size caps, timeouts
  ## and socket options (default: whatever `setServerConfig` installed, else
  ## the built-in defaults).
  ##
  ## `bindAddr` is an address literal, never a hostname: "" or "::" for the
  ## dual-stack wildcard, "0.0.0.0" for IPv4 only, or a specific address such
  ## as "127.0.0.1" for loopback only. See `tryListenTcp`.
  setServerConfig(config)
  ignoreSigpipe()
  initLoop()
  let listenFd = listenOrQuit(port, bindAddr, "")
  spawnTask acceptLoop(listenFd, -1)
  for e in 0 ..< gExtra.len:
    let efd = listenOrQuit(gExtra[e].port, gExtra[e].bindAddr, " (ws-only)")
    spawnTask acceptLoop(efd, e)
  if hasBootTask(): spawnTask bootRunner()
  if gServerConfig.idleTimeoutMs > 0:
    log(info, "hashi http: idle reaper on (idle=" & $gServerConfig.idleTimeoutMs & "ms)")
    spawnTask reaperLoop()
  runLoop()

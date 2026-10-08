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
## registered with `setSseHandler`; both pass the pre-dispatch middleware
## first.
##
## A rejection the client may still be sending into ends in a lingering
## close rather than an immediate one, so the response is not lost to a
## reset: see `handleConn` and `ServerConfig.lingerMs`.
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
from hashi/ws/protocol import assembledLen
import hashi/ws/session
import hashi/ws/session_io
import hashi/sse/session
import hashi/log
import hashi/bootcfg
import hashi/loop
import hashi/buffer

# ── registries ──────────────────────────────────────────────────────────

var appRouter: Frozen[Router]
  ## The process-global `Router` the connection driver dispatches through.

proc routerView(): ptr Router = view(appRouter)

proc addRoute*(meth, path: string; h: Handler) =
  ## Register `h` for `meth path`. See `hashi/http/router` for matching rules.
  addRoute(edit(appRouter)[], meth, path, h)

proc get*(path: string; h: Handler) =
  ## Register `h` for `GET path`.
  get(edit(appRouter)[], path, h)

proc post*(path: string; h: Handler) =
  ## Register `h` for `POST path`.
  post(edit(appRouter)[], path, h)

proc put*(path: string; h: Handler) =
  ## Register `h` for `PUT path`.
  put(edit(appRouter)[], path, h)

proc delete*(path: string; h: Handler) =
  ## Register `h` for `DELETE path`.
  delete(edit(appRouter)[], path, h)

proc head*(path: string; h: Handler) =
  ## Register `h` for `HEAD path`. Without one, a GET route answers HEAD.
  head(edit(appRouter)[], path, h)

proc options*(path: string; h: Handler) =
  ## Register `h` for `OPTIONS path`.
  options(edit(appRouter)[], path, h)

proc patch*(path: string; h: Handler) =
  ## Register `h` for `PATCH path`.
  patch(edit(appRouter)[], path, h)

proc setErrorHandler*(h: ErrorHandler) =
  ## Register the error handler: when a handler raises an `ErrorCode`, this
  ## maps it to the `Response` sent (default: `errorCodeToHttp`).
  setErrorHandler(edit(appRouter)[], h)

proc setNotFoundHandler*(h: Handler) =
  ## Register the fallback handler, invoked when no route matches. It is tried
  ## last regardless of registration order, unlike a greedy `get("/**", …)`
  ## route, which would shadow every route registered after it.
  setNotFound(edit(appRouter)[], h)

proc addBeforeMiddleware*(m: BeforeMiddleware) =
  ## Append a pre-dispatch middleware. See `hashi/http/router`. The chain
  ## runs for routes, SSE requests and WebSocket upgrades on the main
  ## listener, where a claim refuses the upgrade; it does not run on
  ## `addWsListener` listeners.
  addBefore(edit(appRouter)[], m)

proc addAfterMiddleware*(m: AfterMiddleware) =
  ## Append a post-dispatch middleware, e.g. one that adds security headers.
  addAfter(edit(appRouter)[], m)

proc setBeforeMiddleware*(m: seq[BeforeMiddleware]) =
  ## Replace the whole pre-dispatch chain. Its coverage is as for
  ## `addBeforeMiddleware`.
  setBefore(edit(appRouter)[], m)

proc setAfterMiddleware*(m: seq[AfterMiddleware]) =
  ## Replace the whole post-dispatch chain.
  setAfter(edit(appRouter)[], m)

type AsyncHandler* = proc (req: Request): Opt[Response] {.passive.}
  ## A request handler that may suspend on outbound I/O without blocking the
  ## reactor. Registered handlers run after the pre-dispatch middleware and
  ## before the synchronous routes: returning `some(resp)` claims the request,
  ## `none` falls through to route dispatch.

var gAsync: Frozen[seq[AsyncHandler]]

proc addAsyncHandler*(h: AsyncHandler) =
  ## Append a passive handler to the chain. Handlers are tried in registration
  ## order and the first to return `some` claims the request. Call before
  ## `serve`.
  edit(gAsync)[].add h

proc hasAsyncHandler*(): bool =
  result = view(gAsync)[].len > 0

proc asyncHandlerCount*(): int =
  ## Number of registered passive handlers.
  result = view(gAsync)[].len

type BootTask* = proc () {.passive.}
  ## A one-shot `.passive` task run on the reactor once the listener is up,
  ## for startup work that needs the reactor (see `setBootTask`).
var gBootTask: Frozen[nil BootTask]

proc setBootTask*(t: BootTask) =
  ## Register a single `.passive` task to run once on the reactor right after the
  ## listener comes up. Replaces any prior task.
  publish(gBootTask, t)

proc hasBootTask*(): bool = snapshot(gBootTask) != nil

proc bootRunner() {.passive.} =
  ## Drives the registered boot task; spawned by `serve` when one is set.
  let t = snapshot(gBootTask)
  if t != nil: t()

const MaxExtraListeners* = 8
  ## Capacity of the secondary WebSocket-only listener table (`addWsListener`).

type Listener = object
  port: uint16
  bindAddr: string
  handler: WsHandler

var gExtra: Frozen[seq[Listener]]

proc addWsListener*(port: uint16; handler: WsHandler; bindAddr = ""): bool =
  ## Register an additional WebSocket-only listener on `port`/`bindAddr`, served
  ## on the same reactor with its own `handler`. The main listener's routes,
  ## WebSocket handler, SSE handler and pre-dispatch middleware are not
  ## reachable on it (a non-WebSocket request gets 426), so a separate port
  ## or interface is its own trust domain. Call before `serve`. Returns false
  ## once `MaxExtraListeners` are registered. `bindAddr` takes the same
  ## literals as `serve`: "" (the default) listens on 127.0.0.1 and ::1 only.
  let table = edit(gExtra)
  if table[].len >= MaxExtraListeners: return false
  table[].add Listener(port: port, bindAddr: bindAddr, handler: handler)
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
    bodyPos: int                ## chunked body: bytes of `acc` already decoded
    hb: HeadBuf                 ## each response's head, written in place
    linger: bool                ## end with a lingering close (see `handleConn`)

  HeadOutcome = enum
    hoOk        ## `c.req` holds a complete head
    hoClosed    ## the peer went away
    hoTooBig    ## the head, through its CRLFCRLF, exceeds `maxRequestHead` bytes
    hoBad       ## malformed
    hoMore      ## incomplete, and nothing more has arrived yet

  BodyOutcome = enum
    boOk        ## `c.req.body` is filled; `need` is the request's total length
    boClosed
    boBad       ## ambiguous framing or a malformed chunked body
    boTooBig    ## Content-Length over `maxBodySize`
    boMore      ## incomplete, and nothing more has arrived yet

proc fillNow(c: Conn): int =
  ## Append to `c.acc` what has already arrived: `readNow`'s answer.
  result = readNow(c.fd, addr c.rbuf[0], c.rbuf.len)
  if result > 0:
    addInflight(result)
    appendBytes(c.acc, addr c.rbuf[0], result)

proc waitFill(c: Conn): int {.passive.} =
  ## Wait on the ring for the next read into `c.acc`, with the idle deadline
  ## (`ServerConfig.idleTimeoutMs`) armed for the duration of the wait. Any
  ## inbound byte resets the window, so only a silent peer is reaped. Writes
  ## are deliberately untimed: under TCP flow control a slow-but-alive reader
  ## is indistinguishable from a stalled one, and dead-peer detection on the
  ## write side is `TCP_USER_TIMEOUT`'s job (see `setKeepalive`).
  let w = serverConfigView()[].idleTimeoutMs
  if w > 0: setDeadline(c.fd, getMonoTime().ticks + w.int64 * 1_000_000'i64)
  result = waitRead(c.fd, addr c.rbuf[0], c.rbuf.len)
  if w > 0: setDeadline(c.fd, 0'i64)
  if result > 0:
    addInflight(result)
    appendBytes(c.acc, addr c.rbuf[0], result)

proc lingersAfter(status: int): bool =
  ## The rejections a client may still be sending into: a body or head over
  ## its cap, a request on a WebSocket-only listener, a refused origin.
  status == 413 or status == 431 or status == 426 or status == 403

proc reject(c: Conn; status: int) {.passive.} =
  ## Answer `status` with an empty body and `Connection: close`; the caller
  ## ends the connection. Once the whole response is written, a 413, 431,
  ## 426 or 403 marks the connection to linger; a 400 does not, since the
  ## client's framing is already in doubt.
  if writeAll(c.fd, serialize(newResponse(status), closing = true)) and lingersAfter(status):
    c.linger = true

proc sentMore(c: Conn; consumed: int): bool =
  ## Whether the client sent more than the `consumed` bytes of its request:
  ## they are buffered, or waiting on the socket.
  c.acc.len > consumed or hasPendingInput(c.fd)

proc headNow(c: Conn): HeadOutcome =
  ## Parse a request head into `c.req` from what `c.acc` holds and what has
  ## already arrived; `hoMore` when the head is incomplete and the socket is
  ## empty. `hoTooBig` when the head, through its CRLFCRLF, is longer than
  ## `maxRequestHead`: `c.acc` reaches the cap without one, or a complete
  ## head ends past it.
  clear(c.req)
  let cap = serverConfigView()[].maxRequestHead
  var st = parseRequestHead(c.acc, c.req)
  while st == psIncomplete and c.acc.len < cap:
    let n = fillNow(c)
    if n == ReadLater: return hoMore
    if n <= 0: return hoClosed
    st = parseRequestHead(c.acc, c.req)
  case st
  of psOk:
    if c.req.headBytes > cap:
      result = hoTooBig
    else:
      c.bodyPos = c.req.headBytes      # the chunked decode resumes past the head
      result = hoOk
  of psError: result = hoBad
  of psIncomplete: result = hoTooBig

proc awaitHead(c: Conn): HeadOutcome {.passive.} =
  ## `headNow`, waiting on the ring while the head is incomplete: a full head
  ## of at most `maxRequestHead` bytes in `c.req`, or the peer closed, or
  ## `hoTooBig`.
  result = headNow(c)
  while result == hoMore:
    if waitFill(c) <= 0: return hoClosed
    result = headNow(c)

proc bodyNow(c: Conn; need: var int): BodyOutcome =
  ## Decode the body `c.req`'s headers frame into `c.req.body` from what
  ## `c.acc` holds and what has already arrived; `boMore` when it is
  ## incomplete and the socket is empty. `need` becomes how many bytes of
  ## `c.acc` the whole request occupies.
  let bi = bodyFraming(c.req)
  need = c.req.headBytes
  case bi.kind
  of bkError:
    result = boBad
  of bkNone:
    result = boOk
  of bkLength:
    if bi.length > serverConfigView()[].maxBodySize: return boTooBig
    need = c.req.headBytes + bi.length
    while c.acc.len < need:
      let n = fillNow(c)
      if n == ReadLater: return boMore
      if n <= 0: return boClosed
    c.req.body = substr(c.acc, c.req.headBytes, need - 1)
    result = boOk
  of bkChunked:
    # Resume, don't restart: each pass decodes only the chunks the latest
    # read completed, so a body arriving in N reads costs one pass.
    result = boClosed
    var pos = c.bodyPos
    var done = false
    while not done:
      let cr = decodeChunked(c.acc, pos, c.req.body, serverConfigView()[].maxBodySize)
      if cr[0] == psOk:
        need = pos + cr[1]
        result = boOk
        done = true
      elif cr[0] == psError:
        result = boBad
        done = true
      else:
        pos = pos + cr[1]
        c.bodyPos = pos
        let n = fillNow(c)
        if n == ReadLater:
          result = boMore
          done = true
        elif n <= 0:
          done = true

proc awaitBody(c: Conn; need: var int): BodyOutcome {.passive.} =
  ## `bodyNow`, waiting on the ring while the body is incomplete.
  result = bodyNow(c, need)
  while result == boMore:
    if waitFill(c) <= 0: return boClosed
    result = bodyNow(c, need)

proc shouldClose(req: Request): bool =
  ## An explicit `Connection` header wins; otherwise HTTP/1.1 keeps alive and
  ## HTTP/1.0 closes (RFC 9112 §9.3).
  for h in req.headers:
    if eqIgnoreCase(h.name, "Connection"):
      if eqIgnoreCase(h.value, "close"): return true
      if eqIgnoreCase(h.value, "keep-alive"): return false
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
  let sc = runBefore(routerView()[], req)
  if sc.isSome:
    return runAfter(routerView()[], req, sc.get(default(Response)))
  let chain = view(gAsync)
  var i = 0
  while i < chain[].len:
    let a = chain[][i](req)
    if a.isSome:
      return runAfter(routerView()[], req, a.get(default(Response)))
    inc i
  result = runAfter(routerView()[], req, dispatch(routerView()[], req))

proc upgradeToWs(c: Conn; req: Request; ip: string; extraIdx: int) {.passive.} =
  ## The WebSocket upgrade for a request `isWebSocketUpgrade` accepted:
  ## refuse a cross-site origin with 403; on the main listener (`extraIdx`
  ## -1) run the pre-dispatch middleware, whose claim is sent with
  ## `Connection: close` in place of the upgrade; else answer 101 and hand
  ## the socket to the handler, the main one or secondary listener
  ## `extraIdx`'s, which skips the middleware. Returns once the handler
  ## returns or the upgrade is refused; the caller closes the fd.
  let t0 = getMonoTime()
  let wsOrigin = header(req, "Origin")
  if not (originAllowed(wsOrigin) or originMatchesHost(wsOrigin, header(req, "Host"))):
    # Cross-site WebSocket hijack guard: refuse before the upgrade.
    reject(c, 403)
    accessLog(ip, 403, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
    return
  if extraIdx < 0:
    let sc = runBefore(routerView()[], req)
    if sc.isSome:
      let resp = runAfter(routerView()[], req, sc.get(default(Response)))
      # A claim lingers only when the client sent more than the upgrade
      # request: frames written ahead of the 101 they expected.
      if writeAll(c.fd, serialize(resp, req.httpMethod, closing = true)) and
         sentMore(c, req.headBytes):
        c.linger = true
      accessLog(ip, resp.status, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
      return
  if not writeAll(c.fd, handshakeResponse(req)): return
  accessLog(ip, 101, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
  log(info, ip & " connected")
  let ws = newWsConn(c.fd, substr(c.acc, req.headBytes), ip,
                     header(req, "Cookie"), req.target)
  # The connection's bytes now live in `ws.acc` (a copy of the leftover);
  # the count moves with them, and the driver's buffer releases whole.
  subInflight(c.acc.len)
  c.acc.setLen(0)
  addInflight(ws.acc.len)
  if extraIdx >= 0:
    let extras = view(gExtra)
    if extraIdx < extras[].len:
      # Through a local: a passive proc value called straight off a seq
      # element's field miscompiles (see doc/upstream.md).
      let h = extras[][extraIdx].handler
      h(ws)
  elif hasWsHandler():
    let h = wsHandler()
    h(ws)
  else:
    echoHandler(ws)
  # Whatever the handler left buffered is released: unparsed frames and a
  # message part-way assembled.
  subInflight(ws.acc.len + assembledLen(ws.st))
  log(info, ip & " disconnected")

proc unsent(c: Conn; headLen: int; body: string; sent: int): string =
  ## The bytes of head-then-body that a partial gather write left behind.
  result = newStringOfCap(headLen + body.len - sent)
  var i = sent
  while i < headLen:
    result.add c.hb.data[i]
    i = i + 1
  result.add substr(body, max(0, sent - headLen))

proc sendNow(c: Conn; resp: Response; httpMethod: string; closing: bool;
             rest: var string): int =
  ## Write `resp` to the connection as far as the socket takes it: the head
  ## from `c.hb` and the body in one gather write. 1 when all of it went, -1
  ## when the peer is gone, 0 with the unsent bytes in `rest` otherwise.
  let headLen = serializeHead(c.hb, resp, httpMethod, closing = closing)
  if headLen < 0:
    rest = serialize(resp, httpMethod, closing = closing)
    return 0
  let body = if sendsBody(resp, httpMethod): resp.body else: ""
  let sent = writevNow(c.fd, addr c.hb.data[0], headLen, body)
  if sent < 0: result = -1
  elif sent == headLen + body.len: result = 1
  else:
    rest = unsent(c, headLen, body, sent)
    result = 0

proc respond(c: Conn; req: Request; ip: string): bool {.passive.} =
  ## Dispatch one ordinary request and write its response, timed for the
  ## access log. False when the peer is gone.
  let t0 = getMonoTime()
  var resp = default(Response)
  if hasAsyncHandler():
    resp = dispatchAsync(req)
  else:
    resp = route(routerView()[], c.req)
  var rest = ""
  let st = sendNow(c, resp, req.httpMethod, shouldClose(req), rest)
  result = if st == 0: writeAll(c.fd, rest) else: st > 0
  if result:
    accessLog(ip, resp.status, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))

proc serveSse(c: Conn; req: Request; ip: string; need: int) {.passive.} =
  ## Hand a matching request to the SSE handler. The pre-dispatch middleware
  ## still runs, so the endpoint is gated like any route; a claim is a
  ## rejection, sent with `Connection: close`, which lingers when the client
  ## sent more than the request's `need` bytes. Otherwise the handler owns
  ## the fd until it returns.
  let t0 = getMonoTime()
  let sc = runBefore(routerView()[], req)
  if sc.isSome:
    let resp = runAfter(routerView()[], req, sc.get(default(Response)))
    if writeAll(c.fd, serialize(resp, req.httpMethod, closing = true)) and
       sentMore(c, need):
      c.linger = true
    accessLog(ip, resp.status, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
  else:
    # Logged as 200 at handoff: a stream has no single end status.
    accessLog(ip, 200, req.httpMethod, req.target, int((getMonoTime() - t0).inMicroseconds))
    let h = sseHandler()
    h(req, c.fd)

const LingerReadBudget = 65536
  ## Most bytes a lingering connection discards per wake before it polls
  ## again, so a flooding client yields its worker between batches.

proc discardNow(c: Conn): bool =
  ## Read and drop what has arrived, up to `LingerReadBudget` bytes. True to
  ## keep lingering: some bytes came and the socket ran dry, or the budget
  ## ran out. False at EOF, on an error, or when the wake found nothing, so
  ## a readiness that yields no bytes cannot spin.
  result = true
  var got = 0
  var going = true
  while going:
    let n = readNow(c.fd, addr c.rbuf[0], c.rbuf.len)
    if n > 0:
      got = got + n
      if got >= LingerReadBudget: going = false
    elif n == ReadLater:
      if got == 0: result = false
      going = false
    else:
      result = false
      going = false

proc lingerWaitMs(t0: MonoTime): int =
  ## The next readiness wait of a linger begun at `t0`: the idle bound,
  ## clipped to what is left of `lingerMs` and to at least 1 ms; 0 once
  ## `lingerMs` has passed.
  let remaining = serverConfigView()[].lingerMs - int((getMonoTime() - t0).inMilliseconds)
  result = if remaining <= 0: 0 else: max(1, min(serverConfigView()[].lingerIdleMs, remaining))

proc drainLinger(c: Conn) {.passive.} =
  ## Read and discard what the client still sends, until it closes, errors,
  ## goes `lingerIdleMs` without sending, or `lingerMs` has passed since the
  ## start. Bounded by time only, not by bytes. The bytes are never counted
  ## in flight: they are not buffered past the read.
  let t0 = getMonoTime()
  var going = true
  while going:
    let ms = lingerWaitMs(t0)
    if ms <= 0:
      going = false
    elif waitReadableUntil(c.fd, ms) < 0:
      going = false      # timed out (idle, or lingerMs is up) or the wait failed
    else:
      going = discardNow(c)

proc handleConn(fd: cint; extraIdx: int) {.passive.} =
  ## The keep-alive connection driver; see the module doc for the request
  ## lifecycle. `extraIdx` is -1 on the main listener, else the secondary
  ## WebSocket-only listener the connection arrived on, where only an
  ## upgrade is served and anything else gets 426. Every path ends at the
  ## close at the bottom.
  ##
  ## A connection marked to linger (see `reject`, `upgradeToWs` and
  ## `serveSse`) closes gracefully when `lingerMs` is set and a slot is free
  ## under `lingerCap`: its buffers are released, the write side is shut
  ## down so the client reads the response and then EOF, and what the client
  ## still sends is discarded until it closes, goes `lingerIdleMs` silent or
  ## `lingerMs` passes. Closing at once instead, with unread bytes in the
  ## receive queue, makes the kernel send a reset that can destroy the
  ## response before the client reads it. Any other end closes at once.
  let c = Conn(fd: fd, peer: peerAddress(fd), acc: "", req: default(Request))
  # Only a trusted proxy's forwarded headers change the client address, so
  # for any other peer it is settled here rather than per request.
  let viaProxy = isTrustedProxy(c.peer)
  let peerIp = if viaProxy: "" else: attributedClientIp(c.peer, @[], "")
  var keepGoing = true
  while keepGoing:
    keepGoing = false
    var ho = headNow(c)
    let waited = ho == hoMore
    if waited: ho = awaitHead(c)
    case ho
    of hoClosed, hoMore: discard     # awaitHead never answers hoMore
    of hoTooBig: reject(c, 431)
    of hoBad: reject(c, 400)
    of hoOk:
      let ip = if viaProxy: clientIp(c.req, c.peer) else: peerIp
      c.req.remoteAddress = ip
      if isWebSocketUpgrade(c.req):
        if extraIdx >= 0:
          # Socket peer and attributed client differ behind a proxy; if they
          # match when a proxy was expected, it is missing from
          # `setTrustedProxies`.
          log(debug, "ws-only accept peer=" & c.peer & " effective=" & ip)
        c.req.startNanos = getMonoTime().ticks
        upgradeToWs(c, c.req, ip, extraIdx)
      elif extraIdx >= 0:
        log(info, ip & " ws-only: non-WebSocket " & c.req.httpMethod & " " & c.req.target & " → 426")
        reject(c, 426)
      else:
        var need = 0
        var bo = bodyNow(c, need)
        if bo == boMore: bo = awaitBody(c, need)
        case bo
        of boClosed, boMore: discard   # awaitBody never answers boMore
        of boBad: reject(c, 400)
        of boTooBig: reject(c, 413)
        of boOk:
          c.req.startNanos = getMonoTime().ticks
          if hasSseHandler() and sseMatches(c.req):
            serveSse(c, c.req, ip, need)
          elif respond(c, c.req, ip):
            # Consume this request's bytes; carry any pipelined leftover.
            dropPrefix(c.acc, need)
            subInflight(need)
            keepGoing = not shouldClose(c.req)
            # A request that found its bytes already waiting ran without
            # suspending; yield once so a busy connection cannot hold the
            # worker from the others queued on it.
            if keepGoing and not waited: yieldTask()
  subInflight(c.acc.len)   # bytes never parsed leave the count here
  when defined(posix):
    if c.linger and serverConfigView()[].lingerMs > 0 and tryEnterLinger():
      c.acc = ""
      clear(c.req)
      shutdownWrite(fd)
      drainLinger(c)
      leaveLinger()
  clearConn(fd)
  closeFd(fd)

# ── listeners and the loop ──────────────────────────────────────────────

proc acceptLoop(listenFd: cint; extraIdx: int) {.passive.} =
  ## Accept on one listening fd and spawn `handleConn` per connection;
  ## `extraIdx` is -1 for the main listener. A listener on "" has two fds,
  ## each with its own loop and the same `extraIdx`.
  while true:
    let fd = waitAccept(listenFd)
    if fd >= 0:
      if fd >= MaxFds:
        # connreg's deadline table is indexed by fd, so an fd at or past MaxFds
        # cannot be tracked. Refuse it; this caps concurrent connections.
        log(warn, "refusing fd " & $fd.int & " >= MaxFds " & $MaxFds & " (at connection cap)")
        discard close(fd.cint)
      elif serverConfigView()[].maxInflightBytes > 0 and
           inflightBytes() >= serverConfigView()[].maxInflightBytes:
        # The aggregate cap: per-connection caps bound one connection, this
        # bounds all of them. Bytes already buffered by live connections
        # outgrow the budget; new ones are refused, not queued.
        log(warn, "refusing connection: " & $serverConfigView()[].maxInflightBytes &
            " bytes already buffered across connections")
        discard writeAll(fd.cint, serialize(newResponse(503), closing = true))
        discard close(fd.cint)
      else:
        setNonBlocking(fd.cint)
        if serverConfigView()[].tcpNoDelay: setNoDelay(fd.cint)
        setKeepalive(fd.cint, serverConfigView()[].keepaliveIdleSec, serverConfigView()[].keepaliveIntvlSec,
                     serverConfigView()[].keepaliveCnt, serverConfigView()[].userTimeoutMs)
        spawnTask handleConn(fd.cint, extraIdx)

proc reaperLoop() {.passive.} =
  ## Periodic sweep that shuts down connections stalled past their armed
  ## deadline (`connreg`). Spawned only when `idleTimeoutMs` or
  ## `wsIdleTimeoutMs` is set: the WebSocket idle close arms a deadline as
  ## the backstop for its own CLOSE.
  var interval = serverConfigView()[].reapIntervalMs
  if interval <= 0: interval = 1000
  while true:
    sleepMs(interval)
    discard reapExpired(getMonoTime().ticks)

proc hostPort(address: string; port: uint16): string =
  ## `address`:`port` for an operator, an IPv6 address in brackets.
  if find(address, ':') >= 0: result = "[" & address & "]:" & $port.int
  else: result = address & ":" & $port.int

proc listening(what, at: string; fd: cint) =
  log(info, "hashi http" & what & " listening on " & at & " (fd=" & $fd.int & ")")

proc cannotListen(what, at: string; r: ListenResult; port: uint16) =
  ## Exit 1 with the failure on stderr, written synchronously: the log may
  ## not have flushed by `quit`.
  writeLine(stderr, "hashi http" & what & ": cannot listen on " & at & " — " &
                    listenError(r, port))
  quit(1)

proc listenOrQuit(port: uint16; bindAddr, what: string): seq[cint] =
  ## The listening fds for `port`, each bound address logged: one fd for an
  ## address literal; for "", 127.0.0.1 and ::1, or 127.0.0.1 alone with a
  ## warning when the host has no IPv6 loopback. Any other failure exits 1.
  result = @[]
  if bindAddr.len == 0:
    let p = listenLoopbackPair(port)
    if not p.v4.ok:
      if p.v4.stage.len > 0: cannotListen(what, hostPort("127.0.0.1", port), p.v4, port)
      else: cannotListen(what, hostPort("::1", port), p.v6, port)
    result.add p.v4.fd
    listening(what, hostPort("127.0.0.1", port), p.v4.fd)
    if p.v6.ok:
      result.add p.v6.fd
      listening(what, hostPort("::1", port), p.v6.fd)
    else:
      log(warn, "hashi http" & what & ": no IPv6 loopback, listening on 127.0.0.1 only — " &
                listenError(p.v6, port))
  else:
    let lr = tryListenTcp(port, bindAddr = bindAddr)
    if not lr.ok: cannotListen(what, hostPort(bindAddr, port), lr, port)
    result.add lr.fd
    listening(what, hostPort(bindAddr, port), lr.fd)

proc serve*(port: uint16; config = serverConfig(); bindAddr = "") =
  ## Serve HTTP/1.1 on `port`: start the loop and block, dispatching each
  ## request through the registered routes (unmatched: 404). Register routes
  ## and handlers before calling it. `config` sets the size caps, timeouts
  ## and socket options (default: whatever `setServerConfig` installed, else
  ## the built-in defaults).
  ##
  ## `bindAddr` is an address literal, never a hostname. "" (the default)
  ## listens on 127.0.0.1 and ::1, so the server is reachable from this host
  ## only; without IPv6 loopback it warns and listens on 127.0.0.1 alone.
  ## "::" is every interface, dual-stack; "0.0.0.0" every IPv4 interface;
  ## any other literal, such as "192.0.2.10", that address alone. See
  ## `tryListenTcp` and `listenLoopbackPair`. Every bound address is logged.
  ##
  ## Once the config is validated `serve` seals the boot registries (routes,
  ## middleware, handlers, `setServerConfig`, `setTrustedProxies`,
  ## `setAllowedOrigins`, `addWsListener`): a registration after that writes a
  ## FATAL line to stderr and aborts.
  ##
  ## A config `validateServerConfig` rejects, or a `setTrustedProxies` entry
  ## `trustedProxyFaults` reports, is logged at error level and the process
  ## exits 1 before anything listens.
  let bad = validateServerConfig(config)
  if bad.len > 0:
    log(LogLevel.error, "hashi http: invalid server config — " & bad)
    quit(1)
  let badProxies = trustedProxyFaults()
  if badProxies.len > 0:
    log(LogLevel.error, "hashi http: invalid trusted proxies — " & badProxies)
    quit(1)
  setServerConfig(config)
  sealBootConfig()
  let nofile = openFileLimit()
  setLingerCap((if nofile > 0: min(MaxFds, nofile) else: MaxFds) div 4)
  ignoreSigpipe()
  initLoop()
  let mainFds = listenOrQuit(port, bindAddr, "")
  for i in 0 ..< mainFds.len:
    let fd = mainFds[i]
    spawnTask acceptLoop(fd, -1)
  let extras = view(gExtra)
  for e in 0 ..< extras[].len:
    let extraFds = listenOrQuit(extras[][e].port, extras[][e].bindAddr, " (ws-only)")
    for i in 0 ..< extraFds.len:
      let fd = extraFds[i]
      spawnTask acceptLoop(fd, e)
  if hasBootTask(): spawnTask bootRunner()
  if serverConfigView()[].idleTimeoutMs > 0 or serverConfigView()[].wsIdleTimeoutMs > 0:
    log(info, "hashi http: idle reaper on (idle=" & $serverConfigView()[].idleTimeoutMs &
              "ms, ws idle=" & $serverConfigView()[].wsIdleTimeoutMs & "ms)")
    spawnTask reaperLoop()
  runLoop()

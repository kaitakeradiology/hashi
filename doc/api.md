# API guide

How the pieces fit and which module to import for what. The per-symbol
reference is generated from the source with `doc/gen` (into `htmldocs/`);
this guide covers the shape of the API and the rules that span modules.
The runnable programs in [`examples/`](../examples/) show each part in use.

## Imports

`import hashi` brings in the whole application-facing API. The modules
behind it can be imported individually for a narrower surface:

```nim
import hashi/http/server      # serve, route registration, the handler seams
import hashi/http/request     # Request, Response, newResponse, accessors
import hashi/http/config      # ServerConfig, if you override limits
import hashi/http/multipart   # parseMultipart, for file uploads
import hashi/ws/session       # WsConn, WsMessage, setWsHandler
import hashi/ws/session_io    # wsRecv, wsSend, wsClose, wsPeek, wsSkip
import hashi/ws/outq          # the optional outbound queue
import hashi/ws/outq_writer   # its writer loop and producer waits
import hashi/sse/session      # setSseHandler
import hashi/loop     # waitRead, waitWrite for handlers that own a socket
```

Logging goes through `hashi/log`: `logLevel` filters, and `setLogCallback`
routes records to the application's logger instead of stderr. The internals
(`hashi/net`, the frame codec, the protocol state machine)
are not re-exported by `hashi`; import them explicitly if you need them.

## Why not `std/httpserver`

Nimony's stdlib has an HTTP/1.1 server layer of its own (`std/socket`,
`std/http/*`, `std/httpserver`). Hashi keeps its own parser, serializer and
driver for now: the stdlib stack is new and unbenchmarked against hashi's
numbers, its message module imports the compiler's NIF library so a
consumer would be tied to the nimony source tree, and its listen call is
IPv4-only. Rebasing the driver on it is a post-release evaluation gated on
the benchmark; everything above the driver (routing, WebSocket, SSE, the
queue) is unaffected either way.

## Concurrency

Handlers resume on `std/ioring`'s worker pool; there is no single dispatcher
thread. Several handlers run at once on different threads, so any state
shared between handlers (a table, a counter, a cache) needs a lock. State
local to one handler is safe: one continuation runs in one place at a time.

`.passive` procs are sequential code that suspends at I/O. Two Nimony
constraints to write around: a `for` loop cannot contain a suspension
point, so use `while`; and a `.passive` proc cannot take `var`, `openArray`
or `varargs` parameters, which is why `WsConn` is a `ref` and `wsSend` takes
`seq[byte]`.

## HTTP

`serve(port)` starts the loop and blocks. Register everything before
calling it. `serve(port, config)` sets a `ServerConfig` first; `bindAddr`
is an address literal (`""` or `"::"` for dual-stack, `"0.0.0.0"` for IPv4
only, `"127.0.0.1"` for loopback). A listen failure prints one line to
stderr and exits 1.

**Routes.** `get`, `post`, `put`, `delete`, `head`, `options`, `patch` and
`addRoute` register a `Handler` on the process-global router. Matching is
per path segment: a literal, `:name` (captured, read with `pathParam`),
`*` (one segment) or `**` (the rest). The query string is ignored for
matching, the first registered match wins, a path match with no method
match answers 405, and `HEAD` falls back to the `GET` route with the body
suppressed. `setNotFoundHandler` installs a fallback tried after every
route, which is where an SPA's `index.html` belongs.

**Handlers** are `proc(req: Request): Response {.nimcall, raises.}`. Build
the response with `newResponse(status, body)` and append to
`resp.headers`. Serialisation adds `Date` and `Content-Length`, omits the
body for `HEAD` and bodyless statuses, and strips CR and LF from header
values.

**Request** exposes `path` (percent-decoded), `query`, `queryParams`,
`queryParam`, `header`, `headers`, `hasHeader`, `pathParam`, `body`
(decoded, whether Content-Length or chunked), `remoteAddress` and
`startNanos` (monotonic request start, for latency in after-middleware).

**Middleware.** `addBeforeMiddleware` runs before route matching; returning
`some(resp)` short-circuits, and that response still passes through the
after-chain. `addAfterMiddleware` sees every response, including errors,
and is the place for security headers. Middleware must not raise.

**Passive handlers.** `addAsyncHandler` appends a
`proc(req: Request): Opt[Response] {.passive.}` that may suspend on
outbound I/O. The chain runs after the before-middleware and before the
routes; the first handler to return `some` claims the request.
`setBootTask` registers one `.passive` task to run once the listener is
up, for startup work that needs the reactor.

**Errors.** A handler may `raise` an `ErrorCode`; dispatch maps it to a
status with `errorCodeToHttp`, or with the `setErrorHandler` hook, and the
connection stays up. Defects (bounds, overflow, nil) are not catchable and
abort the process, which is why the parsers are fuzzed. See
[`error-handling.md`](error-handling.md).

**Limits and timeouts** live in `ServerConfig`: request-head and body
caps, WebSocket payload and message caps, Nagle, kernel keepalive, and the
idle reaper that shuts down a connection blocked on a read with no inbound
bytes. Writes are never timed by the application; a stalled peer on the
write side is the kernel's job via `TCP_USER_TIMEOUT`.

**Client IP.** `setTrustedProxies` names the direct peers whose
`X-Real-IP` and `X-Forwarded-For` are honoured. With none configured, the
socket peer is the client.

## WebSocket

Register a `proc(ws: WsConn) {.passive.}` with `setWsHandler`. After a
successful upgrade the server calls it with a fresh `WsConn`; it owns the
connection until it returns. Loop on `ws.open`, read with `wsRecv`, write
with `wsSend`, and stop on `wmClose`. Ping, pong and the close handshake
are handled inside `wsRecv`. `ws.cookie` and `ws.path` carry the upgrade
request's cookie header and target, since the handler never sees the
`Request`. With no handler registered the server runs an echo loop, which
is what the Autobahn run exercises.

`wsPeek` looks at the next complete message without blocking and stashes
it; `wsSkip` discards the stash. `setAllowedOrigins` refuses upgrades from
a browser `Origin` that is neither same-origin nor listed.

**Several tasks, one socket.** A connection written by more than one task
(a reply handler plus a background stream, say) goes into queued mode:
`useOutQueue(ws, newOutQueue())` at accept, then `spawnTask
wsWriterLoop(ws, q)` as its own task, producers calling `wsEnqueue` and
parking in `wsAwaitSpace` on `eqFull`, and `wsAwaitWriterDone` before the
handler returns. The queue has three lanes drained in priority order, so a
control message never waits behind a stream backlog, and it caps the
socket send buffer so the backlog stays in the queue where lanes mean
something. Every lane is bounded: STREAM and CONTROL by a byte budget each
(`eqFull`, then `wsAwaitSpace(q, lane)`), URGENT by keeping only the latest
PONG. `examples/ws_queued.nim` is the worked example.

**Secondary listeners.** `addWsListener(port, handler)` serves an extra
WebSocket-only listener on the same reactor. Routes, SSE and the main
WebSocket handler are not reachable there, so a separate port or interface
is its own trust domain.

## Server-Sent Events

`setSseHandler(match, handler)` pairs a predicate with a
`proc(req: Request; fd: cint) {.passive.}`. For a matching request the
before-middleware runs first, so the endpoint is gated like any route;
then the handler owns the fd, writes its own `200 text/event-stream` head
and events with `waitWrite`, and returns when the stream ends.

## Multipart

`parseMultipart(req)` reads the boundary from `Content-Type` and returns
the parts of a `multipart/form-data` body (RFC 7578). Malformed input stops
the parse and returns the parts read cleanly so far; nothing raises.

## Examples

- [`hello.nim`](../examples/hello.nim): two routes and the access log.
- [`routing.nim`](../examples/routing.nim): path params, wildcards, verbs,
  405 versus 404, query parsing, raising `NameNotFound`.
- [`configured.nim`](../examples/configured.nim): overriding `ServerConfig`.
- [`ws_echo.nim`](../examples/ws_echo.nim): the WebSocket handler seam.
- [`ws_queued.nim`](../examples/ws_queued.nim): the outbound queue, a
  background stream and echoed replies on one connection.
- [`bench_raw.nim`](../examples/bench_raw.nim): the production path with the
  access log quieted, for benchmarking.

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

`.passive` procs are sequential code that suspends at I/O. A suspension
point can sit anywhere, a `for` loop included, and a `.passive` proc can
take `var`, `openArray` and `varargs` parameters across one. What such a
parameter cannot do is escape: a call handed to the scheduler with `delay`
or `spawnTask` can outlive the caller's frame, so it must not take one.
The compiler rejects that; pass an owned value (`sink`) instead.

### Socket mode

Connection sockets are `O_NONBLOCK` on every backend: `serve` sets it on each
accepted socket. A blocking socket is not an option on io_uring, where a
write to a peer that has half-closed and does not read is handed to a kernel
worker thread that waits as long as the peer does, one thread per stalled
client.

On a non-blocking socket the ring can complete a write (or read) with
`-EAGAIN`, after the peer's FIN too. `waitWrite` and `waitRead` never return
it: they wait for readiness and retry. On io_uring that poll can wake on the
peer's half-close without readiness; such a wake backs off, doubling from 1 ms
up to 1 s, rather than retrying at once, so a stalled peer costs one write
attempt a second and a peer that resumes reading gets its data within a
second. `writeRetriesTotal` counts the retried writes.

hashi's own direct calls (`readNow`, `writeNow`, `writevNow`, the WebSocket
reader, `hasPendingInput`) use `MSG_DONTWAIT`, so they do not depend on the
socket's mode. On a non-socket fd (a pipe, a PTY master) `readNow`,
`writeNow` and `writevNow` fall back to plain `read`/`write`/`writev`, which
need the fd to be `O_NONBLOCK` itself. A handler that owns its own fds should
make them `O_NONBLOCK` and pass them to `waitRead`/`waitWrite`.

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

**Request targets.** Only origin-form is accepted (`*` and absolute-form
are refused, the latter a deliberate deviation from RFC 9112 §3.2.2), and
the parser rewrites the target to one canonical form before anything sees
it: a single trailing `/` dropped, escaped unreserved bytes decoded, other
escapes uppercased. Empty and dot segments (`//`, `.`, `..`, `%2e`),
malformed escapes, an escaped `/`, `\`, NUL or control byte, a raw `\`,
`#`, space, control or non-ASCII byte in the path, and `#`, space or a
control byte in the query are answered 400 before routing or middleware.
Routing, `path` and checks on `req.target` therefore all see the same
segments. See `canonicalTarget`.

**Request** exposes `path` (percent-decoded), `query`, `queryParams`,
`queryParam`, `header`, `headers`, `hasHeader`, `pathParam`, `body`
(decoded, whether Content-Length or chunked), `remoteAddress` and
`startNanos` (monotonic request start, for latency in after-middleware).

**Middleware.** `addBeforeMiddleware` runs before route matching; returning
`some(resp)` short-circuits, and that response still passes through the
after-chain. The before-chain runs for routes, SSE requests and WebSocket
upgrades on the main listener, not on `addWsListener` listeners.
`addAfterMiddleware` sees every response, including errors, and is the
place for security headers. Middleware must not raise.

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
caps, WebSocket payload and message caps, Nagle, kernel keepalive, the
idle reaper that shuts down an HTTP connection blocked on a read with no
inbound bytes, and the WebSocket keepalive. Writes are never timed by the
application; a stalled peer on the write side is the kernel's job via
`TCP_USER_TIMEOUT` (60 s by default). `serve` exits 1 on a config
`validateServerConfig` rejects, and on a trusted-proxy entry
`trustedProxyFaults` reports.

**Lingering close.** A 413, 431, 426 or 403 (and a before-middleware
claim on a WebSocket upgrade or SSE request, when the client has sent
more than the request) can reach a client that is still sending. Closing
at once with its bytes unread makes the kernel answer with a reset, which
can destroy the response before the client reads it. So once the response
is written the driver shuts down its write side, then reads and discards
until the client closes, sends nothing for `lingerIdleMs` (1 s by
default), or `lingerMs` (5 s) has passed. At most a quarter of the smaller
of `MaxFds` and the soft `RLIMIT_NOFILE` connections linger at once; past
that a rejected connection closes at once. `lingeringNow` and
`lingerClosedTotal` (`hashi/http/connreg`) report them. `lingerMs = 0`
turns it off. A 400 never lingers. The linger narrows the window; no
scheme guarantees a 413 reaches a client that reads only after it has
finished sending an arbitrarily large upload.

**Client IP.** `setTrustedProxies` names the direct peers whose
`X-Real-IP` and `X-Forwarded-For` are honoured. With none configured, the
socket peer is the client. Each entry must be a bare IPv4 or IPv6 literal
(no CIDR, hostname, port, zone id or brackets) that is neither unspecified
(`0.0.0.0`, `::`) nor multicast; `trustedProxyFaults` names any that are
not, and `serve` then exits 1. Addresses are compared and reported in
`parseIpLiteral`'s canonical text (`hashi/net`), the form `peerAddress`
uses: a dotted quad for IPv4 and IPv4-mapped IPv6, compressed lower-case
IPv6 otherwise. From a trusted peer, one `X-Real-IP` line that is an IP
literal is the client; otherwise `X-Forwarded-For` is walked right to left
past trusted hops, and the first other hop is the client if it is an IP
literal. A trusted peer's forwarded headers that name no usable client
leave `remoteAddress` "" (unattributed), never the peer. A trusted proxy
that appends `X-Forwarded-For` without overwriting `X-Real-IP` is logged
as a warning; one that passes both client headers through unchanged
cannot be detected here. See `hashi/http/forwarded`.

## WebSocket

Register a `proc(ws: WsConn) {.passive.}` with `setWsHandler`. After a
successful upgrade the server calls it with a fresh `WsConn`; it owns the
connection until it returns. Loop on `ws.open`, read with `wsRecv`, write
with `wsSend`, and stop on `wmClose`. Ping, pong and the close handshake
are handled inside `wsRecv`. `ws.cookie` and `ws.path` carry the upgrade
request's cookie header and target, since the handler never sees the
`Request`. With no handler registered the server runs an echo loop, which
is what the Autobahn run exercises.

The before-middleware runs on the upgrade request after the origin check
and before the 101: a `some(resp)` is sent through the after-chain as an
ordinary response, the connection closes, and the handler never runs.

`wsPeek` looks at the next complete message without blocking and stashes
it; `wsSkip` discards the stash. `setAllowedOrigins` refuses upgrades from
a browser `Origin` that is neither same-origin nor listed.

**Keepalive.** While a handler is parked in `wsRecv`, the connection pings
a quiet peer after `wsPingIntervalMs` (20 s) and again each interval, and
after `wsIdleTimeoutMs` (60 s) with nothing inbound it sends CLOSE 1001 and
`wsRecv` returns `wmClose`; `wsIdleClosedTotal` counts these. The clock is
inbound-only: any byte from the peer, a PONG included, restarts it, and
nothing the server sends does, since a successful write proves only that
the kernel buffered it. So a server streaming to a peer that never answers
still closes it at the idle timeout. A connection whose handler is not in
`wsRecv` is not pinged, and nor is a peer part-way through sending a frame.
Either knob at 0 turns that half off; the idle timeout must be at least
twice the ping interval. A control frame the reader sends (PONG, PING,
CLOSE) never lands inside a data frame another task is writing: each frame
is written whole under a per-connection guard. The guard is fair to
waiting writers, so a control frame waits its turn behind at most the
frame being written, and once a CLOSE is written no data frame follows
it. A writer stalled on a peer that stops reading is ended by
`TCP_USER_TIMEOUT` (`userTimeoutMs`, 60 s by default). With
`userTimeoutMs` at 0, while the reader's own PING, PONG or CLOSE waits
behind a stalled writer, the reaper backstop is armed for 5 s past the
idle timeout after the last inbound byte, so the peer still cannot pin
the connection. Two tasks sending data still need queued mode,
below. A `WsConn` belongs to its handler: once the handler returns the
driver closes the socket, and nothing may use the `WsConn` after that,
from any task.

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
WebSocket-only listener on the same reactor. Routes, SSE, the main
WebSocket handler and the before-middleware are not reachable there, so a
separate port or interface is its own trust domain, and its handler does
any authentication itself.

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

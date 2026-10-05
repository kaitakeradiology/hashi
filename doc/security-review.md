# Security review & penetration test — 2026-10

Scope: the HTTP/1.1 request path, the WebSocket layer, and the connection
driver. Method: an adversarial read of `src/hashi/`, the unit suite and
fuzzers (`tests/run --fuzz`), and ~40 raw-socket probes against a release
`examples/hello.nim` instance — malformed request lines, smuggling-shaped
headers, canonicalisation edges, cap behaviour, keep-alive/pipelining carry,
WS handshake and frame violations, and load-shaped abuse.

The parser core held. Everything the probes threw at the head parser was
either accepted in canonical form or answered 400/413/431: CL+TE and
duplicate-CL/TE smuggling shapes, non-token field names, LF-only folds,
absolute- and asterisk-form targets, percent-encoding edges (`%2F`, `%00`,
dot segments, double encoding), oversized bodies, unterminated oversized
heads, unmasked WS frames (1002), cross-site `Origin` upgrades (403), and
pipelined carry-over on one connection. One cap gap: `maxRequestHead` was
checked only while a head was incomplete, so a complete head of up to about
4 KiB (one read) past the cap was served. Fixed: a complete head longer than
`maxRequestHead`, through its CRLFCRLF, is now 431 too, WebSocket upgrades
included (`tests/test_inflight.nim`). What did not hold was all resource-shaped, below.

## Findings

### 1. Chunked bodies decoded in O(n²) — fixed

`bodyNow` re-ran `decodeChunked` over the whole accumulated buffer after
every 4 KiB read, re-decoding every earlier chunk on every fill. Measured on
a release build: one 32 MB chunked POST burned **23.5 s of core** (vs 0.25 s
for the same body framed with Content-Length) — ~1.5 s of CPU per MB,
independent of arrival pattern. A few dozen low-and-slow connections saturate
every worker.

Fix: `decodeChunked` now appends to `body` and, when incomplete, reports how
much it consumed; the driver resumes at `start + k` with the same `body`, so
a body arriving in N reads costs one pass. `tests/test_http_body.nim` pins
the contract; `tests/fuzz_chunked.nim` asserts split-and-resume equals one
pass on every round-trip input.

### 2. No aggregate memory bound, and no reaper out of the box — fixed

Every cap was per connection (64 KiB head, 64 MiB body), nothing bounded
connections × bytes, and the defaults shipped `idleTimeoutMs: 0` +
keepalive off — so by default nothing ever reaped an idle or dribbling
connection, and ~1 000 silent sockets (the host's fd limit) held their
buffers indefinitely.

Fix: `defaultServerConfig` now ships the idle reaper on (30 s) and kernel
dead-peer detection on (60 s idle / 10 s interval / 3 probes); the
connection registry counts bytes buffered across all connections and not
yet consumed, and the acceptor refuses new connections at 1 GiB of them
(`maxInflightBytes`) rather than queueing the overflow.

### 3. WebSocket reads were outside the reaper's coverage — fixed

`recvMessage` called `waitRead` bare, so even with `idleTimeoutMs` configured,
upgraded sockets were never armed and a stalled WS peer was kept forever —
the invariant connreg's doc states for "the connection driver" did not hold
for the WS layer.

Fix: WebSocket reads have their own keepalive instead of the HTTP idle
reaper. A parked `wsRecv` pings after `wsPingIntervalMs` (20 s) of inbound
silence and, after `wsIdleTimeoutMs` (60 s), sends CLOSE 1001 and ends the
connection, with a 5 s reap deadline as the backstop for that CLOSE's own
write. Only inbound bytes reset the clock, so a peer that sends nothing cannot
keep a connection open on the strength of the server's writes succeeding. A peer that
stops reading altogether is the kernel's to drop: `TCP_USER_TIMEOUT` is now
on by default (60 s). `tests/test_ws_idle.nim` and
`tests/test_ws_backstop.nim` pin both ends.

### 4. 431/413 rejections can arrive as a reset, not the response — fixed

On any 431 or 413 the driver wrote the status and closed without draining
what the client was still sending. If bytes remain unread in the kernel
receive buffer at `close`, or arrive after it, the kernel answers with RST
and the client may lose the status line. That covers an unterminated head
over `maxRequestHead`, a complete head over it followed by a body or by
pipelined requests, and a Content-Length over `maxBodySize`; the 426 on a
WebSocket-only listener, the cross-site 403 and a middleware claim on an
upgrade or SSE request with bytes behind it are the same shape.

Fix: a lingering close. Once the whole response is written, those
rejections shut down the write side (the client reads the response, then
EOF), then read and discard until the client closes, sends nothing for
`lingerIdleMs` (1 s), or `lingerMs` (5 s) has passed. Never `SO_LINGER`.
Limits: time only, no byte cap; at most a quarter of the smaller of
`MaxFds` and the soft `RLIMIT_NOFILE` connections linger at once, and a
rejection past that closes at once as before; `lingerMs = 0` turns it off;
a 400 and the 503 at accept never linger. A client that reads only after
finishing an arbitrarily large upload can still miss the 413: no scheme
guarantees it. `tests/test_inflight.nim` pins the 413 and 431 against a
client still sending (EOF, not ECONNRESET), the trickling, silent and
flooding clients, and the cap.

### 5. Notes, no action

- `MaxFds` (8192) must stay ≥ `RLIMIT_NOFILE` or connections past it are
  refused at accept; fine on hosts at or below the default limit.
- `parseContentLength` rejects ≥19-digit values as malformed (400) even
  though they also exceed the 64 MiB cap (413 would be apter); harmless.

# Changelog

All notable changes to hashi. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). A release is a git tag `vX.Y.Z`
on this repository; the entry for that version below becomes the release
notes.

## [Unreleased]

### Added

- `listenLoopbackPair` (`hashi/net`): listen on 127.0.0.1 and ::1 on one
  port. ::1 missing (`EADDRNOTAVAIL`, `EAFNOSUPPORT`) leaves 127.0.0.1
  open for the caller to warn; any other ::1 failure closes 127.0.0.1.

### Changed

- **Upgrade note:** an empty bind address now means loopback only, where
  it meant every interface. `serve` and `addWsListener` with `bindAddr`
  `""`, the default, listen on 127.0.0.1 and ::1 (127.0.0.1 alone, with a
  warning, on a host without IPv6 loopback), and `tryListenTcp` with `""`
  binds 127.0.0.1. A server reached from another host stops being
  reachable: callers that passed `""` or nothing for every interface now
  pass `"::"` (dual-stack) or `"0.0.0.0"` (IPv4). `"::"`, `"::0"`,
  `"0.0.0.0"` and other literals are unchanged. `serve` logs every bound
  address, an IPv6 one in brackets (`[::1]:8080`), and names the address
  in a listen failure.
- `examples/ws_echo` takes the bind address as its first argument and
  listens on loopback without one; `ws_echo ::` serves every interface.
- Ported to Nimony's restricted globals (nim-lang/nimony#2609): a routine may
  touch a mutable module-level `var` only through a `.sync` routine. Build
  hashi with a Nimony that has `.sync` and `assumeSync`.
  - Boot-time registrations (routes, middleware, passive handlers, the boot
    task, `addWsListener`, `setWsHandler`, `setSseHandler`, `setServerConfig`,
    `setTrustedProxies`, `setAllowedOrigins`) are sealed when `serve` starts.
    One made afterwards writes `FATAL hashi: boot config changed after
    serve()` to stderr and aborts the process, where it used to race the
    workers. Register before `serve`.
  - `serve`'s `config` default is `serverConfig()`, a copy of what
    `setServerConfig` installed.
  - `initLoop` relies on `initPool` and `initIoRing` being idempotent.

- CI is pinned to Nimony `b3806c1c`, was `564d789e`. The new pin has
  nim-lang/nimony#2609 (restricted globals, which this release needs);
  #2588, which sizes `std/threadpool` from the CPU affinity, so a server
  confined to a CPU subset (a container cpuset) no longer spawns one worker
  per host CPU and stalls; and #2626, which guards the pool's run-queue
  stripes with a blocking lock, so a preempted lock holder no longer stalls
  the other workers' timers (the latency tail under load). Build hashi with
  Nimony `b3806c1c` or later.

### Removed

- Upgrade note: the exported variables `logLevel`, `gServerConfig`,
  `gWsHandler` and `gSseHandler` are gone. Use `setLogLevel(level)` and
  `logEnabled(level)` (`hashi/log`), `serverConfig()` (`hashi/http/config`),
  `wsHandler()` (`hashi/ws/session`) and `sseHandler()` (`hashi/sse/session`).
  `logLevel = error` becomes `setLogLevel(error)`.

## [0.1.6] - 2026-10-06

### Added

- `maxInflightBytes` (`hashi/http/config`) and the byte count it gates on
  (`hashi/http/connreg`): the acceptor refuses new connections at an
  aggregate budget of bytes buffered across all connections; 0 is no
  budget, and a negative value is refused by `validateServerConfig`.
- WebSocket keepalive: a `wsRecv` parked on a quiet peer sends a PING
  every `wsPingIntervalMs` (default 20 s) of inbound silence and, after
  `wsIdleTimeoutMs` (default 60 s), CLOSE 1001 and returns `wmClose`.
  Only inbound bytes reset the clock. `wsIdleClosedTotal`
  (`hashi/http/connreg`) counts these closes. With `userTimeoutMs` at 0, a
  PING, PONG or CLOSE the reader blocks on behind a stalled writer (direct
  mode) is cut off by the reap backstop 5 s past the idle timeout.
- `deadlineOf` (`hashi/http/connreg`): the reap deadline armed for an fd.
- `waitReadableUntil` (`hashi/loop`): wait for an fd to become readable,
  with a deadline.
- `validateServerConfig` (`hashi/http/config`); `serve` logs the reason and
  exits 1 on a config it rejects.
- `lingerMs` (default 5 s, 0 = off) and `lingerIdleMs` (default 1 s)
  (`hashi/http/config`): the lingering close after a rejection.
  `lingeringNow`, `lingerClosedTotal`, `lingerCap` and `setLingerCap`
  (`hashi/http/connreg`) report and bound it; `shutdownWrite`,
  `hasPendingInput` and `openFileLimit` (`hashi/net`).
- `parseIpLiteral` (`hashi/net`): the canonical text of an IPv4 or IPv6
  literal, the form `peerAddress` renders, or "".
- `trustedProxyFaults` (`hashi/http/forwarded`): the `setTrustedProxies`
  entries refused, and why; `serve` logs them and exits 1.
- `forwardedWarning` (`hashi/http/forwarded`): the warning `clientIp` logs
  for a trusted proxy's forwarded headers.

### Changed

- **Upgrade note:** `serve` now REFUSES TO START when a
  `setTrustedProxies` entry is not a bare, unicast, specified IPv4/IPv6
  literal: no CIDR, hostname, port, zone id or brackets, and not
  `0.0.0.0`, `::` or multicast. Such entries previously matched nothing,
  silently. Check deployed `trusted_proxies` values before upgrading. A
  blank entry is dropped, not refused.
- Forwarded client addresses are parsed and canonicalised. Trusted
  proxies, `X-Real-IP` and `X-Forwarded-For` hops are compared as
  addresses, so `::ffff:127.0.0.1` matches `127.0.0.1`. A trusted proxy's
  forwarded headers that name no usable client now give an unattributed
  `remoteAddress` (`""`) instead of the raw string: an `X-Real-IP` and
  right-most untrusted `X-Forwarded-For` hop that are not IP literals, a
  walk that finds only trusted hops, or more than one `X-Real-IP` line with
  no usable `X-Forwarded-For`. The `X-Forwarded-For` walk stops at the
  first hop it cannot use instead of skipping it. Repeated
  `X-Forwarded-For` lines are joined in order; more than one `X-Real-IP`
  line is ignored. `attributedClientIp` takes every `X-Real-IP` line and
  the joined `X-Forwarded-For`.
- `clientIp` logs a warning, at most once a minute per proxy and kind on
  each worker thread, when a trusted proxy appends `X-Forwarded-For`
  without overwriting `X-Real-IP` (`X-Real-IP` equals neither the last
  hop nor the right-most untrusted one), sends more than one `X-Real-IP`,
  or sends one that is not an IP literal. A proxy that passes both client
  headers through unchanged is not detected.

- `decodeChunked` appends to `body` and reports its consumed prefix when
  incomplete; the driver resumes rather than restarts, so a chunked body
  arriving in N reads costs one pass, not N (was O(n²) in body size).
- `defaultServerConfig` ships the idle reaper (30 s) and kernel dead-peer
  detection (60/10/3) on. The reaper's `idleTimeoutMs` covers HTTP reads
  only; WebSocket reads are covered by the keepalive above.
- `userTimeoutMs` (`TCP_USER_TIMEOUT`) defaults to 60 s, was off: a
  connection, HTTP or WebSocket, whose sent data stays unacknowledged or
  whose peer holds a zero window for 60 s is reset by the kernel.
- Each WebSocket frame is written whole under a per-connection guard, fair
  to waiting writers, so the reader's PONG, PING or CLOSE no longer lands
  inside a data frame another task is part-way through writing, nor waits
  indefinitely behind one; once a CLOSE has been written, data frames are
  refused (`wsSend`/`wsWriteAll` return false).
- The `maxInflightBytes` count includes a fragmented WebSocket message while
  it is assembled (`assembledLen`, `hashi/ws/protocol`).

### Fixed

- A large response to a client that half-closed its end (shutdown of its
  write side) was cut short on io_uring: the ring completed the write with
  `-EAGAIN` on the `O_NONBLOCK` socket, which was taken for a vanished peer,
  so a 32 MiB body arrived as 3 to 8 MB followed by a clean EOF. `waitWrite`
  and `waitRead` now wait for readiness and retry on `EAGAIN`, backing off
  (1 ms doubling to 1 s) when the poll wakes on the half-close without
  readiness, so a stalled peer costs one attempt a second. `readNow`,
  `writeNow` and `writevNow` are non-blocking per call (`MSG_DONTWAIT`)
  instead of per socket.
- `maxRequestHead` limits the request line and header section exactly: a
  complete one longer than the limit, through the blank line that ends it,
  is answered 431. Only an incomplete header section was checked before,
  so one up to about 4 KiB over the limit was served, WebSocket upgrades
  included. `validateServerConfig` refuses a limit of 0 or less.
- Responses the server sends just before closing the connection (400, 403,
  413, 426, 431, and a middleware claim on a WebSocket upgrade or SSE
  request) carry `Connection: close` (RFC 9112 §9.6).
- A 413, 431, 426 or 403, or a middleware claim on an upgrade or SSE
  request with bytes behind it, sent to a client still sending, could be
  lost to a reset: the driver closed with the client's bytes unread. It now
  half-closes and drains for up to `lingerMs` first.

### Security

- Adversarial review and penetration pass; see `doc/security-review.md`.

## [0.1.5] - 2026-10-01

### Added

- `readNow`, `writevNow` and `yieldTask` (`hashi/loop`): a direct read of
  what has arrived, a direct gather write, and a yield to the pool's other
  tasks.
- `HeadBuf` and `serializeHead` (`hashi/http/request`): a response head
  written into fixed storage; `sendsBody`; `clear` for a reused `Request`.
- `route` (`hashi/http/router`): `dispatchFull` on a request the caller owns.

### Changed

- A connection reads what has already arrived before waiting on the ring,
  and its head, body and response steps finish without suspending when the
  bytes are at hand; each such request then yields once so a busy
  connection cannot hold its worker.
- Each response is written from a per-connection head buffer and its body
  in one `writev`; the router matches in place and attaches path params to
  the request rather than copying it; header fields are parsed into the
  request's own storage.
- Release builds (`-d:release`, `-d:danger`; not Windows) use link-time
  optimisation.
- On 4 CPUs, plaintext keep-alive throughput is about 27% higher than 0.1.4
  and median latency about a quarter lower; p99 is lower at 64 connections
  and somewhat higher at 512.
- CI runs the fuzzers, and on GitHub the Autobahn suite.

## [0.1.4] - 2026-10-01

### Added

- `workTurn` (`hashi/loop`): one worker's turn on the calling thread, pool
  tasks and then the thread's own lane.
- `writeNow` (`hashi/loop`): a direct non-blocking write of what the kernel
  takes without waiting.
- `findCrlf` and `findCrlfCrlf` (`hashi/buffer`), `eqIgnoreCase`
  (`hashi/http/request`), `isTrustedProxy` (`hashi/http/forwarded`).

### Changed

- `runLoop` takes worker turns, so the thread that runs the server works
  alongside the pool instead of leaving a CPU idle.
- `writeAll` writes what the socket buffer takes at once and waits on the
  ring only for the rest.
- The request path does less per request: line ends are found with
  `memchr`, the `Date` line is formatted once a second per thread, the
  response is built in one presized string, a direct peer's client address
  is settled once per connection, and field names are compared with a
  length check first. On 4 CPUs, plaintext keep-alive throughput is 20–38%
  higher than 0.1.3, with p99 latency the same or lower.

## [0.1.3] - 2026-09-29

### Fixed

- `spawnTask` returns once the task is queued. On Nimony at and after
  nim-lang/nimony#2569, where a regular proc's call of a `.passive` proc
  runs it to completion, it waited for the task to finish, so the accept
  loop served one keep-alive connection at a time (about 96k req/s against
  570k). CI is pinned to `564d789e`.

## [0.1.2] - 2026-09-19

### Fixed

- A response after which the server will close the connection (the request
  said `Connection: close`, or was HTTP/1.0) now carries `Connection: close`
  (RFC 9112 §9.6), so clients stop sending another request into a socket
  about to close.
- The listen backlog is 4096 (was 128): under a thousand connections opening
  and closing per request, the short queue dropped SYNs and the p99 latency
  was the client's retransmit timer.

## [0.1.1] - 2026-09-18

### Fixed

- Builds on Nimony at and after nim-lang/nimony#2539, where a proc type is
  not-nil by default: the optional handlers (error, not-found, WebSocket,
  SSE, boot task) are declared `nil`-able and presence is a nil check. CI
  is pinned to `927296de`.

### Changed

- `doc/benchmarks.md` is rewritten around one measured session and adds
  cps-http as a third server; the README table follows it.

### Removed

- `Router.hasErrorHandler` and `Router.hasNotFound`; test `errorHandler`
  and `notFound` against `nil` instead.

## [0.1.0] - 2026-09-17

First release: an HTTP/1.1 and WebSocket server for Nimony, the Nim 3
compiler, with no dependencies beyond the Nimony standard library.

### Added

- HTTP/1.1 (RFC 9112): Content-Length and chunked bodies, keep-alive and
  pipelining, request-smuggling checks, size limits, an idle reaper, TCP
  keepalive.
- A router with `:param` captures, `*` and `**` wildcards, 405 versus 404,
  a not-found fallback, before and after middleware, and per-request
  error handling on Nimony's `ErrorCode` model.
- WebSocket (RFC 6455): fragmentation, UTF-8 and close-code validation,
  an origin allowlist, a sequential `.passive` handler API, an optional
  lane-prioritised outbound queue for connections written by several
  tasks, and secondary WebSocket-only listeners.
- Server-Sent Events, `multipart/form-data`, trusted-proxy client IP
  attribution, and a status-aware access log.
- Conformance: the Autobahn WebSocket suite passes with no failures; a
  raw-socket WebSocket harness and seven parser fuzzers gate CI.

[Unreleased]: https://github.com/kaitakeradiology/hashi/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/kaitakeradiology/hashi/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/kaitakeradiology/hashi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/kaitakeradiology/hashi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/kaitakeradiology/hashi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kaitakeradiology/hashi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kaitakeradiology/hashi/releases/tag/v0.1.0

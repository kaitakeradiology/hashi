# Changelog

All notable changes to hashi. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). A release is a git tag `vX.Y.Z`
on this repository; the entry for that version below becomes the release
notes.

## [Unreleased]

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

[Unreleased]: https://github.com/kaitakeradiology/hashi/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/kaitakeradiology/hashi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/kaitakeradiology/hashi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/kaitakeradiology/hashi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kaitakeradiology/hashi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kaitakeradiology/hashi/releases/tag/v0.1.0

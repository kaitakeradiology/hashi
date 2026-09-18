# Changelog

All notable changes to hashi. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). A release is a git tag `vX.Y.Z`
on this repository; the entry for that version below becomes the release
notes.

## [Unreleased]

### Fixed

- A response after which the server will close the connection (the request
  said `Connection: close`, or was HTTP/1.0) now carries `Connection: close`
  (RFC 9112 §9.6), so clients stop sending another request into a socket
  about to close.
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

[Unreleased]: https://github.com/kaitakeradiology/hashi/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/kaitakeradiology/hashi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kaitakeradiology/hashi/releases/tag/v0.1.0

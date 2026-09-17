<p align="center">
  <a href="https://kaitakeradiology.co.nz"><picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/assets/krs-lockup-dark.svg">
    <img src="doc/assets/krs-lockup-light.svg" width="360" alt="Kaitake Radiology Systems">
  </picture></a>
</p>

# Hashi (橋, bridge)

An HTTP/1.1 and WebSocket server for [Nimony](https://github.com/nim-lang/nimony),
the Nim 3 compiler. Handlers are `.passive` procs: sequential code that
suspends at I/O points and resumes on `std/ioring`'s worker pool. No event
loop of its own, no thread per connection, no dependencies beyond the
Nimony standard library.

```nim
import hashi

proc home(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "Hello, hashi\n")

get("/", home)
serve(8080'u16)
```

A WebSocket handler is a `.passive` proc that owns the connection:

```nim
import hashi

proc onWs(ws: WsConn) {.passive.} =
  while ws.open:
    let m = wsRecv(ws)
    if m.kind == wmClose: ws.open = false
    elif not wsSend(ws, m.data, m.kind == wmBinary): ws.open = false

setWsHandler(onWs)
serve(8080'u16)
```

## What it does

- HTTP/1.1 (RFC 9112): Content-Length and chunked bodies, keep-alive and
  pipelining, request-smuggling checks, size limits, an idle reaper, TCP
  keepalive.
- Routing with `:param` captures, `*` and `**` wildcards, 405 versus 404,
  a not-found fallback, before and after middleware, and per-request error
  handling on Nimony's `ErrorCode` model.
- WebSocket (RFC 6455): fragmentation, UTF-8 and close-code validation, an
  origin allowlist, an optional lane-prioritised outbound queue for
  connections written by several tasks, secondary WebSocket-only listeners.
- Server-Sent Events, `multipart/form-data`, trusted-proxy client IP
  attribution, a status-aware access log.

Handlers run concurrently on worker threads: state local to a handler is
safe, state shared between handlers needs a lock.

## Status

v0.1.0. HTTP/1.1 and WebSocket over TCP are complete. HTTP/3, QUIC and
WebTransport over HTTP/3 are next, via ngtcp2 and nghttp3; HTTP/2 is
skipped by design.

The Autobahn WebSocket suite passes with no failures; the HTTP/1.1 parser
is fuzzed and differentially tested. Results: [`doc/conformance.md`](doc/conformance.md).

## Performance

`wrk -t10`, 10 s per run, loopback, release builds, 16-core Linux box.
[Mummy](https://github.com/guzba/mummy), a Nim 2 server using worker threads, and
[cps-http](https://github.com/gabearro/cps-http), a Nim 2 server using continuations
from a macro on its own runtime, measured in the same session for scale.
Method and full results: [`doc/benchmarks.md`](doc/benchmarks.md).

| Workload | hashi | cps-http | Mummy |
|---|---|---|---|
| Raw, 100 connections | 276,000 req/s, 0.49 ms | 95,600 req/s, 1.28 ms | 91,800 req/s, 1.09 ms |
| Raw, 1000 connections | 267,000 req/s, 2.55 ms | 78,100 req/s, 13.7 ms | 75,600 req/s, 24.4 ms |
| 10 ms of work per request, 1000 connections | 95,100 req/s, 10.2 ms | 71,400 req/s, 14.0 ms | 9,700 req/s, 97.7 ms |

## Building

Nimony is the only requirement. Clone and bootstrap it as a sibling
checkout, or set `NIMONY=` to the compiler binary, then:

```bash
tests/run                                  # unit tests
tests/run --fuzz                           # unit tests + fuzzers
../nimony/bin/nimony c -r examples/hello.nim
```

The from-scratch sequence, and a sandboxed proof of it, are in
[`doc/building.md`](doc/building.md).

**Platforms.** Linux is the only tested platform, over epoll or io_uring. The I/O
layer is `std/ioring`, which also has kqueue, WSAPoll and IOCP backends,
and Nimony's Windows target needs no C runtime, so macOS, the BSDs and
Windows are potentials. The only Linux-specific code is the
socket FFI in `src/hashi/net.nim`.

## Documentation

- [API reference](https://kaitakeradiology.github.io/hashi/), generated from
  the source on every push; `doc/gen` builds the same pages into `htmldocs/`
  with `nimony doc`.
- [`doc/api.md`](doc/api.md): how the pieces fit together.
- [`examples/`](examples/): routing, configured limits, WebSocket echo, the
  outbound queue.
- [`doc/error-handling.md`](doc/error-handling.md): what a handler can
  raise and what the server catches.
- [`doc/upstream.md`](doc/upstream.md): Nimony issues found on the way,
  each worked around in the tree.

## License

MIT, © 2026 Kaitake Radiology Systems Limited — see [`LICENSE`](LICENSE).

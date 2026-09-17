# AGENTS.md

Guidance for coding agents and new contributors working in this repository.

## What this is

Hashi is an HTTP/1.1 and WebSocket server for Nimony (the Nim 3 era
compiler), with HTTP/3, QUIC and WebTransport planned. Handlers are
`.passive` procs resumed on `std/ioring`'s worker pool. See `README.md`
for the overview and `doc/api.md` for how the modules fit together.

## Build and test

```bash
tests/run                    # unit tests: compiles and runs each tests/test_*.nim
tests/run --fuzz             # plus the parser fuzzers, tests/fuzz_*.nim
tests/run test_router        # one test by name
../nimony/bin/nimony c -r examples/hello.nim
doc/gen                      # API reference into htmldocs/
```

The compiler is resolved as `$NIMONY`, else `../nimony/bin/nimony`, else
`nimony` on `PATH`. `doc/building.md` has the from-scratch toolchain and
setup. Hashi has no dependencies beyond the Nimony standard library;
`nimony.paths` puts `src` on the module search path.

## Layout

- `src/hashi/http/`: server driver, request parser and response
  serialiser, router, URI helpers, multipart, config, connection registry,
  access log.
- `src/hashi/ws/`: frame codec, protocol state machine, handshake, the
  session handle and passive I/O ops, the outbound queue.
- `src/hashi/sse/`: Server-Sent Events.
- `src/hashi/loop.nim`: the loop lifecycle and the passive fd operations
  (`waitAccept`/`waitRead`/`waitWrite`/`writeAll`). `src/hashi/net.nim`:
  listen-socket setup, the peer address, per-connection socket options, and
  the socket FFI `std/posix` lacks. `src/hashi/buffer.nim`: bulk byte
  operations on a string buffer.
- `src/hashi.nim`: the umbrella (`import hashi` re-exports the application
  API) and the root module for `doc/gen`.
- `tests/`: the unit tests and fuzzers `tests/run` drives; `tests/conformance/`:
  the Autobahn runner and the raw-socket WebSocket conformance script.
- `examples/`, `bench/`.
- `.github/workflows/test.yml`: CI, with the pinned Nimony commit;
  `tests/clean_build`: the same job in a local sandbox (see `doc/building.md`).

## How to work here

- **The test suite is the spec.** This is a standards-conformance project.
  Write or extend the test first, confirm it fails, implement, confirm it
  passes. Conformance suites and fuzzers are gating, not advisory.
- **Small, focused changes.** One concern per commit. Build and run the
  suite before declaring anything done; report test output faithfully.
- **Pause before committing.** Show the diff and the test result and let
  the maintainer confirm.
- **Read the source before importing.** Check what a module actually
  exports; do not assume Nim 2 stdlib shapes exist in Nimony.
- **Comments document the API.** Module and exported-symbol docs are `##`
  comments stating the contract. Do not narrate history, removed code or
  compiler workarounds in comments; a live invariant gets one or two
  sentences.

## Nimony constraints

- A `for` loop cannot contain a suspension point. Use `while`.
- A `.passive` proc cannot take `var`, `openArray` or `varargs` params.
- Defects (bounds, overflow, nil dereference) are not catchable and abort
  the process. Transport code that parses attacker-controlled bytes must be
  fuzzed, and must never index without a check.
- `std/ioring`'s worker pool is the scheduler. Handlers run concurrently on
  worker threads; shared state needs a lock.
- Errors are the `ErrorCode` model, not exceptions. See
  `doc/error-handling.md`.

## Standards

| Standard | Status | Test suite |
|---|---|---|
| HTTP/1.1 (RFC 9112) | done | fuzzers |
| WebSocket (RFC 6455) | done | Autobahn |
| HTTP/3 (RFC 9114) | planned | h3spec |
| QUIC (RFC 9000) | planned | quic-interop-runner |
| WebTransport over HTTP/3 | planned | web-platform-tests |

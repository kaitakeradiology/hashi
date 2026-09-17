# Conformance + fuzzing

## WebSocket: Autobahn (RFC 6455)

The official suite, `tests/conformance/autobahn/` (setup in its README), against `examples/ws_echo`. Result on 16 Sep 2026, at
the CI-pinned Nimony:

| Outcome | Cases | Sections |
|---|---|---|
| Pass | 294 | 1–5, 6 (UTF-8), 7 (close), 9 (limits/performance), 10 |
| Non-strict | 4 | 6.4.1–6.4.4 |
| Informational | 3 | 7.13 (reserved close codes) |
| Unimplemented | 216 | 12, 13 (permessage-deflate) |
| Fail | 0 | |

The four non-strict cases send a text message in fragments where a later
fragment makes the UTF-8 invalid. hashi closes with 1007 once the message is
complete rather than at the first invalid frame; the RFC permits either, and
Autobahn marks the late close non-strict. Sections 12 and 13 exercise the
compression extension, which hashi does not negotiate, so the suite skips
them.

# HTTP/1.1 conformance + fuzzing

The in-process fuzzers, run by CI:

1. **In-process fuzzers** — `tests/fuzz_*.nim`, run by `tests/run --fuzz`.
   Each drives a seeded `std/random` generator (the seed is in the file's
   header, so a failure reproduces) through thousands of random, shaped and
   well-formed inputs, checking invariants on the first two kinds (no crash,
   consumed bytes in range, results within the configured caps) and an
   exact round-trip on the third. The generators are shared in
   `tests/fuzzkit.nim`.

   | Fuzzer | Target |
   |---|---|
   | `fuzz_request` | `parseRequestHead`: random bytes, then well-formed heads parsed back exactly |
   | `fuzz_chunked` | `decodeChunked`: random bytes, then chunk-encoded bodies decoded back exactly |
   | `fuzz_ws_frame` | `parseFrame` and `handleFrame`: random bytes, masked frames unmasked back exactly, the state machine and UTF-8 check on arbitrary input |
   | `fuzz_uri` | the `Request` accessors over `std/uri`, an `encodeQuery` round-trip, the origin check, and the upgrade detection under random damage |
   | `fuzz_router` | `matchRoute` on random patterns and targets, targets derived from a pattern matching it with the right captures |
   | `fuzz_multipart` | `parseMultipartForm` on random bodies, then generated forms with CRLFs and decoy boundaries in the data parsed back exactly |
   | `fuzz_buffer` | `hashi/buffer` against a plain-string model across the string's inline and heap tiers |

## Findings (Jun 2026)

The differential harness found two real hashi conformance gaps, both fixed
(TDD: `tests/test_http_request.nim`):

- **Field-names weren't validated as tokens.** hashi accepted `<: x` etc.;
  RFC 9110 §5.6.2 requires field-name = `1*tchar`. Fixed: `parseField` now
  rejects any non-`tchar` byte in the name (subsuming the earlier
  whitespace-before-colon smuggling check). (Mummy is *lenient* here — it
  accepts non-token field-names; hashi is now the stricter/conformant one.)
- **Method wasn't validated as a token.** hashi accepted `GE\T`, `GE;T`;
  RFC 9112 §3.1 requires method = token. Fixed: `isToken(meth)` in
  `parseRequestHead`.

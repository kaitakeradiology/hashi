# Error handling

How hashi handles errors, what it can and can't catch, and why **fuzzing is
load-bearing** here. Grounded in Nimony's error model.

## The model: `ErrorCode`, not exceptions

Nimony has no Nim-style exceptions. Errors are a standardized **`ErrorCode`
enum** (`Failure`, `NameNotFound`, `BadOperation`, `TimeoutError`, …). A proc
that may fail is `{.raises.}` and does `raise NameNotFound`; callers catch with
`try: … except ErrorCode as e:`.

hashi's `Handler` is `proc(req): Response {.nimcall, raises.}`. A handler (or any
library it calls — Nimony's I/O/DB layers report failures as `ErrorCode`s) may
`raise`. `dispatch` catches it:

```nim
try:
  result = handler(rq)
except ErrorCode as e:
  result = if hasErrorHandler: errorHandler(rq, e)
           else: newResponse(errorCodeToHttp(e))
```

`errorCodeToHttp` maps the code to an HTTP status (mirrors the errorcodes package's
`errorCodeToHttp`): `NameNotFound`→404, `BadOperation`→400, `PermissionDenied`→403,
`ContentTooLong`→413, `TimeoutError`→408, `UnimplementedOperation`→501, …,
everything else→500. Apps can override with `setErrorHandler(proc(req, err))` for
custom status/body/logging.

So a handler deep in helper code can `raise NameNotFound` and the client gets a
clean 404 — the connection and server stay up.

## What is and isn't caught

| Class | Example | Caught? |
|---|---|---|
| Malformed/malicious **input** | bad framing, oversize body, smuggling | ✅ guarded at the transport (400/413/431), never reaches a handler |
| **Expected** errors (`raise ErrorCode`) | not-found, validation, I/O, timeout | ✅ caught by `dispatch` → mapped status |
| Programming **bugs** (Defects) | index OOB, overflow, nil deref, failed `{.requires.}` | ❌ **fatal `quit 1`** — uncatchable, aborts the process |

The third row is a hard Nimony property: contract/bounds/overflow violations
lower to `raiseAssert`/`quit 1`. There is **no** `--panics:off`-style mode to make
them catchable (`--boundchecks:off` only *removes* the check → UB, which is
worse). This is the same robustness class as a Nim server built with
`--panics:on`. A handler *bug* therefore aborts the process — and since the
reactor is one process with a shared worker pool, that takes the server down.

## Consequences

1. **hashi's own transport code must be defect-free.** It's defensively written
   (bounds-checked parsing, size caps, smuggling guards) so untrusted *input*
   can't trip a Defect. This is the part we control and must keep airtight.
2. **App-handler bugs need process supervision.** Run under systemd / a
   supervisor with auto-restart; a buggy handler that indexes out of bounds will
   abort, and fast restart is the recovery. (Same as `--panics:on` Nim.)
3. **Fuzzing is the safety net, not a nicety.** Because input-triggered Defects
   in transport code are unrecoverable, the parser/framing/WS layers must be
   fuzzed hard to find them *before* deploy. `tests/fuzz_request.nim` exists;
   the WS frame/UTF-8/close paths and the chunked decoder want the same. This is
   elevated from backlog to a standing priority.

## API summary

- `Handler = proc(req: Request): Response {.nimcall, raises.}` — may `raise` an `ErrorCode`.
- `raise NameNotFound` (etc.) in a handler → mapped to an HTTP status by `dispatch`.
- `errorCodeToHttp(e: ErrorCode): int` — the mapping (override per-request via an error handler).
- `setErrorHandler(proc(req, err): Response)` — custom error response (process-global, or per-`Router`).
- Defects are **not** catchable — see the table above.

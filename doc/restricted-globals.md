# Restricted globals: what 0.1.7 changes for your code

hashi 0.1.7 builds under Nimony's restricted globals
([nim-lang/nimony#2609](https://github.com/nim-lang/nimony/pull/2609)). The rule
applies to every module the compiler sees, so an application on hashi has to
follow it too. This page covers what hashi changed and how to port your own
globals. You need Nimony `b3806c1c` or later.

## The rule

A routine may touch a mutable module-level `var` in only two ways:

- by passing it to a `var` or `ptr` parameter of a `.sync` routine, such as
  an atomic operation or `acquire`/`release` on a lock;
- inside `{.cast(assumeSync).}:`, which tells the compiler the access is
  synchronised some other way.

Anything else is a compile error:

```
Error: unsynchronized access to global variable 'gCache'; pass it to a `.sync`
routine or use `{.cast(assumeSync).}`
```

`let`, `const` and `{.threadvar.}` globals are not affected. Handlers run
concurrently on `std/ioring`'s worker threads, so the rule catches real races:
a global the compiler rejects is one that workers could touch at the same time.

## What hashi changed

**Removed variables.** Use the accessor instead:

| 0.1.6 | 0.1.7 |
|---|---|
| `logLevel = warn` | `setLogLevel(warn)` |
| reading `logLevel` | `logEnabled(level)` |
| `gServerConfig` | `serverConfig()`, a copy |
| `gWsHandler` | `wsHandler()` |
| `gSseHandler` | `sseHandler()` |

`setLogLevel` and `setLogCallback` are safe from any thread, at any time.

**Registration is sealed when `serve` starts.** These calls belong before
`serve`:

- routes and middleware;
- passive handlers and the boot task;
- `addWsListener`, `setWsHandler` and `setSseHandler`;
- `setServerConfig`, `setTrustedProxies` and `setAllowedOrigins`.

One made after `serve` has started writes
`FATAL hashi: boot config changed after serve()` to stderr and aborts the
process. In 0.1.6 it raced the workers silently. If a handler or a background
task registers a route late, move the registration into startup.

**`serve`'s config default** is `serverConfig()`, a copy of whatever
`setServerConfig` installed.

## Porting your own globals

Decide what each global is, then pick the matching tool.

| The global is... | Use |
|---|---|
| set during startup, read-only afterwards | a `Frozen[T]` from `hashi/bootcfg` |
| a counter or a flag written at runtime | `std/atomics` |
| a container or object written at runtime | a `Lock`, with `{.cast(assumeSync).}` inside it |
| per-thread scratch state | `{.threadvar.}` |
| test-only state on one thread | `{.feature: "assumeSync".}` for that test module |

**Startup configuration: `Frozen[T]`.** `serve` seals these along with its own
configuration, so a late write aborts instead of racing.

```nim
import hashi/bootcfg

var gUpstream: Frozen[string]          # never touched directly

proc configure*(url: string) =
  publish(gUpstream, url)              # before serve; aborts after

proc upstream*(): string =
  snapshot(gUpstream)                  # any thread: a copy
```

- `view` returns a pointer to the value in place. It is for hot paths that
  read a large value without copying it. Never write through it.
- `edit` returns a pointer for in-place building during startup. Call it
  only on the thread that later calls `serve`.
- Values are never freed, so a re-publish during startup leaks the old one.
  That is fine for configuration and wrong for anything that changes at
  runtime.
- The module needs `--mm:atomicArc`, the default.

**Counters and flags: atomics.**

```nim
import std/atomics

var gRequests: int   # only through atomic ops

proc countRequest*() =
  discard atomicFetchAdd(gRequests, 1, moRelaxed)

proc requests*(): int =
  atomicLoad(gRequests, moRelaxed)
```

**Shared containers: a lock, and a cast that says which lock.** `acquire` and
`release` are `.sync`, so the lock itself needs no cast. The data it guards
does, and the comment on the cast names the lock:

```nim
import std/locks

var gLock: Lock
var gSessions: Table[string, Session]   # only under gLock

initLock(gLock)

proc remember*(id: string; s: Session) =
  acquire(gLock)
  {.cast(assumeSync).}:   # gSessions: under gLock
    gSessions[id] = s
  release(gLock)
```

- Keep the cast as narrow as the lock. A cast outside a lock is a promise
  the compiler cannot check, so write down why it holds.
- Do not hold a lock across a suspension point in a `.passive` proc. While
  the task is suspended, every other task that wants the lock blocks its
  worker thread. Copy what you need under the lock, release it, then
  suspend.
- Prefer returning a copy from inside the lock to handing out a reference
  into the guarded data.

**Avoid whole-module opt-outs in application code.** `{.feature: "assumeSync".}`
turns the check off for a module and trusts its globals everywhere. Use it
only in a test that never shares state with a worker thread, and say so in a
comment.

## Checklist

1. Build with Nimony `b3806c1c` or later and hashi 0.1.7.
2. Replace the removed hashi variables using the table above.
3. Move every registration ahead of `serve`.
4. For each compiler error, classify the global and use the matching tool.
   Each `{.cast(assumeSync).}` gets a comment saying why it is safe.
5. Run your tests on both `std/ioring` backends: the default, and
   `-d:nimIoringNoUring` for epoll.

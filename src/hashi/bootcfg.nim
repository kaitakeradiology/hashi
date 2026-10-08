## Boot-time configuration: registered before `serve`, read from any thread
## afterwards.
##
## Nimony allows a mutable module-level `var` to be touched only through a
## `.sync` routine. A `Frozen[T]` is a module-level `var` that is reached only
## through the routines below; `serve` calls `sealBootConfig` before it starts
## accepting, and every `publish` or `edit` after that writes
## `FATAL hashi: boot config changed after serve()` to fd 2 and aborts, so a
## late registration fails loudly instead of racing the workers.
##
## A stored value is never freed. That is what makes the raw `ptr T` from
## `view` safe to hold, and why a request path reads a `Router` or a handler
## table without copying it. `snapshot` copies, which is sound because the
## reference counts are atomic (hence the `gcAtomicArc` guard).
##
## `T` must be valid all-zero: an unset slot reads as `default(T)` and `edit`
## and `view` install a zeroed block. A `T` whose default is not all-zero
## (`ServerConfig`, `LogLevel`) is published once from a module-level statement.

import std/atomics
when defined(posix):
  from std/posix/posix import write
elif not (defined(wasm32) and defined(standalone)):
  import std/syncio

when not defined(gcAtomicArc):
  {.error: "hashi/bootcfg needs --mm:atomicArc (the default): snapshot copies a shared value".}

type
  Frozen*[T] = object
    ## One boot-time value. Declare it as a module-level `var`.
    p: int   # address of a `ptr T` from alloc0, never freed; 0 = unset

var gSealed: bool   # only through atomicLoad/atomicStore, in .sync procs

proc cAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}

proc die(msg: string) {.noreturn.} =
  when defined(posix):
    var m: seq[byte] = @[]
    for c in msg: m.add byte(c)
    m.add byte('\n')
    discard write(cint(2), addr m[0], m.len)
  elif not (defined(wasm32) and defined(standalone)):
    write(stderr, msg & "\n")
  cAbort()

proc sealBootConfig*() {.sync.} =
  ## End of boot: every later `publish` or `edit` aborts. `serve` calls this.
  atomicStore(gSealed, true, moRelease)

proc bootConfigSealed*(): bool {.sync.} =
  atomicLoad(gSealed, moAcquire)

proc refuseIfSealed() {.sync.} =
  if bootConfigSealed():
    die("FATAL hashi: boot config changed after serve()")

proc slot[T](f: var Frozen[T]): int {.sync.} =
  ## The address of `f`'s block, installing a zeroed one if nothing is there.
  result = atomicLoad(f.p, moAcquire)
  if result == 0:
    let fresh = cast[int](alloc0(sizeof(T)))
    var expected = 0
    if atomicCompareExchange(f.p, expected, fresh):
      result = fresh
    else:
      dealloc(cast[pointer](fresh))   # lost the race; nothing else saw this block
      result = expected

proc publish*[T](f: var Frozen[T]; v: sink T) {.sync.} =
  ## Install `v` as the value. Aborts once sealed. Replacing a value leaks the
  ## old one, which a reader may still hold.
  refuseIfSealed()
  let q = cast[ptr T](alloc0(sizeof(T)))
  q[] = v
  atomicStore(f.p, cast[int](q), moRelease)

proc edit*[T](f: var Frozen[T]): ptr T {.sync.} =
  ## The value in place, for a registration to append to. Aborts once sealed.
  refuseIfSealed()
  result = cast[ptr T](slot(f))

proc view*[T](f: var Frozen[T]): ptr T {.sync.} =
  ## The value in place, for reading only: never write through it.
  result = cast[ptr T](slot(f))

proc snapshot*[T: HasDefault](f: var Frozen[T]): T {.sync.} =
  ## A copy of the value, or `default(T)` if none was set.
  let q = atomicLoad(f.p, moAcquire)
  if q == 0:
    result = default(T)
  else:
    result = cast[ptr T](q)[]

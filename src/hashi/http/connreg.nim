## Per-fd deadline registry for the idle-connection reaper.
##
## The connection driver arms a deadline on an fd immediately before it blocks
## on a read and disarms it the instant the read returns, so a connection is
## watched only while blocked with no inbound bytes — never while a handler
## runs, and any inbound byte resets it. A recurring reaper sweep calls
## `reapExpired`, which `shutdown()`s any fd still armed past its deadline;
## that routes through the normal completion path, so the parked read returns
## <=0 and the driver's existing unwind closes the fd.
##
## Writes are intentionally not timed. A write blocks under TCP flow control
## until the peer's window reopens, which for a slow-but-alive reader can be
## much slower than its read cadence, so an app-layer write deadline cannot
## tell "slow but alive" from "stalled". Write-stall / dead-peer detection is
## the kernel's job (`TCP_USER_TIMEOUT`); see `hashi/http/server`.
##
## Lock-free: the connection worker writes its slot's deadline and the reaper
## reads it, both via aligned 64-bit atomics. fd reuse needs no generation
## counter because deadlines are monotonic-nanosecond values (effectively
## unique): the reaper commits a reap with a compare-and-swap of the exact
## deadline it saw, which fails if teardown cleared the slot or a new
## connection re-armed it with a different value.

import std/atomics

const MaxFds* = 8192
  ## Bound on the fd numbers this registry can track: `gDeadline` below is a
  ## flat fd-indexed array, so an fd at or past this cannot be armed and the
  ## acceptor refuses it (see `hashi/http/server`). Raising it costs 8 bytes
  ## of BSS per fd; it should stay at or above the process's `RLIMIT_NOFILE`,
  ## since that is what actually bounds the fds this registry can be handed.

proc shutdownRaw(fd: cint; how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
const SHUT_RDWR = 2.cint

var gDeadline: array[MaxFds, int64]   ## 0 = not watched; else the deadline in monotonic ticks.
var gReapCount: int64                 ## Total connections reaped, for `reapedTotal`.

proc setDeadline*(fd: cint; deadlineNanos: int64) =
  ## Arm (deadlineNanos > 0) or disarm (0) the reap deadline for `fd`.
  if fd >= 0.cint and fd.int < MaxFds:
    atomicStore(gDeadline[fd.int], deadlineNanos)

proc clearConn*(fd: cint) =
  ## Disarm on connection teardown (belt-and-suspenders; the driver also disarms
  ## after each wait returns).
  if fd >= 0.cint and fd.int < MaxFds:
    atomicStore(gDeadline[fd.int], 0'i64)

proc reapExpired*(nowNanos: int64): int =
  ## Sweep the table; `shutdown()` every fd armed past `nowNanos`. Returns the
  ## number reaped this pass. Called on the reactor from the reaper loop.
  result = 0
  var fd = 0
  while fd < MaxFds:
    let dl = atomicLoad(gDeadline[fd])
    if dl != 0'i64 and nowNanos > dl:
      var expected = dl
      # Claim the reap atomically: only shutdown if the slot still holds the
      # exact expired deadline we saw (guards teardown / fd reuse).
      if atomicCompareExchange(gDeadline[fd], expected, 0'i64):
        discard shutdownRaw(fd.cint, SHUT_RDWR)
        discard atomicFetchAdd(gReapCount, 1'i64)
        result = result + 1
    fd = fd + 1

proc reapedTotal*(): int64 =
  ## Cumulative connections reaped since boot (for app /metrics).
  atomicLoad(gReapCount)

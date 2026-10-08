## INTERNAL: test hook for `hashi/bootcfg`, not part of hashi's API.
##
## A late `publish` or `edit` aborts the process, which a race test cannot
## survive. Once `countLateRefusals` is called, `bootcfg` instead counts the
## refusal and returns without storing. Nothing in `src` calls it.

import std/atomics

var gCounting: bool   # only through atomicLoad/atomicStore, in .sync procs
var gRefused: int

proc countLateRefusals*() {.sync.} =
  atomicStore(gCounting, true, moRelease)

proc lateRefusals*(): int {.sync.} =
  atomicLoad(gRefused, moAcquire)

proc probeLate*(): bool {.sync.} =
  ## True, after recording the refusal, when the hook is on.
  result = atomicLoad(gCounting, moAcquire)
  if result:
    discard atomicFetchAdd(gRefused, 1, moAcquireRelease)

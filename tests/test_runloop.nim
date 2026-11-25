## `runLoop` on the thread that calls it.
##
## `runLoop` only waits: no task runs on its thread. A thread outside the
## pool that ran tasks would hand each I/O completion it took to another
## worker's queue, moving the connection between threads on every request.
## `runLoop` returns soon after `stopLoop`, which a pool worker calls here.
##
## A few thousand tasks that each yield several times pass through every
## queue, so a `runLoop` that took turns would run some of them.
import std/[syncio, monotimes, atomics]
import hashi/loop
import testkit

proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a `runLoop` that never returns fails the run.

const
  Tasks = 4000
  Yields = 8

var gDone: int          # accessed atomically: tasks finished
var gOffPool: int       # accessed atomically: steps that ran outside the pool
var gStopTicks: int64   # accessed atomically: when `stopLoop` was called

proc note() =
  if not isPoolWorker(): discard atomicFetchAdd(gOffPool, 1, moRelaxed)

proc hopper() {.passive.} =
  var i = 0
  while i < Yields:
    note()
    yieldTask()
    i = i + 1
  note()
  discard atomicFetchAdd(gDone, 1, moAcquireRelease)

proc stopper() {.passive.} =
  ## Waits for every hopper, then stops the loop from a pool worker.
  while atomicLoad(gDone, moAcquire) < Tasks:
    sleepMs(1)
  atomicStore(gStopTicks, getMonoTime().ticks, moRelease)
  stopLoop()

discard cAlarm(60)
initLoop()

var i = 0
while i < Tasks:
  spawnTask hopper()
  i = i + 1
spawnTask stopper()
runLoop()
let lateMs = (getMonoTime().ticks - atomicLoad(gStopTicks, moAcquire)) div 1_000_000

section "runLoop runs no task on its own thread"
check atomicLoad(gDone, moAcquire) == Tasks, "all " & $Tasks & " tasks finished"
check atomicLoad(gOffPool, moAcquire) == 0,
  $atomicLoad(gOffPool, moAcquire) & " task steps ran outside the pool"

section "runLoop returns soon after stopLoop"
check lateMs < 250, "runLoop returned " & $lateMs & " ms after stopLoop (pool shutdown included)"

finish()

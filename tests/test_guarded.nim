## `Guarded[T]` and `guarded`: module-level globals shared by four raw threads,
## no cast and no assumeSync feature in this file.
import std/[syncio, rawthreads, ticketlocks]
import hashi/guarded
import testkit

const
  Threads = 4
  Rounds = 10_000

var gSeq: Guarded[seq[int]]
var gCount: Guarded[int]
var gLock: TicketLock
var gPlain: int            # only under gLock

proc worker(p: pointer) =
  var i = 0
  while i < Rounds:
    withLock gSeq:
      it[0] = it[0] + 1
    withLock gCount:
      it = it + 1
    guarded gLock:
      gPlain = gPlain + 1
    i = i + 1

proc runThreads() =
  var thr {.noinit.}: array[Threads, RawThread]
  var k = 0
  while k < Threads:
    try:
      create thr[k], worker, nil
    except:
      check false, "thread creation failed"
      return
    k = k + 1
  k = 0
  while k < Threads:
    thr[k].join()
    k = k + 1

proc readSeq(): int =
  withLock gSeq:
    result = it[0]

proc readCount(): int =
  withLock gCount:
    result = it

proc readPlain(): int =
  guarded gLock:
    result = gPlain

section "Guarded[T] and guarded under contention"
gSeq = initGuarded(@[0])
gCount = initGuarded(0)
runThreads()
check readSeq() == Threads * Rounds, "Guarded[seq[int]] ends at 40000"
check readCount() == Threads * Rounds, "Guarded[int] ends at 40000"
check readPlain() == Threads * Rounds, "guarded(lock) ends at 40000"
finish()

## The passive half of the outbound queue: the writer loop, the producer's
## space-wait, and the driver's join.
##
## `import` this alongside `hashi/ws/outq` and `hashi/ws/session`. A
## connection using `useOutQueue` needs `wsWriterLoop` spawned as its own
## task, `wsAwaitSpace` for producer backpressure, and `wsAwaitWriterDone`
## for the driver to join before closing the fd.
##
## Every park here follows one shape: arm-or-self-resume under the queue's
## lock (see `hashi/ws/outq`'s `armOrResume*` procs), then an unconditional
## `suspend()`. That unconditional suspend is what Nimony's CPS transform
## needs; do not turn it into a conditional suspend.

import std/monotimes
import hashi/loop
import hashi/log
import hashi/ws/session
import hashi/ws/outq
import hashi/ws/session_io

proc submitAll*(cs: seq[Continuation]) =
  ## Resume a batch claimed under the queue lock. Always called AFTER release:
  ## `submit` caller-runs under pool saturation, so submitting under the lock
  ## could execute arbitrary continuation code while holding it.
  var i = 0
  while i < cs.len:
    submit(cs[i])
    i = i + 1

proc wsAwaitSpace*(q: OutQueue; lane = lnStream) {.passive.} =
  ## Producer-side backpressure: park until `lane` drains to its low mark,
  ## or the connection closes. The caller re-checks `wsEnqueue` after this —
  ## a wake is permission to retry, never a guarantee of room.
  let c = delay()
  armOrResumeSpace(q, c, lane)
  suspend()

proc wsAwaitWriterDone*(q: OutQueue) {.passive.} =
  ## Driver-side join: park until the writer loop has exited, so the fd is not
  ## closed out from under a CLOSE frame still being written.
  let c = delay()
  armOrResumeJoin(q, c)
  suspend()

proc wsWriterLoop*(ws: WsConn; q: OutQueue) {.passive.} =
  ## The sole owner of the socket's write side once a connection is in
  ## queued mode. Pops by lane priority and writes one complete message at a
  ## time, so messages never interleave and `ws.sbuf` has exactly one user.
  ## Runs until the queue closes and drains (`pkDone`) or a write fails.
  ##
  ## There is deliberately no sleep-based pacing here: the STREAM lane's byte
  ## bound (enforced at enqueue time) plus the fd's `SO_SNDBUF` cap (set by
  ## `useOutQueue` at accept) are what keep the backlog in the queue instead
  ## of the socket buffer. `wsSend` already parks in `waitWrite` once the
  ## kernel is full, and while parked nothing more is handed down — the
  ## socket itself is the clock.
  var running = true
  while running:
    let p = popNext(q)
    if p.kind == pkMsg:
      # `raw` messages are complete frames already (PONG/CLOSE — control opcodes
      # wsSend cannot express); everything else is a payload we frame here.
      var ok = false
      if p.msg.raw:
        ok = wsWriteAll(ws, frameString(p.msg))
      else:
        ok = wsSend(ws, p.msg.data, p.msg.binary)
      if ok:
        # Receipt→wire latency for a stamped message. Reported HERE and nowhere
        # else: this is the first moment the bytes have actually left, and it is
        # the number the outbound-queue work exists to move.
        if p.msg.stamp > 0:
          log(LogLevel.info, "outq: reply on the wire +" &
              $((getMonoTime().ticks - p.msg.stamp) div 1_000_000) & "ms")
        # Draining a message may have freed room for producers parked on its lane.
        submitAll(takeSpaceWaiters(q))
      else:
        # Write failed ⇒ the client is gone. This is the ONE place the
        # dead-client verdict is formed; producers learn it as eqClosed.
        ws.open = false
        submitAll(closeQueue(q))
        running = false
    elif p.kind == pkEmpty:
      let c = delay()
      armOrResumeWriter(q, c)
      suspend()
    else:
      running = false          # pkDone: closed and drained
  submitAll(markWriterDone(q))

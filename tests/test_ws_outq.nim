## Outbound-queue unit tests — the non-passive core (lanes, byte bound,
## drop-by-stream, cancellation, close). The park/wake halves need the reactor
## and are exercised by the integration test.
##
## No continuation is ever parked here, so no `submit` fires and the pool is not
## required — these are pure locked-state transitions.

import testkit
import hashi/ws/outq

section "lane priority"
block:
  let q = newOutQueue()
  check wsEnqueue(q, lnStream, "chunk1", true, 7) == eqOk, "stream enqueue ok"
  check wsEnqueue(q, lnStream, "chunk2", true, 7) == eqOk, "stream enqueue ok"
  check wsEnqueue(q, lnControl, "browse-reply", false) == eqOk, "control enqueue ok"
  check wsEnqueue(q, lnUrgent, "pong", false) == eqOk, "urgent enqueue ok"
  # URGENT first, then CONTROL, then STREAM — and STREAM stays FIFO.
  let a = popNext(q)
  check a.kind == pkMsg and frameString(a.msg) == "pong", "urgent drains first"
  let b = popNext(q)
  check b.kind == pkMsg and frameString(b.msg) == "browse-reply", "control beats stream"
  let c = popNext(q)
  check c.kind == pkMsg and frameString(c.msg) == "chunk1", "stream FIFO 1"
  let d = popNext(q)
  check d.kind == pkMsg and frameString(d.msg) == "chunk2", "stream FIFO 2"
  check popNext(q).kind == pkEmpty, "empty when drained"

section "a control reply overtakes a deep stream backlog"
block:
  # The whole point of the design: a reply enqueued LAST comes out FIRST.
  let q = newOutQueue(highBytes = 1024 * 1024)
  var i = 0
  while i < 200:
    discard wsEnqueue(q, lnStream, "0123456789", true, 1)
    i = i + 1
  check wsEnqueue(q, lnControl, "series-reply", false) == eqOk, "reply queued behind 200 chunks"
  let first = popNext(q)
  check first.kind == pkMsg and frameString(first.msg) == "series-reply",
        "reply overtakes the backlog"

section "STREAM lane is byte-bounded"
block:
  let q = newOutQueue(highBytes = 100, lowBytes = 40)
  check wsEnqueue(q, lnStream, "0123456789", true, 1) == eqOk, "under budget"
  check queuedBytes(q) == 10, "bytes accounted"
  var i = 0
  while i < 9:
    discard wsEnqueue(q, lnStream, "0123456789", true, 1)
    i = i + 1
  check queuedBytes(q) == 100, "at budget"
  check wsEnqueue(q, lnStream, "more", true, 1) == eqFull,
        "stream refused at budget — backpressure, NOT a dead client"
  check wsEnqueue(q, lnControl, "reply", false) == eqOk,
        "a full STREAM lane does not refuse CONTROL"

section "CONTROL lane is byte-bounded; raw protocol frames are exempt"
block:
  let q = newOutQueue(controlHighBytes = 20, controlLowBytes = 5)
  check wsEnqueue(q, lnControl, "0123456789", false) == eqOk, "under budget"
  check wsEnqueue(q, lnControl, "0123456789", false) == eqOk, "at budget"
  check queuedBytes(q, lnControl) == 20, "control bytes accounted"
  check wsEnqueue(q, lnControl, "one more reply", false) == eqFull,
        "control refused at budget — a stalled client, not a dead one"
  check not wsQueueClosed(q), "a full CONTROL lane is a healthy queue"
  check wsEnqueue(q, lnControl, "\x88\x02\x03\xe8", false, -1, true) == eqOk,
        "a raw CLOSE frame is never refused"
  check queuedBytes(q, lnControl) == 20, "raw frames are not counted"
  check wsEnqueue(q, lnStream, "chunk", true, 1) == eqOk,
        "a full CONTROL lane does not refuse STREAM"
  discard popNext(q)
  check queuedBytes(q, lnControl) == 10, "popping a reply frees its bytes"
  discard popNext(q)
  discard popNext(q)
  check queuedBytes(q, lnControl) == 0, "popping the raw frame frees nothing"

section "URGENT holds only the latest PONG"
block:
  let q = newOutQueue()
  check wsEnqueue(q, lnUrgent, "pong-1", false, -1, true, 0'i64, true) == eqOk, "first PONG"
  check wsEnqueue(q, lnUrgent, "pong-2", false, -1, true, 0'i64, true) == eqOk, "second PONG"
  check wsEnqueue(q, lnUrgent, "pong-3", false, -1, true, 0'i64, true) == eqOk, "third PONG"
  check queuedCount(q, lnUrgent) == 1, "a PING flood queues one PONG, not one per PING"
  let m = popNext(q)
  check m.kind == pkMsg and frameString(m.msg) == "pong-3", "the latest PONG is the one kept"
  check popNext(q).kind == pkEmpty, "nothing else queued"

section "drop-by-stream frees only that stream's bytes"
block:
  let q = newOutQueue()
  discard wsEnqueue(q, lnStream, "aaaa", true, 1)
  discard wsEnqueue(q, lnStream, "bbbbbb", true, 2)
  discard wsEnqueue(q, lnStream, "cccc", true, 1)
  check queuedBytes(q) == 14, "three messages accounted"
  wsDropStream(q, 1)
  check queuedBytes(q) == 6, "only stream 1's bytes freed"
  let m = popNext(q)
  check m.kind == pkMsg and m.msg.streamId == 2, "stream 2 survives"
  check popNext(q).kind == pkEmpty, "nothing else left"

section "cancellation flag is per stream and retireable"
block:
  let q = newOutQueue()
  check not streamCancelled(q, 4), "not cancelled initially"
  markCancelled(q, 4)
  check streamCancelled(q, 4), "cancelled"
  check not streamCancelled(q, 5), "other stream unaffected"
  markCancelled(q, 4)
  check streamCancelled(q, 4), "idempotent"
  clearCancelled(q, 4)
  check not streamCancelled(q, 4), "retired so a reused id is not born cancelled"

section "close refuses new work but still drains what is queued"
block:
  let q = newOutQueue()
  discard wsEnqueue(q, lnStream, "tail", true, 1)
  discard closeQueue(q)
  check wsQueueClosed(q), "closed flag visible to producers"
  check wsEnqueue(q, lnControl, "late", false) == eqClosed,
        "eqClosed is the ONLY dead-client signal"
  let m = popNext(q)
  check m.kind == pkMsg and frameString(m.msg) == "tail", "already-queued work still drains"
  check popNext(q).kind == pkDone, "then the writer is told to exit"

section "eqFull and eqClosed are distinguishable"
block:
  # Conflating these would abort every stream on a slow link — the exact case
  # the design exists to serve. Guard it explicitly.
  let q = newOutQueue(highBytes = 4)
  discard wsEnqueue(q, lnStream, "aaaa", true, 1)
  check wsEnqueue(q, lnStream, "b", true, 1) == eqFull, "full is not closed"
  check not wsQueueClosed(q), "a full queue is a HEALTHY queue"

finish()

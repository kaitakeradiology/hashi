## WebSocket outbound queue: lane-prioritised, bounded, single-writer.
##
## A connection's outbound bytes can come from more than one task (e.g. a
## reply handler and a background stream). Without a shared queue two such
## tasks would race the socket directly, and a small control reply queued
## behind a large payload already handed to the kernel would wait for that
## payload to drain — bytes in the kernel's send buffer cannot be reordered.
## This module gives a connection one outbound queue with three priority
## lanes (`WsLane`) and a single writer that drains it in lane order, so a
## control message only ever waits behind other control messages, never
## behind a stream backlog.
##
## Ordering here is only half the fix: the writer must also pace what it
## hands to the kernel, or the backlog just re-accumulates in the socket
## send buffer where lanes mean nothing again. See `hashi/ws/outq_pacing`.
##
## This module is non-passive and importable: types, the locked queue ops,
## and the park/wake claim protocol. The passive writer loop that drains the
## queue is `hashi/ws/outq_writer`, imported by the connection driver
## alongside this module.
##
## Claim-token discipline: `writerParked` is the single token authorising a
## resume of `writerCont`, flipped false under the lock by whoever claims
## it, so every parked continuation is resumed exactly once, by exactly one
## claimant. The same protocol guards `spaceConts` and `joinCont`.
##
## `submit` is non-lossy but can caller-run under scheduler saturation — it
## may execute the continuation to its next suspension point on the calling
## thread rather than handing it to another worker. So a `wsEnqueue` that
## wakes the writer may itself end up doing writer work. Correctness holds
## either way (still one execution, still one fd owner), but enqueue is not
## guaranteed O(1) at the tail.

{.feature: "lenientnils".}   # nil/default for Continuation

import std/ticketlocks
import hashi/loop

func toBytes(s: string): seq[byte] =
  if s.len == 0: return @[]
  result = newSeqUninit[byte](s.len)
  copyMem(addr result[0], readRawData(s), s.len)

func toString(b: openArray[byte]): string =
  result = ""
  if b.len > 0:
    copyMem(beginStore(result, b.len), addr b[0], b.len)
    endStore(result)

type
  WsLane* = enum
    ## Lanes are by ownership, not by frame type: everything on `lnStream`
    ## for one stream must stay in the order its producer enqueued it, so a
    ## lane cannot reorder within itself by looking at frame content.
    lnUrgent    ## WS protocol frames the reader must emit: PONG, CLOSE.
    lnControl   ## Replies belonging to no stream: e.g. request/response replies.
    lnStream    ## Ongoing stream data. Strict FIFO per stream.

  EnqResult* = enum
    eqOk        ## queued
    eqFull      ## the lane is at its byte budget; the caller should park via
                ## `wsAwaitSpace` for that lane and retry. Not a dead-client
                ## signal — on a slow link this is the normal steady state.
    eqClosed    ## the connection is finished; the only dead-client signal

  PopKind* = enum
    pkMsg       ## `msg` is valid
    pkEmpty     ## nothing queued — the writer should park
    pkDone      ## closed and drained — the writer should exit

  OutMsg* = object
    data*: seq[byte]    ## payload, or (when `raw`) a complete pre-serialized frame.
                        ## `seq[byte]` rather than `string` so a caller with a
                        ## `seq[byte]` chunk (`wsSend`'s zero-copy overload) never
                        ## pays a seq→string round-trip to get it onto the queue.
    binary*: bool
    raw*: bool          ## true ⇒ `data` is already a serialized frame and the writer
                        ## must emit it verbatim rather than framing it. This is how
                        ## control opcodes reach the queue: PONG and CLOSE are neither
                        ## text nor binary, so `wsSend` (which only knows opText and
                        ## opBinary) cannot express them.
    streamId*: int      ## lnStream: owning stream id, for wsDropStream. Else -1.
    stamp*: int64       ## monotonic ns when the app accepted the request this
                        ## message answers; 0 ⇒ not measured. The writer reports
                        ## the age, since `wsEnqueue` returns long before the bytes
                        ## actually leave — timing at the enqueue site would
                        ## measure work the queue has not done yet.
    coalesce*: bool     ## only the latest such message in its lane matters: a
                        ## new one replaces a queued one. PONG (RFC 6455 5.5.3).

  SpaceWaiter = object
    lane: WsLane
    cont: Continuation

  PopResult* = object
    kind*: PopKind
    msg*: OutMsg        ## valid iff `kind == pkMsg`

  OutQueue* = ref object
    lock: TicketLock
    urgent: seq[OutMsg]
    control: seq[OutMsg]
    stream: seq[OutMsg]
    streamBytes: int          ## bytes currently queued on the STREAM lane
    highBytes: int            ## STREAM enqueue refuses at/above this
    lowBytes: int             ## STREAM producers wake at/below this
    controlBytes: int         ## payload bytes queued on the CONTROL lane
    controlHighBytes: int     ## CONTROL enqueue refuses at/above this
    controlLowBytes: int      ## CONTROL producers wake at/below this
    pacingBytes*: int         ## `SO_SNDBUF` ceiling, applied to the fd by
                              ## `useOutQueue`. Not consulted by the writer: the
                              ## kernel enforces it, and `wsSend` parking in
                              ## `waitWrite` is how the writer feels it. 0 to
                              ## leave the socket unpaced.
    writerCont: Continuation
    writerParked: bool        ## THE claim token for writerCont
    spaceConts: seq[SpaceWaiter]    ## producers parked in wsAwaitSpace
    joinCont: Continuation
    joinParked: bool          ## claim token for joinCont (the driver, awaiting drain)
    closed: bool              ## no new work accepted
    writerDone: bool          ## writer has exited; safe to close the fd
    cancelled: seq[int]       ## stream ids cancelled but possibly still producing

const
  DefaultHighBytes* = 512 * 1024
    ## STREAM-lane budget: `wsEnqueue` refuses (`eqFull`) at or above this many
    ## queued STREAM bytes. Deliberately small — it is what keeps the backlog
    ## in the queue, where lanes are meaningful, rather than in the socket
    ## send buffer, where they are not. Too large and prioritising stops
    ## working; too small and the link idles between writes.
  DefaultLowBytes* = 128 * 1024
    ## STREAM-lane low-water mark: producers parked in `wsAwaitSpace` wake once
    ## queued STREAM bytes drop to or below this.
  DefaultPacingBytes* = 64 * 1024
    ## Default `OutQueue.pacingBytes`: the `SO_SNDBUF` ceiling `useOutQueue`
    ## applies to the socket. See `setWsSendBuf` for what setting it does.
  DefaultControlHighBytes* = 1024 * 1024
    ## CONTROL-lane budget for application payloads: `wsEnqueue` refuses
    ## (`eqFull`) at or above this many queued CONTROL bytes. Replies are
    ## protocol-shaped and small, so a lane this deep means the client is not
    ## reading; without a bound a fast application and a stalled client
    ## would grow the process without limit. Raw protocol frames (CLOSE) are
    ## never refused.
  DefaultControlLowBytes* = 256 * 1024
    ## CONTROL-lane low-water mark: producers parked in `wsAwaitSpace` for
    ## that lane wake once queued CONTROL bytes drop to or below this.

proc newOutQueue*(highBytes = DefaultHighBytes; lowBytes = DefaultLowBytes;
                  pacingBytes = DefaultPacingBytes;
                  controlHighBytes = DefaultControlHighBytes;
                  controlLowBytes = DefaultControlLowBytes): OutQueue =
  result = OutQueue(urgent: @[], control: @[], stream: @[],
                    streamBytes: 0, highBytes: highBytes, lowBytes: lowBytes,
                    controlBytes: 0, controlHighBytes: controlHighBytes,
                    controlLowBytes: controlLowBytes,
                    pacingBytes: pacingBytes,
                    writerCont: default(Continuation), writerParked: false,
                    spaceConts: @[], joinCont: default(Continuation),
                    joinParked: false, closed: false, writerDone: false,
                    cancelled: @[])

proc takeWriter(q: OutQueue; c: var Continuation): bool =
  ## Claim the parked writer, if any. **Caller must hold the lock**; the actual
  ## `submit` happens after release (never submit under a lock — the caller-runs
  ## path would then run arbitrary continuation code holding it).
  result = q.writerParked
  if result:
    q.writerParked = false
    c = q.writerCont
    q.writerCont = default(Continuation)

proc addCoalescing(lane: var seq[OutMsg]; m: OutMsg) =
  ## Append `m`; if it coalesces, first drop the queued message it supersedes.
  if m.coalesce:
    var i = 0
    while i < lane.len:
      if lane[i].coalesce:
        lane.delete(i)
      else:
        inc i
  lane.add m

proc wsEnqueue*(q: OutQueue; lane: WsLane; data: seq[byte]; binary: bool;
                streamId = -1; raw = false; stamp = 0'i64;
                coalesce = false): EnqResult =
  ## Queue one complete message. Non-passive: a locked push plus at most one
  ## writer wake.
  ##
  ## Every lane is bounded. STREAM and CONTROL each have a byte budget and
  ## answer `eqFull` at it, for application payloads; the caller parks in
  ## `wsAwaitSpace` for that lane and retries. A `raw` protocol frame (CLOSE)
  ## is never refused: it is a few bytes, and refusing it would leave the
  ## peer without the close it is owed. URGENT holds only PONGs, which
  ## `coalesce`: a new one replaces the queued one, as RFC 6455 5.5.3
  ## allows, so a peer flooding PINGs costs one queued frame, not one per
  ## PING.
  var wake = false
  var c = default(Continuation)
  q.lock.acquire()
  if q.closed:
    q.lock.release()
    return eqClosed
  if not raw:
    if lane == lnStream and q.streamBytes >= q.highBytes:
      q.lock.release()
      return eqFull
    if lane == lnControl and q.controlBytes >= q.controlHighBytes:
      q.lock.release()
      return eqFull
  let m = OutMsg(data: data, binary: binary, raw: raw, streamId: streamId,
                 stamp: stamp, coalesce: coalesce)
  case lane
  of lnUrgent: addCoalescing(q.urgent, m)
  of lnControl:
    addCoalescing(q.control, m)
    if not raw: q.controlBytes = q.controlBytes + data.len
  of lnStream:
    q.stream.add m
    q.streamBytes = q.streamBytes + data.len
  wake = takeWriter(q, c)
  q.lock.release()
  if wake: submit(c)
  result = eqOk

proc wsEnqueue*(q: OutQueue; lane: WsLane; data: string; binary: bool;
                streamId = -1; raw = false; stamp = 0'i64;
                coalesce = false): EnqResult =
  ## String convenience for the CONTROL/URGENT path — `serializeFrame` returns a
  ## string, and PONG/CLOSE are a handful of bytes, so the copy here is free. The
  ## `seq[byte]` overload above stays the hot path: stream chunks must not pay a
  ## conversion per chunk.
  result = wsEnqueue(q, lane, toBytes(data), binary, streamId, raw, stamp,
                     coalesce)

proc frameString*(m: OutMsg): string =
  ## A `raw` message's bytes as the string `wsWriteAll` wants.
  result = toString(m.data)

proc popNext*(q: OutQueue): PopResult =
  ## Writer-side pop, strict lane priority, FIFO within a lane. Also reports when
  ## draining a STREAM message frees enough room to wake parked producers — the
  ## writer performs those wakes (see `takeSpaceWaiters`).
  q.lock.acquire()
  if q.urgent.len > 0:
    result = PopResult(kind: pkMsg, msg: q.urgent[0])
    q.urgent.delete(0)
  elif q.control.len > 0:
    result = PopResult(kind: pkMsg, msg: q.control[0])
    q.control.delete(0)
    if not result.msg.raw:
      q.controlBytes = q.controlBytes - result.msg.data.len
      if q.controlBytes < 0: q.controlBytes = 0
  elif q.stream.len > 0:
    result = PopResult(kind: pkMsg, msg: q.stream[0])
    q.stream.delete(0)
    q.streamBytes = q.streamBytes - result.msg.data.len
    if q.streamBytes < 0: q.streamBytes = 0
  elif q.closed:
    result = PopResult(kind: pkDone, msg: default(OutMsg))
  else:
    result = PopResult(kind: pkEmpty, msg: default(OutMsg))
  q.lock.release()

proc laneHasRoom(q: OutQueue; lane: WsLane): bool =
  ## Under the lock: whether a producer parked for `lane` may retry.
  case lane
  of lnStream: q.streamBytes <= q.lowBytes
  of lnControl: q.controlBytes <= q.controlLowBytes
  of lnUrgent: true

proc takeSpaceWaiters*(q: OutQueue): seq[Continuation] =
  ## Claim every producer parked in `wsAwaitSpace` whose lane has drained to
  ## its low mark (or the queue closed — a parked producer must never be left
  ## waiting on a dead connection). Returns them for the caller to submit
  ## AFTER releasing, same rule as takeWriter.
  result = @[]
  q.lock.acquire()
  if q.spaceConts.len > 0:
    var kept: seq[SpaceWaiter] = @[]
    var i = 0
    while i < q.spaceConts.len:
      if q.closed or laneHasRoom(q, q.spaceConts[i].lane):
        result.add q.spaceConts[i].cont
      else:
        kept.add q.spaceConts[i]
      inc i
    q.spaceConts = kept
  q.lock.release()

proc armOrResumeWriter*(q: OutQueue; c: Continuation) =
  ## Park the writer, or self-resume if work arrived between its `popNext`
  ## and here. Checking and parking happen under one lock acquisition, so
  ## there is no lost-wakeup window; letting the caller self-resume rather
  ## than skip the park keeps its `suspend()` unconditional, which is the
  ## shape Nimony's CPS transform needs. The submit is deliberately outside
  ## the lock, since `submit` can caller-run.
  var selfResume = false
  q.lock.acquire()
  if q.urgent.len > 0 or q.control.len > 0 or q.stream.len > 0 or q.closed:
    selfResume = true
  else:
    q.writerCont = c
    q.writerParked = true
  q.lock.release()
  if selfResume: submit(c)

proc armOrResumeSpace*(q: OutQueue; c: Continuation; lane = lnStream) =
  ## Park a producer until `lane` drains to its low mark; self-resume if
  ## there is already room or the queue closed. Same unconditional-suspend
  ## shape.
  var selfResume = false
  q.lock.acquire()
  if q.closed or laneHasRoom(q, lane):
    selfResume = true
  else:
    q.spaceConts.add SpaceWaiter(lane: lane, cont: c)
  q.lock.release()
  if selfResume: submit(c)

proc wsDropStream*(q: OutQueue; streamId: int) =
  ## Discard queued STREAM-lane messages belonging to one stream. Used by
  ## cancellation. Does NOT stop the producer — that needs the cancelled flag
  ## below plus an upstream abort; dropping alone would let the producer finish
  ## unaware and emit a SECOND terminal frame for the same id.
  q.lock.acquire()
  var kept: seq[OutMsg] = @[]
  var freed = 0
  var i = 0
  while i < q.stream.len:
    if q.stream[i].streamId == streamId:
      freed = freed + q.stream[i].data.len
    else:
      kept.add q.stream[i]
    i = i + 1
  q.stream = kept
  q.streamBytes = q.streamBytes - freed
  if q.streamBytes < 0: q.streamBytes = 0
  q.lock.release()

proc markCancelled*(q: OutQueue; streamId: int) =
  q.lock.acquire()
  var seen = false
  var i = 0
  while i < q.cancelled.len:
    if q.cancelled[i] == streamId: seen = true
    i = i + 1
  if not seen: q.cancelled.add streamId
  q.lock.release()

proc streamCancelled*(q: OutQueue; streamId: int): bool =
  ## Producers check this after each fetch step and before each enqueue. On true
  ## they stop and emit NOTHING — the canceller already sent the terminal frame.
  q.lock.acquire()
  result = false
  var i = 0
  while i < q.cancelled.len:
    if q.cancelled[i] == streamId: result = true
    i = i + 1
  q.lock.release()

proc clearCancelled*(q: OutQueue; streamId: int) =
  ## Retire a cancelled id once its producer has stopped, so a later stream
  ## reusing the id is not cancelled on arrival.
  q.lock.acquire()
  var kept: seq[int] = @[]
  var i = 0
  while i < q.cancelled.len:
    if q.cancelled[i] != streamId: kept.add q.cancelled[i]
    i = i + 1
  q.cancelled = kept
  q.lock.release()

proc closeQueue*(q: OutQueue): seq[Continuation] =
  ## Refuse new work and claim EVERY parked continuation so nothing is stranded
  ## on a dead connection: the writer (so it observes pkDone and exits) and all
  ## parked producers (so they observe eqClosed and abort). Returns them for the
  ## caller to submit after release.
  result = @[]
  q.lock.acquire()
  q.closed = true
  var c = default(Continuation)
  if takeWriter(q, c): result.add c
  var i = 0
  while i < q.spaceConts.len:
    result.add q.spaceConts[i].cont
    i = i + 1
  q.spaceConts = @[]
  q.lock.release()

proc wsQueueClosed*(q: OutQueue): bool =
  ## The dead-client signal, checked by producers at loop head. Distinct from
  ## `eqFull`, which is healthy backpressure.
  q.lock.acquire()
  result = q.closed
  q.lock.release()

proc markWriterDone*(q: OutQueue): seq[Continuation] =
  ## The writer's exit: record it and claim the driver if it is parked waiting to
  ## close the fd. Returns it for submission after release.
  result = @[]
  q.lock.acquire()
  q.writerDone = true
  if q.joinParked:
    q.joinParked = false
    result.add q.joinCont
    q.joinCont = default(Continuation)
  q.lock.release()

proc armOrResumeJoin*(q: OutQueue; c: Continuation) =
  ## Park the driver until the writer has exited; self-resume if it already has.
  ## Unconditional-suspend shape, as above. The driver must NOT `closeFd` before
  ## this returns, or the writer's final CLOSE frame is written to a dead fd.
  var selfResume = false
  q.lock.acquire()
  if q.writerDone:
    selfResume = true
  else:
    q.joinCont = c
    q.joinParked = true
  q.lock.release()
  if selfResume: submit(c)

proc queuedBytes*(q: OutQueue; lane = lnStream): int =
  ## Queued payload bytes on `lane`, for tests and telemetry. URGENT carries
  ## only raw frames and reports zero.
  q.lock.acquire()
  case lane
  of lnStream: result = q.streamBytes
  of lnControl: result = q.controlBytes
  of lnUrgent: result = 0
  q.lock.release()

proc queuedCount*(q: OutQueue; lane: WsLane): int =
  ## Messages queued on `lane`, for tests and telemetry.
  q.lock.acquire()
  case lane
  of lnUrgent: result = q.urgent.len
  of lnControl: result = q.control.len
  of lnStream: result = q.stream.len
  q.lock.release()

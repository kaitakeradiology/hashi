## WebSocket session I/O: the passive `wsRecv`/`wsSend`/`wsClose`/`wsPeek`/
## `wsSkip` ops.
##
## `import` this alongside `hashi/ws/session` to write a handler
## (`proc(ws: WsConn) {.passive.}`). Protocol correctness (framing,
## fragmentation, UTF-8, close codes) lives in `hashi/ws/protocol`; this
## module is the I/O loop that drives it and surfaces complete messages to
## the handler.

import std/monotimes
import hashi/loop
import hashi/buffer
import hashi/http/request
import hashi/http/config
import hashi/ws/frame
import hashi/ws/protocol
import hashi/ws/session
import hashi/ws/outq

proc cRecv(fd: cint; buf: pointer; len: csize_t; flags: cint): int {.importc: "recv", header: "<sys/socket.h>".}
const MsgDontWait = (when defined(macosx): 0x80.cint else: 0x40.cint)
  ## `MSG_DONTWAIT`, for `wsPeek`'s non-blocking recv: it replaces `wsRecv`'s
  ## blocking `waitRead` so a peek never parks on an empty socket (EAGAIN
  ## means nothing is buffered yet, not an error).

proc wsWriteAll*(ws: WsConn; data: string): bool {.passive.} =
  ## Write `data` in full, handling short writes. Returns false on a write
  ## error. Accumulates the connection's send counters: time suspended in
  ## `waitWrite` (backpressure) and syscall count.
  result = true
  var wbuf = default(array[4096, char])
  var off = 0
  var cont = true
  while off < data.len and cont:
    var clen = data.len - off
    if clen > 4096: clen = 4096
    copyOut(addr wbuf[0], data, off, clen)
    var wOff = 0
    while wOff < clen and cont:
      let t0 = getMonoTime()
      let w = waitWrite(ws.fd, addr wbuf[wOff], clen - wOff)
      ws.sendBlockedNs = ws.sendBlockedNs + (getMonoTime() - t0).inNanoseconds
      ws.writeSyscalls = ws.writeSyscalls + 1
      if w <= 0:
        result = false
        cont = false
      else:
        wOff = wOff + w
    off = off + clen

proc wsEmitCtl(ws: WsConn; frame: string; lane = lnUrgent;
               coalesce = false): bool {.passive.} =
  ## Emit a complete, pre-serialized control frame (PONG / CLOSE). In queued
  ## mode (`ws.hasOutq`) this enqueues onto `lane` instead of writing the fd
  ## directly, so the writer loop stays the only task that touches the socket
  ## — a direct write here would race it. Not queued: the plain inline write.
  ##
  ## Callers pick the lane deliberately: PONG is liveness and must not wait
  ## behind data, so it goes `lnUrgent`. CLOSE must not jump ahead of a
  ## queued explanatory frame (e.g. an `error` message) or the client sees
  ## the disconnect without learning why, so it goes `lnControl` — ahead of
  ## the STREAM lane, behind anything already on CONTROL. A PONG `coalesce`s:
  ## only the reply to the latest PING is kept queued (RFC 6455 5.5.3).
  if ws.hasOutq:
    result = wsEnqueue(ws.outq, lane, frame, false, -1, true, 0'i64,
                       coalesce) != eqClosed
  else:
    result = wsWriteAll(ws, frame)

proc wsConsume(ws: WsConn; consumed: int) =
  ## Drop the first `consumed` (parsed) bytes from the inbound buffer. Frees the
  ## large buffer before the caller builds/echoes — keeps peak memory down.
  dropPrefix(ws.acc, consumed)

proc fillSendBuf(ws: WsConn; op: Opcode; data: string): int =
  ## Non-passive: build [frame header | payload] into the connection's reusable
  ## send buffer (one heap buffer, grown to the largest frame seen, reused after).
  ## Returns the total length. Coalescing into one buffer lets wsSend issue a
  ## single write — no separate tiny-header packet, and no 4 KB chunking that with
  ## TCP_NODELAY put each slice in its own segment/syscall.
  let hdr = frameHeader(op, data.len)
  let total = hdr.len + data.len
  if ws.sbuf.len < total:
    ws.sbuf.setLen(total)
  copyOut(addr ws.sbuf[0], hdr, 0, hdr.len)
  if data.len > 0:
    copyOut(addr ws.sbuf[hdr.len], data, 0, data.len)
  result = total

proc fillSendBuf(ws: WsConn; op: Opcode; data: openArray[byte]): int =
  ## `openArray[byte]` payload variant: the payload is appended with one
  ## `copyMem`, avoiding a per-byte loop or a seq→string round-trip.
  let hdr = frameHeader(op, data.len)
  let total = hdr.len + data.len
  if ws.sbuf.len < total:
    ws.sbuf.setLen(total)
  copyOut(addr ws.sbuf[0], hdr, 0, hdr.len)
  if data.len > 0:
    copyMem(addr ws.sbuf[hdr.len], addr data[0], data.len)
  result = total

proc writeSendBuf(ws: WsConn; total: int): bool {.passive.} =
  ## Write the first `total` bytes of the send buffer in one pass, handling
  ## short writes. Updates `ws.writeSyscalls` and `ws.sendBlockedNs` on every
  ## `waitWrite`; false once the peer is gone.
  result = true
  var off = 0
  var cont = true
  while off < total and cont:
    let t0 = getMonoTime()
    let w = waitWrite(ws.fd, addr ws.sbuf[off], total - off)
    ws.sendBlockedNs = ws.sendBlockedNs + (getMonoTime() - t0).inNanoseconds
    ws.writeSyscalls = ws.writeSyscalls + 1
    if w <= 0:
      result = false
      cont = false
    else:
      off = off + w

proc wsSend*(ws: WsConn; data: string; binary = false): bool {.passive.} =
  ## Send one data message (text by default, binary if `binary`). Header and
  ## payload are coalesced into the connection's reusable buffer and written
  ## in one pass.
  let op = if binary: opBinary else: opText
  result = writeSendBuf(ws, fillSendBuf(ws, op, data))
  if result:
    ws.bytesSent = ws.bytesSent + int64(data.len)

proc wsSend*(ws: WsConn; data: seq[byte]; binary = true): bool {.passive.} =
  ## Send one binary-payload data message, defaulting to binary. The bytes
  ## are coalesced with one `copyMem`, no seq→string copy at the send
  ## boundary. `seq[byte]`, not `openArray`: a `.passive` proc lifts its
  ## params into its CPS continuation environment, where a fat `openArray`
  ## pointer+length does not survive; a managed single-pointer `seq` does,
  ## like `string`.
  let op = if binary: opBinary else: opText
  result = writeSendBuf(ws, fillSendBuf(ws, op, data))
  if result:
    ws.bytesSent = ws.bytesSent + int64(data.len)

proc wsClose*(ws: WsConn; code = 1000; reason = ""): bool {.passive.} =
  ## Send a CLOSE frame and mark the connection closed. The handler should
  ## return after this; the driver closes the fd.
  ##
  ## Queued mode: the frame goes on the CONTROL lane — behind any control
  ## message already queued (an explanatory frame must reach the client
  ## first) but ahead of the STREAM lane, so a close never waits behind a
  ## data backlog.
  ws.open = false
  result = wsEmitCtl(ws, serializeFrame(opClose, closeFrameBody(code) & reason), lnControl)

proc recvMessage(ws: WsConn; blocking: bool): WsMessage {.passive.} =
  ## The receive loop behind `wsRecv` and `wsPeek`: parse frames from the
  ## inbound buffer, reading more when a frame is incomplete, until a
  ## complete data message or a close. Ping → pong and the close handshake
  ## are answered here; a protocol error sends the right close code and
  ## yields `wmClose`, with `ws.open` already false. The limits are the
  ## server config's.
  ##
  ## `blocking` reads park in `waitRead`; otherwise the read is a
  ## `MSG_DONTWAIT` recv and an empty socket yields `wmNone` instead of
  ## suspending. A real recv error other than EAGAIN also yields `wmNone`
  ## there; it resurfaces on the next blocking send or recv.
  result = WsMessage(kind: wmClose, data: "")
  var done = false
  while not done:
    var f = default(Frame)
    let pr = parseFrame(ws.acc, 0, f, gServerConfig.maxWsPayload)
    if pr[0] == psIncomplete:
      var n = 0
      if blocking:
        n = waitRead(ws.fd, addr ws.rbuf[0], ws.rbuf.len)
      else:
        n = cRecv(ws.fd, addr ws.rbuf[0], csize_t(ws.rbuf.len), MsgDontWait)
      if n == 0 or (n < 0 and blocking):
        ws.open = false
        result = WsMessage(kind: wmClose, data: "")
        done = true
      elif n < 0:
        result = WsMessage(kind: wmNone, data: "")
        done = true
      else:
        appendBytes(ws.acc, addr ws.rbuf[0], n)
    elif pr[0] == psError:
      discard wsEmitCtl(ws, serializeFrame(opClose, closeFrameBody(1002)), lnControl)
      ws.open = false
      result = WsMessage(kind: wmClose, data: "")
      done = true
    else:
      # Consume the (masked) frame bytes before building the result — frees the
      # big inbound buffer first. Only `handleFrame`'s returned action is read
      # after this; `f` itself is not touched again.
      wsConsume(ws, pr[1])
      let act = handleFrame(ws.st, f, gServerConfig.maxWsMessage)
      if act.kind == waPong:
        if not wsEmitCtl(ws, serializeFrame(opPong, act.payload), lnUrgent, true):
          ws.open = false
          result = WsMessage(kind: wmClose, data: "")
          done = true
      elif act.kind == waMessage:
        let k = if act.opcode == opText: wmText else: wmBinary
        result = WsMessage(kind: k, data: act.payload)
        done = true
      elif act.kind == waClose:
        discard wsEmitCtl(ws,
          serializeFrame(opClose, closeFrameBody(act.closeCode) & act.payload), lnControl)
        ws.open = false
        result = WsMessage(kind: wmClose, data: act.payload)
        done = true
      # waNone (buffered fragment / pong received): keep looping.

proc wsRecv*(ws: WsConn): WsMessage {.passive.} =
  ## Block until the next complete data message, or a close/EOF. On
  ## `wmClose`, `ws.open` is already false. A message a prior `wsPeek`
  ## stashed on the connection is delivered (and cleared) before touching
  ## the socket, so a peeked-but-not-skipped message (e.g. a control message
  ## that arrived mid-stream) is returned here unchanged.
  if ws.hasPeeked:
    result = ws.peeked
    ws.hasPeeked = false
    ws.peeked = WsMessage(kind: wmNone, data: "")
  else:
    result = recvMessage(ws, true)

proc wsPeek*(ws: WsConn): WsMessage {.passive.} =
  ## Non-blocking look at the next complete data message: an empty socket
  ## yields `wmNone` (nothing complete buffered) instead of suspending. A
  ## pong reply can still suspend under send backpressure. A complete data
  ## message is drained from the buffer and stashed on the connection: this
  ## call and every following `wsPeek` return it unchanged until `wsSkip`
  ## discards it or `wsRecv` delivers it.
  if ws.hasPeeked:
    result = ws.peeked
  else:
    result = recvMessage(ws, false)
    if result.kind == wmText or result.kind == wmBinary:
      ws.peeked = result
      ws.hasPeeked = true

proc wsSkip*(ws: WsConn) {.passive.} =
  ## Discard the message the immediately-preceding `wsPeek` stashed — the caller
  ## decided to act on it (e.g. a `cancel`) and does not want `wsRecv` to see it.
  ## A peeked message left un-skipped stays stashed for the next `wsRecv` to
  ## deliver (e.g. a mid-stream `reauth` the send loop must not swallow).
  ws.hasPeeked = false
  ws.peeked = WsMessage(kind: wmNone, data: "")

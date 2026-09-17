## WebSocket protocol state machine (RFC 6455 §5.4–§5.5, §7.4) — the pure
## decision logic, independent of I/O so it can be unit-tested. The connection
## driver feeds parsed frames in and acts on the returned WsAction.
##
## Rules enforced:
##   - client→server frames MUST be masked (§5.1) → else 1002;
##   - fragmentation: data frame starts a message (FIN ends it), continuation
##     frames extend it; a continuation with no message, or a new data frame
##     mid-message, is a protocol error (§5.4) → 1002;
##   - control frames (close/ping/pong) may interleave fragments, handled
##     immediately (§5.4);
##   - text payloads MUST be valid UTF-8 (§8.1) → else 1007;
##   - close codes are validated (§7.4) → invalid → 1002.

import hashi/ws/frame

const MaxWsMessage* = 64 * 1024 * 1024
  ## Largest accepted *assembled* (fragmented) message — bounds st.buf growth so
  ## a flood of small continuation frames can't exhaust memory. Exceeded → 1009.

type
  WsState* = object
    inMessage: bool        ## a fragmented data message is in progress
    msgIsText: bool        ## that message is text (needs UTF-8 validation)
    buf: string            ## assembled fragment payload

  WsActionKind* = enum
    waNone                 ## nothing to send
    waPong                 ## reply pong with `payload`
    waMessage              ## a complete data message (`opcode`,`payload`) — echo
    waClose                ## close with `closeCode` (+ optional `payload` echo)

  WsAction* = object ## What the connection layer should do with a parsed frame.
    kind*: WsActionKind
    opcode*: Opcode        ## message type for waMessage
    payload*: string       ## pong payload / message data / close reason
    closeCode*: int        ## for waClose

proc isValidUtf8*(s: string): bool =
  ## RFC 3629 validation: rejects overlong encodings, surrogate code points,
  ## and anything past U+10FFFF. Used on text-message payloads (§8.1).
  var i = 0
  let n = s.len
  while i < n:
    let c = uint8(s[i]).int
    if c < 0x80:
      i = i + 1
    elif c >= 0xC2 and c <= 0xDF:                 # 2-byte
      if i + 1 >= n: return false
      if (uint8(s[i+1]).int and 0xC0) != 0x80: return false
      i = i + 2
    elif c >= 0xE0 and c <= 0xEF:                 # 3-byte
      if i + 2 >= n: return false
      let c1 = uint8(s[i+1]).int
      let c2 = uint8(s[i+2]).int
      if (c2 and 0xC0) != 0x80: return false
      if c == 0xE0:
        if c1 < 0xA0 or c1 > 0xBF: return false   # no overlong
      elif c == 0xED:
        if c1 < 0x80 or c1 > 0x9F: return false   # no surrogates
      else:
        if (c1 and 0xC0) != 0x80: return false
      i = i + 3
    elif c >= 0xF0 and c <= 0xF4:                 # 4-byte
      if i + 3 >= n: return false
      let c1 = uint8(s[i+1]).int
      let c2 = uint8(s[i+2]).int
      let c3 = uint8(s[i+3]).int
      if (c2 and 0xC0) != 0x80 or (c3 and 0xC0) != 0x80: return false
      if c == 0xF0:
        if c1 < 0x90 or c1 > 0xBF: return false   # no overlong
      elif c == 0xF4:
        if c1 < 0x80 or c1 > 0x8F: return false   # ≤ U+10FFFF
      else:
        if (c1 and 0xC0) != 0x80: return false
      i = i + 4
    else:
      return false                                # 0x80-0xC1, 0xF5-0xFF invalid
  result = true

proc validCloseCode(code: int): bool =
  if code >= 3000 and code <= 4999: return true   # registered/private use
  case code
  of 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011:
    result = true
  else:
    result = false                                # 1004/1005/1006/1015/etc.

proc closeAction(code: int; reason = ""): WsAction =
  result = WsAction(kind: waClose, closeCode: code, payload: reason)

proc handleClose(f: Frame): WsAction =
  ## Validate a CLOSE frame and produce the close to echo (§5.5.1, §7.4).
  let n = f.payload.len
  if n == 0:
    return closeAction(1000)
  if n == 1:
    return closeAction(1002)                      # 1-byte payload is illegal
  let code = (uint8(f.payload[0]).int shl 8) or uint8(f.payload[1]).int
  if not validCloseCode(code):
    return closeAction(1002)
  # reason (bytes after the code) must be valid UTF-8
  var reason = ""
  var i = 2
  while i < n:
    reason.add f.payload[i]
    i = i + 1
  if not isValidUtf8(reason):
    return closeAction(1007)
  result = closeAction(1000)

proc handleFrame*(st: var WsState; f: Frame; maxMessage = MaxWsMessage): WsAction =
  ## Advance the protocol state with one parsed frame, returning the action.
  if not f.masked:
    return closeAction(1002)                       # client frames must be masked

  case f.opcode
  of opClose:
    result = handleClose(f)
  of opPing:
    result = WsAction(kind: waPong, payload: f.payload)
  of opPong:
    result = WsAction(kind: waNone, payload: "")
  of opText, opBinary:
    if st.inMessage:
      return closeAction(1002)                     # data frame mid-message
    if f.fin:
      if f.opcode == opText and not isValidUtf8(f.payload):
        return closeAction(1007)
      result = WsAction(kind: waMessage, opcode: f.opcode, payload: f.payload)
    else:
      st.inMessage = true
      st.msgIsText = f.opcode == opText
      st.buf = f.payload
      result = WsAction(kind: waNone, payload: "")
  of opContinuation:
    if not st.inMessage:
      return closeAction(1002)                     # continuation with no message
    if st.buf.len + f.payload.len > maxMessage:  # bound the assembled message
      st.buf = ""
      st.inMessage = false
      return closeAction(1009)                     # message too big
    st.buf.add f.payload
    if f.fin:
      let isText = st.msgIsText
      st.inMessage = false
      st.msgIsText = false
      if isText and not isValidUtf8(st.buf):
        st.buf = ""
        return closeAction(1007)
      let op = if isText: opText else: opBinary
      result = WsAction(kind: waMessage, opcode: op, payload: st.buf)
      st.buf = ""                                  # plain copy above, then reset
    else:
      result = WsAction(kind: waNone, payload: "")

proc closeFrameBody*(code: int): string =
  ## 2-byte big-endian close code payload for a server CLOSE frame.
  result = ""
  result.add char((code shr 8) and 0xFF)
  result.add char(code and 0xFF)

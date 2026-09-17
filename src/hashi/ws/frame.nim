## WebSocket framing (RFC 6455 §5).
##
##   0                   1                   2                   3
##   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
##  +-+-+-+-+-------+-+-------------+-------------------------------+
##  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
##  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
##  |N|V|V|V|       |S|             |                               |
##  | |1|2|3|       |K|             |                               |
##  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
##  | Masking-key (if MASK set, 4 bytes) | Payload Data ...         |
##
## Client→server frames MUST be masked; server→client MUST NOT be. parseFrame
## reports `masked` so the connection layer can enforce that.

import hashi/http/request

type
  Opcode* = enum ## RFC 6455 §5.2 opcode values.
    opContinuation = 0x0
    opText = 0x1
    opBinary = 0x2
    opClose = 0x8
    opPing = 0x9
    opPong = 0xA

  Frame* = object ## One parsed WebSocket frame.
    fin*: bool       ## final fragment of the message
    opcode*: Opcode
    masked*: bool    ## true for a client→server frame
    payload*: string ## unmasked payload

const MaxWsPayload* = 64 * 1024 * 1024
  ## Largest accepted single-frame payload (DoS guard). Comfortably above the
  ## Autobahn 9.x cases (≤16 MB); a 64-bit length beyond this is rejected
  ## before allocating.

proc isValidOpcode(o: int): bool =
  case o
  of 0x0, 0x1, 0x2, 0x8, 0x9, 0xA: result = true
  else: result = false

proc opcodeOf(o: int): Opcode =
  case o
  of 0x1: result = opText
  of 0x2: result = opBinary
  of 0x8: result = opClose
  of 0x9: result = opPing
  of 0xA: result = opPong
  else: result = opContinuation

proc byteAt(data: string; i: int): int =
  result = uint8(data[i]).int

proc unmask(buf: pointer; n: int; key: array[4, int]) =
  ## XOR `n` bytes at `buf` with the repeating 4-byte mask, a word at a time
  ## where the buffer is 8-aligned (a long string's heap payload is), with
  ## the ends done per byte.
  let p = cast[ptr UncheckedArray[char]](buf)
  var i = 0
  when not defined(bigEndian):
    if n >= 16 and (cast[uint](p) and 7'u) == 0'u:
      let m32 = uint32(key[0]) or (uint32(key[1]) shl 8) or
                (uint32(key[2]) shl 16) or (uint32(key[3]) shl 24)
      let m64 = uint64(m32) or (uint64(m32) shl 32)
      let words = cast[ptr UncheckedArray[uint64]](p)
      let nw = n div 8
      var w = 0
      while w < nw:
        words[w] = words[w] xor m64
        inc w
      i = nw * 8
  while i < n:
    p[i] = char(uint8(p[i]).int xor key[i and 3])
    inc i

proc parseFrame*(data: string; start: int; frame: var Frame;
                 maxPayload = MaxWsPayload): (ParseStatus, int) =
  ## Parse one frame from `data[start ..]`. Returns `(psOk, consumed)` with
  ## `frame` filled and `consumed` total bytes; `(psIncomplete, 0)` if more
  ## bytes are needed; `(psError, 0)` on a protocol violation (reserved bits,
  ## reserved opcode, fragmented/oversized control frame).
  let avail = data.len - start
  if avail < 2:
    return (psIncomplete, 0)
  let b0 = byteAt(data, start)
  let b1 = byteAt(data, start + 1)
  let fin = (b0 and 0x80) != 0
  let rsv = b0 and 0x70
  let opc = b0 and 0x0F
  let masked = (b1 and 0x80) != 0
  let len7 = b1 and 0x7F
  if rsv != 0:
    return (psError, 0)                          # RSV1-3 must be 0 (no ext)
  if not isValidOpcode(opc):
    return (psError, 0)                          # reserved opcode
  let isControl = opc >= 0x8
  if isControl and (not fin):
    return (psError, 0)                          # control frames can't fragment

  var headerLen = 2
  # `payloadLen` is filled below; a 64-bit length field is attacker-controlled,
  # so it is validated against MaxWsPayload before any allocation (no huge or
  # negative `newString`).
  var payloadLen = 0
  if len7 < 126:
    payloadLen = len7
  elif len7 == 126:
    if avail < 4:
      return (psIncomplete, 0)
    payloadLen = (byteAt(data, start+2) shl 8) or byteAt(data, start+3)
    headerLen = 4
  else:                                          # len7 == 127, 64-bit length
    if avail < 10:
      return (psIncomplete, 0)
    var L = 0
    var k = 0
    while k < 8:
      L = (L shl 8) or byteAt(data, start+2+k)
      k = k + 1
    payloadLen = L
    headerLen = 10
  if isControl and payloadLen > 125:
    return (psError, 0)                          # control payload ≤ 125
  if payloadLen < 0 or payloadLen > maxPayload:
    return (psError, 0)                          # overflow / oversized frame (DoS guard)

  var maskKey = default(array[4, int])
  if masked:
    if avail < headerLen + 4:
      return (psIncomplete, 0)
    var k = 0
    while k < 4:
      maskKey[k] = byteAt(data, start + headerLen + k)
      k = k + 1
    headerLen = headerLen + 4

  let total = headerLen + payloadLen
  if avail < total:
    return (psIncomplete, 0)

  frame.fin = fin
  frame.opcode = opcodeOf(opc)
  frame.masked = masked
  frame.payload = ""
  if payloadLen > 0:
    let dst = beginStore(frame.payload, payloadLen)
    copyMem(dst, readRawData(data, start + headerLen), payloadLen)
    if masked: unmask(dst, payloadLen, maskKey)
    endStore(frame.payload)
  result = (psOk, total)

proc frameHeader*(opcode: Opcode; payloadLen: int; fin = true): string =
  ## Just the server→client frame header (≤10 bytes, unmasked). Write this then
  ## the payload directly to avoid materialising a full header+payload copy of a
  ## large message.
  result = newStringOfCap(10)
  var b0 = ord(opcode)
  if fin:
    b0 = b0 or 0x80
  result.add char(b0)
  let n = payloadLen
  if n < 126:
    result.add char(n)
  elif n <= 0xFFFF:
    result.add char(126)
    result.add char((n shr 8) and 0xFF)
    result.add char(n and 0xFF)
  else:
    result.add char(127)
    var k = 7
    while k >= 0:
      result.add char((n shr (k * 8)) and 0xFF)
      k = k - 1

proc serializeFrame*(opcode: Opcode; payload: string; fin = true): string =
  ## Encode a server→client frame (unmasked, per RFC 6455 §5.1). Convenience
  ## for small frames; for large payloads prefer `frameHeader` + a direct write.
  result = frameHeader(opcode, payload.len, fin)
  result.add payload

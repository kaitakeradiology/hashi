## WebSocket frame tests (RFC 6455 §5.7 example frames + edge cases).

import std/syncio
import hashi/http/request   # ParseStatus
import hashi/ws/frame
import testkit

proc bytes(xs: openArray[int]): string =
  result = ""
  var i = 0
  while i < xs.len:
    result.add char(xs[i])
    i = i + 1

proc parse1(s: string): (ParseStatus, Frame, int) =
  var f = default(Frame)
  let (st, n) = parseFrame(s, 0, f)
  result = (st, f, n)

# ── parse: RFC 6455 §5.7 examples ──────────────────────────────────────
section "parse examples"

block:
  # unmasked text "Hello": 0x81 0x05 H e l l o
  let (st, f, n) = parse1(bytes([0x81, 0x05]) & "Hello")
  check st == psOk, "unmasked Hello parses"
  check f.fin, "FIN set"
  check f.opcode == opText, "opcode text"
  check not f.masked, "not masked"
  check f.payload == "Hello", "payload"
  check n == 7, "7 bytes consumed"

block:
  # masked text "Hello": 81 85 37fa213d 7f9f4d5158
  let (st, f, n) = parse1(bytes([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d,
                                 0x7f, 0x9f, 0x4d, 0x51, 0x58]))
  check st == psOk, "masked Hello parses"
  check f.masked, "masked flag"
  check f.payload == "Hello", "payload unmasked correctly"
  check n == 11, "11 bytes consumed"

# ── extended lengths ───────────────────────────────────────────────────
section "lengths"

block:
  # 126-byte payload uses 16-bit length
  var body = ""
  var i = 0
  while i < 126: body.add 'a'; i = i + 1
  let (st, f, n) = parse1(bytes([0x82, 126, 0x00, 0x7E]) & body)
  check st == psOk, "16-bit length parses"
  check f.opcode == opBinary, "binary"
  check f.payload.len == 126, "126-byte payload"
  check n == 4 + 126, "consumed"

block:
  # 65536-byte payload uses 64-bit length
  var body = ""
  var i = 0
  while i < 65536: body.add 'b'; i = i + 1
  let (st, f, n) = parse1(bytes([0x82, 127, 0,0,0,0, 0,1,0,0]) & body)
  check st == psOk, "64-bit length parses"
  check f.payload.len == 65536, "65536-byte payload"
  check n == 10 + 65536, "consumed"

block:
  # Masked payloads long enough for the word-at-a-time unmask, at lengths
  # that exercise the aligned middle and the per-byte tails, against a
  # per-byte reference.
  let key = [0x37, 0xfa, 0x21, 0x3d]
  for n in [15, 16, 17, 23, 24, 25, 100, 1000, 65536]:
    var plain = ""
    for i in 0 ..< n: plain.add char((i * 7 + 3) and 0xff)
    var masked = ""
    for i in 0 ..< n: masked.add char(uint8(plain[i]).int xor key[i and 3])
    var head = ""
    if n < 126:
      head = bytes([0x82, 0x80 or n])
    elif n <= 0xffff:
      head = bytes([0x82, 0x80 or 126, n shr 8, n and 0xff])
    else:
      head = bytes([0x82, 0x80 or 127, 0, 0, 0, 0, (n shr 24) and 0xff, (n shr 16) and 0xff, (n shr 8) and 0xff, n and 0xff])
    let (st, f, c) = parse1(head & bytes(key) & masked)
    check st == psOk and f.payload == plain and c == head.len + 4 + n,
          "masked payload of " & $n & " bytes unmasks correctly"

# ── incomplete ─────────────────────────────────────────────────────────
section "incomplete"

block:
  let (st, _, _) = parse1(bytes([0x81]))
  check st == psIncomplete, "one byte -> incomplete"

block:
  let (st, _, _) = parse1(bytes([0x81, 0x85, 0x37, 0xfa]))  # mask key cut off
  check st == psIncomplete, "missing mask key -> incomplete"

block:
  let (st, _, _) = parse1(bytes([0x81, 0x05]) & "Hel")      # payload short
  check st == psIncomplete, "short payload -> incomplete"

# ── protocol errors ────────────────────────────────────────────────────
section "protocol errors"

block:
  let (st, _, _) = parse1(bytes([0xC1, 0x00]))   # RSV1 set
  check st == psError, "reserved bit set -> error"

block:
  let (st, _, _) = parse1(bytes([0x83, 0x00]))   # opcode 0x3 reserved
  check st == psError, "reserved opcode -> error"

block:
  let (st, _, _) = parse1(bytes([0x09, 0x00]))   # ping with FIN=0
  check st == psError, "fragmented control frame -> error"

block:
  let (st, _, _) = parse1(bytes([0x89, 126, 0x00, 0x7E]))  # ping len 126
  check st == psError, "oversized control frame -> error"

# ── serialize (server→client, unmasked) ───────────────────────────────
section "serialize"

block:
  check serializeFrame(opText, "Hello") == bytes([0x81, 0x05]) & "Hello",
    "text Hello"

block:
  # round-trip a 200-byte payload through 16-bit length
  var body = ""
  var i = 0
  while i < 200: body.add 'z'; i = i + 1
  let wire = serializeFrame(opBinary, body)
  var f = default(Frame)
  let (st, n) = parseFrame(wire, 0, f)
  check st == psOk, "serialized 200-byte frame re-parses"
  check f.payload == body, "round-trip payload"
  check n == wire.len, "consumed whole frame"

block:
  let wire = serializeFrame(opClose, "")
  check wire == bytes([0x88, 0x00]), "empty close frame"

finish()

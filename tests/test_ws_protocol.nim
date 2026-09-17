## WebSocket protocol state-machine tests (RFC 6455 §5.4–5.5, §7.4, §8.1).

import std/syncio
import hashi/ws/frame
import hashi/ws/protocol
import testkit

proc bytes(xs: openArray[int]): string =
  result = ""
  var i = 0
  while i < xs.len:
    result.add char(xs[i])
    i = i + 1

proc mframe(op: Opcode; payload: string; fin = true): Frame =
  Frame(fin: fin, opcode: op, masked: true, payload: payload)

# ── UTF-8 validation ───────────────────────────────────────────────────
section "utf-8"

block:
  check isValidUtf8(""), "empty ok"
  check isValidUtf8("hello"), "ascii ok"
  check isValidUtf8(bytes([0xC3, 0xA9])), "é (2-byte) ok"
  check isValidUtf8(bytes([0xE2, 0x82, 0xAC])), "€ (3-byte) ok"
  check isValidUtf8(bytes([0xF0, 0x9F, 0x98, 0x80])), "😀 (4-byte) ok"
  check not isValidUtf8(bytes([0x80])), "lone continuation invalid"
  check not isValidUtf8(bytes([0xC0, 0x80])), "overlong 2-byte invalid"
  check not isValidUtf8(bytes([0xED, 0xA0, 0x80])), "surrogate invalid"
  check not isValidUtf8(bytes([0xC3])), "truncated 2-byte invalid"
  check not isValidUtf8(bytes([0xF5, 0x80, 0x80, 0x80])), "out-of-range invalid"
  check not isValidUtf8(bytes([0xF0, 0x80, 0x80, 0x80])), "overlong 4-byte invalid"

# ── masking enforcement ────────────────────────────────────────────────
section "masking"

block:
  var st = default(WsState)
  let a = handleFrame(st, Frame(fin: true, opcode: opText, masked: false, payload: "hi"))
  check a.kind == waClose and a.closeCode == 1002, "unmasked client frame -> close 1002"

# ── data + control ─────────────────────────────────────────────────────
section "data + control"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opText, "Hello"))
  check a.kind == waMessage, "single text -> message"
  check a.opcode == opText and a.payload == "Hello", "message contents"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opPing, "pingdata"))
  check a.kind == waPong and a.payload == "pingdata", "ping -> pong echo"

block:
  var st = default(WsState)
  check handleFrame(st, mframe(opPong, "x")).kind == waNone, "pong -> nothing"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opText, bytes([0xC3, 0x28])))  # bad utf-8
  check a.kind == waClose and a.closeCode == 1007, "invalid utf-8 text -> 1007"

# ── fragmentation ──────────────────────────────────────────────────────
section "fragmentation"

block:
  var st = default(WsState)
  let a1 = handleFrame(st, mframe(opText, "Hel", fin = false))
  check a1.kind == waNone, "first fragment buffered"
  let a2 = handleFrame(st, mframe(opContinuation, "lo", fin = true))
  check a2.kind == waMessage and a2.payload == "Hello", "continuation completes message"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opContinuation, "x"))
  check a.kind == waClose and a.closeCode == 1002, "continuation with no message -> 1002"

block:
  var st = default(WsState)
  discard handleFrame(st, mframe(opText, "a", fin = false))
  let a = handleFrame(st, mframe(opText, "b"))   # new data frame mid-message
  check a.kind == waClose and a.closeCode == 1002, "data frame mid-message -> 1002"

block:
  # control frame may interleave between fragments
  var st = default(WsState)
  discard handleFrame(st, mframe(opText, "a", fin = false))
  let p = handleFrame(st, mframe(opPing, "z"))
  check p.kind == waPong, "ping interleaved with fragments -> pong"
  let a = handleFrame(st, mframe(opContinuation, "b", fin = true))
  check a.kind == waMessage and a.payload == "ab", "fragmented message still completes"

block:
  # fragmented text with split multi-byte char must validate the whole message
  var st = default(WsState)
  discard handleFrame(st, mframe(opText, bytes([0xC3]), fin = false))
  let a = handleFrame(st, mframe(opContinuation, bytes([0xA9]), fin = true))
  check a.kind == waMessage, "split é across fragments is valid utf-8"

# ── close handling ─────────────────────────────────────────────────────
section "close"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opClose, ""))
  check a.kind == waClose and a.closeCode == 1000, "empty close -> 1000"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opClose, bytes([0x03, 0xE8])))  # 1000
  check a.kind == waClose and a.closeCode == 1000, "valid close code echoed as 1000"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opClose, bytes([0x03, 0xEC])))  # 1004 reserved
  check a.kind == waClose and a.closeCode == 1002, "invalid close code -> 1002"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opClose, bytes([0x03])))        # 1-byte
  check a.kind == waClose and a.closeCode == 1002, "1-byte close payload -> 1002"

block:
  var st = default(WsState)
  let a = handleFrame(st, mframe(opClose, bytes([0x03, 0xE8, 0xC3, 0x28])))
  check a.kind == waClose and a.closeCode == 1007, "close reason bad utf-8 -> 1007"

finish()

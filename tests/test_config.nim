## Unit tests for per-server config: the defaults, the set/get global, and that
## each size cap is honoured when threaded as a limit param to the pure checks.

import std/syncio
import hashi/http/config
import hashi/http/request
import hashi/ws/frame
import hashi/ws/protocol
import testkit

# ── defaults + global ─────────────────────────────────────────────────────
section "config defaults"

let d = defaultServerConfig()
block: check d.maxRequestHead == MaxRequestHead, "default maxRequestHead = const"
block: check d.maxBodySize == MaxBodySize, "default maxBodySize = const"
block: check d.maxWsPayload == MaxWsPayload, "default maxWsPayload = const"
block: check d.maxWsMessage == MaxWsMessage, "default maxWsMessage = const"
block: check d.tcpNoDelay, "nodelay on by default"

section "setServerConfig"
block:
  var c = defaultServerConfig()
  c.maxBodySize = 123
  setServerConfig(c)
  check gServerConfig.maxBodySize == 123, "setServerConfig updates the global"
  setServerConfig(defaultServerConfig())   # restore for any later use

# ── parseFrame honours maxPayload ─────────────────────────────────────────
section "parseFrame maxPayload"

# A masked binary frame header declaring a 200-byte payload (16-bit length).
proc hdr200(): string =
  result = ""
  result.add char(0x82)            # FIN | binary
  result.add char(0x80 or 126)     # masked, 16-bit length follows
  result.add char(0x00)            # length hi
  result.add char(0xC8)            # length lo = 200
  result.add char(0x01); result.add char(0x02)  # 4-byte mask key
  result.add char(0x03); result.add char(0x04)

block:
  var f = default(Frame)
  let r = parseFrame(hdr200(), 0, f, 100)      # 200 > 100
  check r[0] == psError, "payload over maxPayload -> psError"
block:
  var f = default(Frame)
  let r = parseFrame(hdr200(), 0, f, 300)      # 200 <= 300, body absent
  check r[0] == psIncomplete, "within maxPayload -> needs more (not rejected)"

# ── handleFrame honours maxMessage (assembled fragments) ──────────────────
section "handleFrame maxMessage"

block:
  var st = default(WsState)
  let a1 = handleFrame(st, Frame(fin: false, opcode: opText, masked: true,
                                 payload: "aaa"), 5)
  check a1.kind == waNone, "first fragment buffered"
  let a2 = handleFrame(st, Frame(fin: true, opcode: opContinuation, masked: true,
                                 payload: "bbb"), 5)            # 3+3 > 5
  check a2.kind == waClose and a2.closeCode == 1009, "over maxMessage -> close 1009"
block:
  var st = default(WsState)
  discard handleFrame(st, Frame(fin: false, opcode: opText, masked: true,
                                payload: "aaa"), 100)
  let a2 = handleFrame(st, Frame(fin: true, opcode: opContinuation, masked: true,
                                 payload: "bbb"), 100)
  check a2.kind == waMessage and a2.payload == "aaabbb", "within maxMessage -> message"

# ── decodeChunked honours maxBody ─────────────────────────────────────────
section "decodeChunked maxBody"

block:
  var body = ""
  let r = decodeChunked("5\r\nhello\r\n0\r\n\r\n", 0, body, 3)   # 5 > 3
  check r[0] == psError, "chunk over maxBody -> psError"
block:
  var body = ""
  let r = decodeChunked("5\r\nhello\r\n0\r\n\r\n", 0, body, 64)
  check r[0] == psOk and body == "hello", "within maxBody -> decoded"

finish()

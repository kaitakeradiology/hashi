## Unit tests for per-server config: the defaults, the set/get global, and that
## each size cap is honoured when threaded as a limit param to the pure checks.

import std/syncio
import hashi/http/config
import hashi/http/connreg   # addInflight/subInflight/inflightBytes
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
block: check d.idleTimeoutMs > 0, "the idle reaper is armed out of the box"
block: check d.keepaliveIdleSec > 0 and d.keepaliveIntvlSec > 0 and d.keepaliveCnt > 0,
      "kernel dead-peer detection on by default"
block: check d.maxInflightBytes > 0, "aggregate buffered-byte budget on by default"
block: check d.userTimeoutMs == 60_000, "TCP_USER_TIMEOUT 60 s by default"
block: check d.wsPingIntervalMs == 20_000, "WebSocket pings every 20 s of inbound silence"
block: check d.wsIdleTimeoutMs == 60_000, "WebSocket idle close after 60 s of inbound silence"
block: check d.wsKeepalivePollMs == MaxKeepalivePollMs, "keepalive waits capped at MaxKeepalivePollMs"
block: check MaxKeepalivePollMs == 20_000, "MaxKeepalivePollMs is 20 s"
block: check d.lingerMs == 5000, "a rejected connection lingers up to 5 s by default"
block: check d.lingerIdleMs == 1000, "and stops after 1 s of silence"

section "validateServerConfig"
block: check validateServerConfig(d) == "", "the defaults are valid"
block:
  var c = defaultServerConfig()
  c.wsPingIntervalMs = 0
  c.wsIdleTimeoutMs = 0
  check validateServerConfig(c) == "", "keepalive off (0/0) is valid"
block:
  var c = defaultServerConfig()
  c.maxRequestHead = 0
  check validateServerConfig(c) == "maxRequestHead must be positive (got 0)",
        "a zero head cap is refused"
block:
  var c = defaultServerConfig()
  c.maxRequestHead = -1
  check validateServerConfig(c) == "maxRequestHead must be positive (got -1)",
        "a negative head cap is refused"
block:
  var c = defaultServerConfig()
  c.maxRequestHead = 1
  check validateServerConfig(c) == "", "a head cap of one byte is valid"
block:
  var c = defaultServerConfig()
  c.wsPingIntervalMs = -1
  check validateServerConfig(c) == "wsPingIntervalMs must not be negative (got -1)",
        "a negative ping interval is refused"
block:
  var c = defaultServerConfig()
  c.wsIdleTimeoutMs = -5
  check validateServerConfig(c) == "wsIdleTimeoutMs must not be negative (got -5)",
        "a negative idle timeout is refused"
block:
  var c = defaultServerConfig()
  c.maxInflightBytes = -1
  check validateServerConfig(c) == "maxInflightBytes must not be negative (got -1)",
        "a negative in-flight budget is refused"
block:
  var c = defaultServerConfig()
  c.maxInflightBytes = 0
  check validateServerConfig(c) == "", "an in-flight budget of 0 (no budget) is valid"
block:
  var c = defaultServerConfig()
  c.wsPingIntervalMs = 100
  c.wsIdleTimeoutMs = 150
  check validateServerConfig(c) ==
        "wsIdleTimeoutMs (150) must be at least twice wsPingIntervalMs (100)",
        "an idle timeout under two ping intervals is refused"
block:
  var c = defaultServerConfig()
  c.wsPingIntervalMs = 100
  c.wsIdleTimeoutMs = 200
  check validateServerConfig(c) == "", "exactly two ping intervals is valid"
block:
  var c = defaultServerConfig()
  c.wsPingIntervalMs = 0
  c.wsIdleTimeoutMs = 50
  check validateServerConfig(c) == "", "an idle close without pings is valid"
block:
  var c = defaultServerConfig()
  c.lingerMs = -1
  check validateServerConfig(c) == "lingerMs must be between 0 and 60000 (got -1)",
        "a negative linger is refused"
block:
  var c = defaultServerConfig()
  c.lingerMs = 60_001
  check validateServerConfig(c) == "lingerMs must be between 0 and 60000 (got 60001)",
        "a linger over a minute is refused"
block:
  var c = defaultServerConfig()
  c.lingerMs = 60_000
  c.lingerIdleMs = 60_000
  check validateServerConfig(c) == "", "a linger of exactly a minute is valid"
block:
  var c = defaultServerConfig()
  c.lingerMs = 1000
  c.lingerIdleMs = 0
  check validateServerConfig(c) == "lingerIdleMs must be positive while lingerMs is set (got 0)",
        "a zero linger idle bound is refused while lingering is on"
block:
  var c = defaultServerConfig()
  c.lingerMs = 1000
  c.lingerIdleMs = -3
  check validateServerConfig(c) == "lingerIdleMs must be positive while lingerMs is set (got -3)",
        "a negative linger idle bound is refused while lingering is on"
block:
  var c = defaultServerConfig()
  c.lingerMs = 1000
  c.lingerIdleMs = 1001
  check validateServerConfig(c) == "lingerIdleMs (1001) must not exceed lingerMs (1000)",
        "a linger idle bound over lingerMs is refused"
block:
  var c = defaultServerConfig()
  c.lingerMs = 1000
  c.lingerIdleMs = 1000
  check validateServerConfig(c) == "", "a linger idle bound equal to lingerMs is valid"
block:
  var c = defaultServerConfig()
  c.lingerMs = 0
  c.lingerIdleMs = 0
  check validateServerConfig(c) == "", "linger off (0) leaves lingerIdleMs unchecked"

section "inflight accounting"
# The accept gate reads one number: bytes buffered across connections and not
# yet consumed by a parser. Reads add, consumption and teardown subtract.
block:
  let base = inflightBytes()
  addInflight(100)
  check inflightBytes() == base + 100, "buffered bytes are counted"
  subInflight(40)
  check inflightBytes() == base + 60, "consumed bytes stop being counted"
  subInflight(60)
  check inflightBytes() == base, "the counter returns to its baseline"

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

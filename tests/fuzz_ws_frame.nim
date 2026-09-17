## Fuzzer for the WebSocket frame layer (RFC 6455 §5) + the protocol state
## machine. Why it matters: Nimony Defects (index/overflow) are uncatchable, so
## an input-triggered Defect in parseFrame/handleFrame would abort the process —
## this hunts them. Arms:
##   1. parseFrame invariants on random/shaped bytes (no crash, consumed in
##      bounds, payload ≤ cap, control frames ≤ 125 & FIN);
##   2. masked round-trip — a frame we build must parse back to the same
##      opcode/fin/payload (and unmask correctly);
##   3. handleFrame + isValidUtf8 on arbitrary input never crash.
##
##   ../nimony/bin/nimony c -r tests/fuzz_ws_frame.nim
import std/syncio
import hashi/http/request   # ParseStatus
import hashi/ws/frame
import hashi/ws/protocol
import testkit
import fuzzkit

seedFuzz(0x9E3779B97F4A7C15'i64)
const iterations = 3000

proc isControl(op: Opcode): bool = ord(op) >= 0x8

# Build a well-formed *masked* client frame (the wire shape parseFrame expects).
proc maskedFrame(op: Opcode; payload: string; fin: bool): string =
  result = ""
  var b0 = ord(op)
  if fin: b0 = b0 or 0x80
  result.add char(b0)
  let n = payload.len
  if n < 126:
    result.add char(0x80 or n)
  elif n <= 0xFFFF:
    result.add char(0x80 or 126)
    result.add char((n shr 8) and 0xFF)
    result.add char(n and 0xFF)
  else:
    result.add char(0x80 or 127)
    var k = 7
    while k >= 0:
      result.add char((n shr (k * 8)) and 0xFF)
      k = k - 1
  var mask = default(array[4, int])
  var i = 0
  while i < 4:
    mask[i] = rnd(256)
    result.add char(mask[i])
    i = i + 1
  i = 0
  while i < n:
    result.add char((int(uint8(payload[i])) xor mask[i and 3]) and 0xFF)
    i = i + 1

const opcodes = [opContinuation, opText, opBinary, opClose, opPing, opPong]

# ── arm 1: parseFrame invariants on arbitrary bytes ────────────────────────
section "parseFrame invariants (random bytes)"
block:
  var bad = 0
  var okc = 0
  var it = 0
  while it < iterations:
    var data = ""
    if rnd(2) == 0:
      data = randomBytes(40)
    else:
      # shaped: a plausible header + random tail, to reach length/mask paths
      data.add char(rnd(256))
      data.add char(rnd(256))
      data.add randomBytes(30)
    let cap = if rnd(4) == 0: 1 + rnd(64) else: MaxWsPayload
    var f = default(Frame)
    let r = parseFrame(data, 0, f, cap)
    if r[0] == psOk:
      okc = okc + 1
      if not (r[1] > 0 and r[1] <= data.len): bad = bad + 1
      if f.payload.len > cap: bad = bad + 1
      if isControl(f.opcode) and (f.payload.len > 125 or not f.fin): bad = bad + 1
    else:
      if r[1] != 0: bad = bad + 1               # incomplete/error ⇒ consumed 0
    it = it + 1
  check bad == 0, "no parseFrame invariant violations over " & $iterations & " inputs"
  echo "  (psOk=", $okc, " of ", $iterations, ")"

# ── arm 2: masked round-trip ───────────────────────────────────────────────
section "parseFrame round-trip (masked frames)"
block:
  var bad = 0
  var it = 0
  while it < iterations:
    let op = opcodes[rnd(opcodes.len)]
    var payLen =
      if isControl(op): rnd(126)                # control ≤ 125
      else: rnd(400)                            # spans 7-bit and 16-bit lengths
    let fin = if isControl(op): true else: rnd(2) == 0
    var payload = ""
    var i = 0
    while i < payLen:
      payload.add char(rnd(256))
      i = i + 1
    let wire = maskedFrame(op, payload, fin)
    var f = default(Frame)
    let r = parseFrame(wire, 0, f)
    if r[0] != psOk: bad = bad + 1
    elif r[1] != wire.len: bad = bad + 1
    elif f.opcode != op: bad = bad + 1
    elif f.fin != fin: bad = bad + 1
    elif not f.masked: bad = bad + 1
    elif f.payload != payload: bad = bad + 1    # correct unmasking
    it = it + 1
  check bad == 0, "all " & $iterations & " masked frames round-trip exactly"

# ── arm 3: handleFrame + isValidUtf8 never crash on arbitrary input ─────────
section "handleFrame / isValidUtf8 (no crash)"
block:
  var it = 0
  var actions = 0
  while it < iterations:
    discard isValidUtf8(randomBytes(48))        # must not abort/over-read
    var st = default(WsState)
    # feed a short random sequence of frames through the state machine
    var steps = 1 + rnd(4)
    var s = 0
    while s < steps:
      let op = opcodes[rnd(opcodes.len)]
      let fin = if isControl(op): true else: rnd(2) == 0
      let f = Frame(fin: fin, opcode: op, masked: true, payload: randomBytes(40))
      let act = handleFrame(st, f)
      actions = actions + ord(act.kind)         # touch the result
      s = s + 1
    it = it + 1
  check actions >= 0, "handleFrame/isValidUtf8 survived " & $iterations & " random sequences"

finish()

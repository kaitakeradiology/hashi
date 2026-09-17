## Fuzzer for decodeChunked (RFC 9112 §7.1) — the chunked request-body decoder.
## A Defect here (over-read on a bad chunk-size, overflow on a long HEXDIG run)
## would abort the process (uncatchable), so this hunts them. Arms:
##   1. invariants on random/shaped bytes (no crash, consumed in bounds,
##      body ≤ cap);
##   2. round-trip — a body we chunk-encode must decode back byte-for-byte.
##
##   ../nimony/bin/nimony c -r tests/fuzz_chunked.nim
import std/syncio
import hashi/http/request   # decodeChunked, ParseStatus, MaxBodySize
import testkit
import fuzzkit

seedFuzz(0xD1B54A32D192ED03'i64)
const iterations = 3000
const hexDigits = "0123456789abcdef"

proc toHexLower(n: int): string =
  ## Lowercase hex chunk-size (no "0x"); n >= 0.
  if n == 0: return "0"
  result = ""
  var v = n
  var digs = ""
  while v > 0:
    digs.add hexDigits[v and 0xF]
    v = v shr 4
  # reverse
  var i = digs.len - 1
  while i >= 0:
    result.add digs[i]
    i = i - 1

proc encodeChunked(chunks: seq[string]): string =
  ## chunk = size CRLF data CRLF; terminated by a 0-size last-chunk + CRLF.
  result = ""
  var i = 0
  while i < chunks.len:
    result.add toHexLower(chunks[i].len) & "\r\n" & chunks[i] & "\r\n"
    i = i + 1
  result.add "0\r\n\r\n"

# ── arm 1: invariants on arbitrary bytes ───────────────────────────────────
section "decodeChunked invariants (random bytes)"
block:
  var bad = 0
  var okc = 0
  var it = 0
  while it < iterations:
    var data = ""
    if rnd(2) == 0:
      data = randomBytes(60)
    else:
      # shaped: hex-ish size, CRLF, random data — reaches the size/CRLF paths
      var k = 1 + rnd(6)
      var j = 0
      while j < k:
        data.add hexDigits[rnd(16)]
        j = j + 1
      if rnd(2) == 0: data.add "\r\n"
      data.add randomBytes(40)
      if rnd(2) == 0: data.add "\r\n0\r\n\r\n"
    let cap = if rnd(4) == 0: 1 + rnd(32) else: MaxBodySize
    var body = ""
    let r = decodeChunked(data, 0, body, cap)
    if r[0] == psOk:
      okc = okc + 1
      if not (r[1] > 0 and r[1] <= data.len): bad = bad + 1
      if body.len > cap: bad = bad + 1
    else:
      if r[1] != 0: bad = bad + 1
      if body.len > cap: bad = bad + 1
    it = it + 1
  check bad == 0, "no decodeChunked invariant violations over " & $iterations & " inputs"
  echo "  (psOk=", $okc, " of ", $iterations, ")"

# ── arm 2: round-trip ──────────────────────────────────────────────────────
section "decodeChunked round-trip"
block:
  var bad = 0
  var it = 0
  while it < iterations:
    let nc = 1 + rnd(8)
    var chunks = default(seq[string])
    var expected = ""
    var j = 0
    while j < nc:
      let c = randomBytesExact(1 + rnd(50))   # non-empty (a 0-size chunk is the terminator)
      chunks.add c
      expected.add c
      j = j + 1
    let data = encodeChunked(chunks)
    var body = ""
    let r = decodeChunked(data, 0, body, MaxBodySize)
    if r[0] != psOk: bad = bad + 1
    elif r[1] != data.len: bad = bad + 1
    elif body != expected: bad = bad + 1
    it = it + 1
  check bad == 0, "all " & $iterations & " chunked bodies round-trip exactly"

finish()

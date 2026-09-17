## Fuzzer for parseRequestHead (RFC 9112 §3/§5). Two arms:
##   1. invariants on random/malformed bytes — must never crash, over-read, or
##      return an inconsistent result;
##   2. round-trip on well-formed requests — must parse back to the exact
##      method/target/version/headers.
##
## The generators are `tests/fuzzkit`, seeded so a failure reproduces.
##
##   ../nimony/bin/nimony c -r tests/fuzz_request.nim

import std/syncio
import hashi/http/request
import testkit
import fuzzkit

seedFuzz(0x2545F4914F6CDD1D'i64)

# ── helpers to check parser invariants ─────────────────────────────────
const iterations = 4000


proc endsWithCRLFCRLF(s: string; n: int): bool =
  ## Does s[0..<n] end with CRLFCRLF (n is headBytes)?
  if n < 4 or n > s.len: return false
  result = s[n-4] == '\r' and s[n-3] == '\n' and s[n-2] == '\r' and s[n-1] == '\n'

# ── arm 1: invariants on arbitrary bytes ───────────────────────────────
section "invariants (random bytes)"

block:
  var okCount = 0
  var incCount = 0
  var errCount = 0
  var bad = 0
  var it = 0
  while it < iterations:
    # Mix: pure random bytes, and "shaped" near-requests, to reach more paths.
    var data = ""
    if rnd(2) == 0:
      data = randomBytes(220)
    else:
      data = randomToken(8) & " " & randomToken(12) & " HTTP/1." & $rnd(3)
      if rnd(2) == 0: data.add "\r\n"
      if rnd(2) == 0: data.add randomBytes(40)
      if rnd(2) == 0: data.add "\r\n\r\n"
    var req = default(Request)
    let st = parseRequestHead(data, req)
    if st == psOk:
      okCount = okCount + 1
      if not (req.headBytes > 0 and req.headBytes <= data.len): bad = bad + 1
      if not endsWithCRLFCRLF(data, req.headBytes): bad = bad + 1
      if req.httpMethod.len == 0 or req.target.len == 0: bad = bad + 1
      if req.version == HttpUnknown: bad = bad + 1
    elif st == psIncomplete:
      incCount = incCount + 1
      if hasCRLFCRLF(data): bad = bad + 1   # incomplete ⇒ no terminator yet
    else:
      errCount = errCount + 1
    it = it + 1
  check bad == 0, "no invariant violations over " & $iterations & " random inputs"
  echo "  (ok=", $okCount, " incomplete=", $incCount, " error=", $errCount, ")"

# ── arm 2: round-trip on well-formed requests ──────────────────────────
section "round-trip (well-formed)"

block:
  const CRLF = "\r\n"
  var bad = 0
  var it = 0
  while it < iterations:
    let meth = randomTchar(8)
    let target = "/" & randomToken(20)
    let ver = if rnd(2) == 0: "HTTP/1.0" else: "HTTP/1.1"
    var names = default(seq[string])
    var values = default(seq[string])
    # HTTP/1.1 requires exactly one Host (RFC 9112 §3.2); include it so the
    # generated request is well-formed. (A random 12-char field-name can't
    # collide with "Host", so this stays the only Host header.)
    if ver == "HTTP/1.1":
      names.add "Host"
      values.add "h." & randomToken(6)
    let nh = rnd(8)
    var j = 0
    while j < nh:
      names.add randomTchar(12)        # field-name must be a valid token
      values.add randomToken(20)
      j = j + 1
    var data = meth & " " & target & " " & ver & CRLF
    var hi = 0
    while hi < names.len:
      data.add names[hi] & ": " & values[hi] & CRLF
      hi = hi + 1
    data.add CRLF
    var req = default(Request)
    let st = parseRequestHead(data, req)
    if st != psOk: bad = bad + 1
    elif req.httpMethod != meth: bad = bad + 1
    elif req.target != target: bad = bad + 1
    elif req.headers.len != names.len: bad = bad + 1
    else:
      var k = 0
      while k < names.len:
        if req.headers[k].name != names[k] or req.headers[k].value != values[k]:
          bad = bad + 1
        k = k + 1
    it = it + 1
  check bad == 0, "all " & $iterations & " well-formed requests round-trip exactly"

finish()

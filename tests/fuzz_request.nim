## Fuzzer for parseRequestHead (RFC 9112 §3/§5). Arms:
##   1. invariants on random/malformed bytes — must never crash, over-read, or
##      return an inconsistent result;
##   2. round-trip on well-formed requests — must parse back to the exact
##      method/version/headers, with the target as `refCanonical` gives it, or
##      be rejected exactly when `refCanonical` rejects the target;
##   3. `canonicalTarget` over targets drawn from `/ . % 2 e E f F 5 c 0 ? # a A`:
##      agreement with `refCanonical`, idempotence, and the segment invariant
##      the router and `path()` rely on.
##
## The generators are `tests/fuzzkit`, seeded so a failure reproduces.
##
##   ../nimony/bin/nimony c -r tests/fuzz_request.nim

import std/[syncio, strutils, uri]
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

# ── reference canonicaliser: deliberately naive split / decode / join ──
proc refHex(c: char): int =
  if c >= '0' and c <= '9': result = ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': result = ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F': result = ord(c) - ord('A') + 10
  else: result = -1

proc refUnreserved(c: char): bool =
  result = c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}

proc refCanonical(t: string; ok: var bool): string =
  ## The canonical form of request-target `t` (see `canonicalTarget`), with
  ## `ok` false when `t` is rejected. Written independently of it.
  ok = false
  result = ""
  if t.len == 0 or t[0] != '/': return
  let q = find(t, '?')
  let p = if q < 0: t else: substr(t, 0, q - 1)
  let qs = if q < 0: "" else: substr(t, q)
  for c in qs:
    if c == '#' or c < '!' or c == '\x7F': return
  for c in p:
    if c == '#' or c == '\\' or c < '!' or c > '~': return
  if p == "/":
    ok = true
    return p & qs
  var parts = split(substr(p, 1), '/')
  if parts.len > 1 and parts[parts.len - 1] == "":
    parts.setLen(parts.len - 1)                 # one trailing slash
  var outSegs: seq[string] = @[]
  for seg in parts:
    if seg.len == 0: return                     # empty segment
    var o = ""
    var i = 0
    while i < seg.len:
      if seg[i] == '%':
        if i + 2 >= seg.len: return
        let hi = refHex(seg[i + 1])
        let lo = refHex(seg[i + 2])
        if hi < 0 or lo < 0: return
        let b = char(hi * 16 + lo)
        if b == '/' or b == '\\' or b < ' ' or b == '\x7F': return
        if refUnreserved(b):
          o.add b
        else:
          o.add '%'
          o.add toUpperAscii(seg[i + 1])
          o.add toUpperAscii(seg[i + 2])
        i = i + 3
      else:
        o.add seg[i]
        i = i + 1
    if o == "." or o == "..": return            # dot segment
    outSegs.add o
  ok = true
  result = "/" & join(outSegs, "/") & qs

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
      data = randomToken(8) & " " & (if rnd(2) == 0: "/" else: "") &
             randomToken(12) & " HTTP/1." & $rnd(3)
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
  var rejected = 0
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
    var refOk = false
    let want = refCanonical(target, refOk)
    if not refOk:
      rejected = rejected + 1
      if st != psError: bad = bad + 1
    elif st != psOk: bad = bad + 1
    elif req.httpMethod != meth: bad = bad + 1
    elif req.target != want: bad = bad + 1
    elif req.headers.len != names.len: bad = bad + 1
    else:
      var k = 0
      while k < names.len:
        if req.headers[k].name != names[k] or req.headers[k].value != values[k]:
          bad = bad + 1
        k = k + 1
    it = it + 1
  check bad == 0, "all " & $iterations & " well-formed requests round-trip, or are rejected, as refCanonical says"
  echo "  (rejected=", $rejected, " of ", $iterations, ")"

# ── arm 3: canonicalTarget on structured targets ───────────────────────
section "canonicalTarget (structured alphabet)"

block:
  const alphabet = "/.%2eEfF5c0?#aA"
  var bad = 0
  var accepted = 0
  var rewritten = 0
  var shown = 0
  var it = 0
  while it < 20000:
    var target = if rnd(8) == 0: "" else: "/"
    let n = rnd(14)
    var k = 0
    while k < n:
      target.add alphabet[rnd(alphabet.len)]
      k = k + 1
    var refOk = false
    let want = refCanonical(target, refOk)
    var got = target
    let ok = canonicalTarget(got)
    if ok != refOk or (ok and got != want):
      bad = bad + 1
      shown = shown + 1
      if shown <= 20: echo "  '", target, "': canonicalTarget ", ok, " '", got, "', reference ", refOk, " '", want, "'"
    if ok:
      accepted = accepted + 1
      if got != target: rewritten = rewritten + 1
      var again = got
      if not canonicalTarget(again) or again != got:
        bad = bad + 1
        shown = shown + 1
        if shown <= 20: echo "  not idempotent: '", got, "' -> '", again, "'"
      let q = find(got, '?')
      let raw = if q < 0: got else: substr(got, 0, q - 1)
      var joined = ""
      if raw != "/":
        if raw.len < 2 or raw[0] != '/': bad = bad + 1
        for seg in split(substr(raw, 1), '/'):
          var d = ""
          if seg.len == 0 or not decodeUrl(toOpenArray(seg, 0, seg.len - 1), d):
            bad = bad + 1                       # empty or undecodable segment
          elif d == "." or d == ".." or find(d, {'/', '\0', '\\'}) >= 0:
            bad = bad + 1                       # dot segment, or a hidden separator
          joined.add '/'
          joined.add d
      else:
        joined = "/"
      var req = default(Request)
      req.target = got
      if path(req) != joined:
        bad = bad + 1
        shown = shown + 1
        if shown <= 20: echo "  path() of '", got, "' is '", path(req), "', segments give '", joined, "'"
    it = it + 1
  check bad == 0, "canonicalTarget agrees with refCanonical and keeps the segment invariant over 20000 targets"
  echo "  (accepted=", $accepted, " rewritten=", $rewritten, ")"

finish()

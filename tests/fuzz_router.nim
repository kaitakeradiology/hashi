## Fuzzer for the router's pattern matching. Arms:
##   1. random patterns and targets never crash `matchRoute`, and a match
##      reports a route index in range with one captured param per `:name`;
##   2. a target assembled from a pattern's own segments (random values for
##      the `:name` and `*` slots) matches that pattern, and the captures are
##      the values used;
##   3. `/**` matches every target.
##
##   ../nimony/bin/nimony c -r tests/fuzz_router.nim

import std/syncio
import hashi/http/request
import hashi/http/router
import testkit
import fuzzkit

seedFuzz(0xBB67AE8584CAA73B'i64)
const iterations = 3000

proc noop(req: Request): Response {.nimcall, raises.} = newResponse(200)

proc randomSegment(): string =
  case rnd(4)
  of 0: ":" & randomAlnum(6)
  of 1: "*"
  of 2: "**"
  else: randomAlnum(8)

proc randomPattern(): string =
  result = ""
  for i in 0 ..< rnd(5):
    result.add "/" & randomSegment()
  if result.len == 0: result = "/"

section "matchRoute invariants on random patterns and targets"
block:
  var bad = 0
  var found = 0
  for it in 0 ..< iterations:
    var r = default(Router)
    for k in 0 ..< 1 + rnd(4):
      addRoute(r, (if rnd(3) == 0: "POST" else: "GET"), randomPattern(), noop)
    let target = if rnd(3) == 0: randomBytes(40) else: "/" & randomAlnum(6) & "/" & randomAlnum(6) & "?" & randomBytes(10)
    let m = matchRoute(r, "GET", target)
    if m.found:
      inc found
      if m.idx < 0 or m.idx >= r.routes.len: inc bad
      # One capture per `:name` before the catch-all, which ends matching.
      var named = 0
      for seg in r.routes[m.idx].segs:
        if seg == "**": break
        if seg.len > 0 and seg[0] == ':': inc named
      if m.params.len != named: inc bad
    elif m.idx != -1 or m.params.len != 0:
      inc bad
  check bad == 0, "no matchRoute invariant violations over " & $iterations & " routers"
  echo "  (found=", $found, " of ", $iterations, ")"

section "a target built from a pattern matches it with the right captures"
block:
  var bad = 0
  for it in 0 ..< iterations:
    var pattern = ""
    var target = ""
    var wantKeys: seq[string] = @[]
    var wantVals: seq[string] = @[]
    var sawCatchAll = false
    for i in 0 ..< 1 + rnd(5):
      if sawCatchAll: break
      let seg = randomSegment()
      pattern.add "/" & seg
      if seg == "**":
        sawCatchAll = true
        for k in 0 ..< rnd(3): target.add "/" & randomAlnum(5)
      elif seg == "*":
        target.add "/" & randomAlnum(5)
      elif seg[0] == ':':
        let v = randomAlnum(7)
        wantKeys.add substr(seg, 1)
        wantVals.add v
        target.add "/" & v
      else:
        target.add "/" & seg
    if target.len == 0: target = "/"
    var r = default(Router)
    addRoute(r, "GET", pattern, noop)
    let m = matchRoute(r, "GET", target & (if rnd(2) == 0: "?" & randomBytes(8) else: ""))
    if not m.found or m.idx != 0:
      inc bad
    elif m.params.len != wantKeys.len:
      inc bad
    else:
      for k in 0 ..< wantKeys.len:
        if m.params[k].key != wantKeys[k] or m.params[k].val != wantVals[k]: inc bad
  check bad == 0, "all " & $iterations & " pattern-derived targets match with their captures"

section "the catch-all matches everything"
block:
  var bad = 0
  var r = default(Router)
  addRoute(r, "GET", "/**", noop)
  for it in 0 ..< iterations:
    if not matchRoute(r, "GET", randomBytes(30)).found: inc bad
  check bad == 0, "/** matched " & $iterations & " random targets"

finish()

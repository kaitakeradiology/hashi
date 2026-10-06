## Fuzzer for the IP-literal parser and forwarded-header attribution. Arms:
##   1. random bytes and address-shaped strings never crash `parseIpLiteral`;
##      what it accepts is canonical (a fixed point), at most 45 bytes of
##      `[0-9a-f:.]`;
##   2. random `X-Real-IP` lines and `X-Forwarded-For` from a trusted peer
##      give "" or a canonical literal, never the peer unless a forwarded
##      header names it, and `forwardedWarning` never crashes.
##
##   ../nimony/bin/nimony c -r tests/fuzz_forwarded.nim

import std/[syncio, strutils]
import hashi/net
import hashi/http/forwarded
import testkit
import fuzzkit

seedFuzz(0x3C6EF372FE94F82B'i64)
const iterations = 20000

const hexd = "0123456789abcdefABCDEF"

proc group(): string =
  result = ""
  for i in 0 ..< rnd(6): result.add hexd[rnd(hexd.len)]

proc quad(): string =
  result = $rnd(300) & "." & $rnd(300) & "." & $rnd(300) & "." & $rnd(300)

proc addressLike(): string =
  ## Mostly near-miss literals, sometimes valid, sometimes noise.
  case rnd(6)
  of 0: result = quad()
  of 1: result = randomBytes(50)
  of 2: result = quad() & (if rnd(2) == 0: ":" & $rnd(70000) else: "/" & $rnd(40))
  else:
    result = ""
    for i in 0 ..< 1 + rnd(9):
      if i > 0: result.add ':'
      if rnd(6) == 0: result.add ':'
      result.add group()
    if rnd(3) == 0: result.add ":" & quad()
  if rnd(8) == 0: result = " " & result & "\t"

proc canonicalShape(c: string): bool =
  result = c.len <= 45
  for ch in c:
    if not (ch in {'0'..'9', 'a'..'f', ':', '.'}): result = false

section "parseIpLiteral"
block:
  var accepted = 0
  var bad = 0
  for it in 0 ..< iterations:
    let s = addressLike()
    let c = parseIpLiteral(s)
    if c.len > 0:
      inc accepted
      if not canonicalShape(c) or parseIpLiteral(c) != c: inc bad
  check bad == 0, $accepted & " of " & $iterations & " accepted, every one canonical"

section "attribution from a trusted peer"
setTrustedProxies(@["127.0.0.1", "10.0.0.2"])
block:
  var bad = 0
  var warned = 0
  for it in 0 ..< iterations:
    var xri: seq[string] = @[]
    for k in 0 ..< rnd(3): xri.add addressLike()
    var xff = ""
    for k in 0 ..< rnd(5):
      if k > 0: xff.add(if rnd(2) == 0: ", " else: ",")
      case rnd(4)
      of 0: xff.add "10.0.0.2"
      of 1: xff.add "127.0.0.1"
      else: xff.add addressLike()
    let r = attributedClientIp("127.0.0.1", xri, xff)
    if r.len > 0 and parseIpLiteral(r) != r: inc bad
    if r == "127.0.0.1":
      let named = xri.len == 1 and parseIpLiteral(xri[0]) == "127.0.0.1"
      let none = (xri.len == 0 or (xri.len == 1 and strip(xri[0]).len == 0)) and
                 strip(xff).len == 0
      if not named and not none: inc bad
    if forwardedWarning("127.0.0.1", xri, xff).len > 0: inc warned
  check bad == 0, "every result is \"\" or canonical, and the peer only when named (" &
                  $warned & " warned)"

finish()

## Fuzzer for the request accessors that sit on `std/uri` (path and query
## decoding), the WebSocket origin check, and the upgrade detection. Arms:
##   1. random targets and headers never crash the accessors;
##   2. a query built with `std/uri.encodeQuery` from random pairs reads back
##      through `queryParams` pair for pair;
##   3. an origin built from a random host reads as same-origin, and random
##      bytes never crash `originMatchesHost` or `isWebSocketUpgrade`.
##
##   ../nimony/bin/nimony c -r tests/fuzz_uri.nim

import std/syncio
import std/uri
import hashi/http/request
import hashi/ws/session
import hashi/ws/handshake
import testkit
import fuzzkit

seedFuzz(0x6A09E667F3BCC908'i64)
const iterations = 3000

proc reqWith(target: string): Request =
  result = default(Request)
  result.httpMethod = "GET"
  result.target = target

section "accessors on random targets (no crash)"
block:
  var touched = 0
  for it in 0 ..< iterations:
    var target = ""
    case rnd(3)
    of 0: target = randomBytes(60)
    of 1: target = "/" & randomToken(30) & "?" & randomBytes(40)
    else: target = "/%" & randomBytes(6) & "?a=%" & randomBytes(4) & "&+%2"
    let r = reqWith(target)
    touched = touched + r.path.len + r.query.len + r.queryParams.len +
              r.queryParam("a").len
  check touched >= 0, "path/query/queryParams/queryParam survived " & $iterations & " targets"

section "query round-trip through std/uri"
block:
  var bad = 0
  for it in 0 ..< iterations:
    var pairs: seq[(string, string)] = @[]
    for k in 0 ..< rnd(6):
      pairs.add (randomAlnum(8), randomBytes(16))
    let r = reqWith("/p?" & encodeQuery(pairs))
    let got = r.queryParams
    if got.len != pairs.len:
      inc bad
    else:
      for k in 0 ..< pairs.len:
        if got[k].key != pairs[k][0] or got[k].val != pairs[k][1]: inc bad
  check bad == 0, "all " & $iterations & " encoded queries read back exactly"

section "origin check"
block:
  var bad = 0
  for it in 0 ..< iterations:
    let host = randomAlnum(12) & (if rnd(2) == 0: ":" & $(1 + rnd(65535)) else: "")
    let scheme = if rnd(2) == 0: "http" else: "https"
    if not originMatchesHost(scheme & "://" & host & (if rnd(2) == 0: "/" & randomToken(8) else: ""), host):
      inc bad
    if originMatchesHost(scheme & "://" & host & "x", host):
      inc bad
    discard originMatchesHost(randomBytes(40), randomBytes(20))
    discard originAllowed(randomBytes(20))
  check bad == 0, "same-origin recognised and a longer host refused, " & $iterations & " times"

section "upgrade detection: a valid handshake, then random damage"
block:
  var bad = 0
  var upgrades = 0
  for it in 0 ..< iterations:
    var r = reqWith("/ws")
    r.headers.add Header(name: "Host", value: "h")
    r.headers.add Header(name: "Upgrade", value: (if rnd(2) == 0: "websocket" else: "WebSocket"))
    r.headers.add Header(name: "Connection", value: (if rnd(2) == 0: "Upgrade" else: "keep-alive, upgrade"))
    r.headers.add Header(name: "Sec-WebSocket-Version", value: "13")
    r.headers.add Header(name: "Sec-WebSocket-Key", value: randomAlnum(24))
    if not isWebSocketUpgrade(r):
      inc bad
    # One random change must never crash, and a change to a required part
    # must be refused.
    var damaged = r
    case rnd(6)
    of 0: damaged.httpMethod = "POST"
    of 1: damaged.headers[1].value = randomBytes(12)
    of 2: damaged.headers[2].value = randomBytes(12)
    of 3: damaged.headers[3].value = "12"
    of 4: damaged.headers[4].value = ""
    else: damaged.headers.add Header(name: randomTchar(8), value: randomBytes(20))
    let stillOk = isWebSocketUpgrade(damaged)
    if stillOk: inc upgrades
    if stillOk and damaged.httpMethod == "POST": inc bad
    if stillOk and damaged.headers[3].value == "12": inc bad
    if stillOk and damaged.headers[4].value.len == 0: inc bad
  check bad == 0, "every valid handshake accepted and every required-part change refused, " & $iterations & " times (" & $upgrades & " survived harmless damage)"

finish()

## Unit tests for the HTTP/1.1 request-head parser (RFC 9112 §3, §5).
##
## Contract under test (parseRequestHead):
##   - psIncomplete until the terminating CRLFCRLF is present;
##   - then parse the request line + field block, returning psOk with the
##     filled Request (incl. headBytes), or psError if malformed/rejected.
##
## These are written against the stub (which always returns psError), so
## the psOk cases fail until the parser is implemented — that's the point
## (TDD: red before green).

import std/[syncio, strutils]
import hashi/http/request
import testkit

const CRLF = "\r\n"

proc parse(data: string): (ParseStatus, Request) =
  var r = default(Request)
  let st = parseRequestHead(data, r)
  result = (st, r)

proc nameAt(r: Request; i: int): string =
  ## Bounds-safe header accessor: returns "" rather than indexing out of
  ## range, so a failing (red) test reports cleanly instead of crashing.
  result = if i < r.headers.len: r.headers[i].name else: ""

proc valueAt(r: Request; i: int): string =
  result = if i < r.headers.len: r.headers[i].value else: ""

# ── request line ──────────────────────────────────────────────────────
section "request line"

block:
  # HTTP/1.0 needs no Host, so this exercises the minimal no-header path.
  let (st, r) = parse("GET / HTTP/1.0" & CRLF & CRLF)
  check st == psOk, "minimal GET parses"
  check r.httpMethod == "GET", "method is GET"
  check r.target == "/", "target is /"
  check r.version == Http10, "version is HTTP/1.0"
  check r.headers.len == 0, "no headers"
  check r.headBytes == 18, "headBytes counts line + CRLFCRLF"

block:
  let (st, r) = parse("GET / HTTP/1.1" & CRLF & "Host: x" & CRLF & CRLF)
  check st == psOk, "minimal HTTP/1.1 request (with required Host) parses"
  check r.version == Http11, "version is HTTP/1.1"
  check r.headers.len == 1, "Host header present"

block:
  let (st, r) = parse("POST /a/b?c=1 HTTP/1.0" & CRLF & CRLF)
  check st == psOk, "POST with query parses"
  check r.httpMethod == "POST", "method is POST"
  check r.target == "/a/b?c=1", "target keeps query"
  check r.version == Http10, "version is HTTP/1.0"

# ── header fields ─────────────────────────────────────────────────────
section "header fields"

block:
  let (st, r) = parse(
    "GET / HTTP/1.1" & CRLF &
    "Host: example.com" & CRLF &
    "Accept: text/plain" & CRLF & CRLF)
  check st == psOk, "two headers parse"
  check r.headers.len == 2, "header count is 2"
  check nameAt(r, 0) == "Host", "first header name"
  check valueAt(r, 0) == "example.com", "first header value"
  check nameAt(r, 1) == "Accept", "second header name preserved in order"
  check valueAt(r, 1) == "text/plain", "second header value"

block:
  # RFC 9112 §5: OWS around the field value must be trimmed.
  let (st, r) = parse("GET / HTTP/1.1" & CRLF & "Host:   example.com   " & CRLF & CRLF)
  check st == psOk, "OWS header parses"
  check valueAt(r, 0) == "example.com", "leading/trailing OWS trimmed from value"

# ── incomplete (need more bytes) ──────────────────────────────────────
section "incomplete"

block:
  let (st, _) = parse("GET / HTTP/1.1")
  check st == psIncomplete, "bare request line (no CRLF) is incomplete"

block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & "Host: x" & CRLF)
  check st == psIncomplete, "headers without terminating CRLFCRLF are incomplete"

# ── malformed / rejected (RFC 9112 §3, smuggling defenses §11) ─────────
section "rejected"

block:
  let (st, _) = parse("GET / HTTP/1.1 extra" & CRLF & CRLF)
  check st == psError, "extra token in request line rejected (smuggling defense)"

block:
  let (st, _) = parse("GET /" & CRLF & CRLF)
  check st == psError, "request line missing version rejected"

block:
  let (st, _) = parse("GET / HTTP/2.0" & CRLF & CRLF)
  check st == psError, "unsupported HTTP version rejected"

block:
  let (st, _) = parse("GET / HTAP/1.1" & CRLF & CRLF)
  check st == psError, "malformed version token rejected"

# Field-name must be a token (RFC 9110 §5.6.2: 1*tchar). Found by the
# differential fuzzer vs Mummy — hashi was accepting non-tchar field names.
block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & "<: n" & CRLF & CRLF)
  check st == psError, "field-name with non-tchar '<' rejected"

block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & "a(b: x" & CRLF & CRLF)
  check st == psError, "field-name with non-tchar '(' rejected"

block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & "Host : x" & CRLF & CRLF)
  check st == psError, "whitespace before colon rejected (smuggling defense)"

block:
  # tchar specials must still be accepted as field-name characters. (Host last
  # so the weird header stays at index 0.)
  let (st, r) = parse("GET / HTTP/1.1" & CRLF & "X-Weird_Name.1!~: ok" & CRLF &
                      "Host: x" & CRLF & CRLF)
  check st == psOk, "valid tchar field-name accepted"
  check valueAt(r, 0) == "ok", "value parsed"

# Method must be a token too (RFC 9112 §3.1) — also found by the fuzzer.
block:
  let (st, _) = parse("GE\\T / HTTP/1.1" & CRLF & CRLF)
  check st == psError, "method with non-tchar '\\' rejected"

block:
  let (st, _) = parse("GE;T / HTTP/1.1" & CRLF & CRLF)
  check st == psError, "method with non-tchar ';' rejected"

block:
  let (st, r) = parse("PROPFIND / HTTP/1.1" & CRLF & "Host: x" & CRLF & CRLF)
  check st == psOk, "uncommon but valid token method accepted"
  check r.httpMethod == "PROPFIND", "method preserved"

# ── Host header (RFC 9112 §3.2) ────────────────────────────────────────
section "Host validation"

block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & CRLF)
  check st == psError, "HTTP/1.1 without Host rejected (400)"

block:
  let (st, _) = parse("GET / HTTP/1.0" & CRLF & CRLF)
  check st == psOk, "HTTP/1.0 without Host accepted (Host not required)"

block:
  let (st, _) = parse("GET / HTTP/1.1" & CRLF & "Host: a" & CRLF & "Host: b" & CRLF & CRLF)
  check st == psError, "duplicate Host rejected (smuggling/ambiguity)"

block:
  let (st, _) = parse("GET / HTTP/1.0" & CRLF & "Host: a" & CRLF & "Host: b" & CRLF & CRLF)
  check st == psError, "duplicate Host rejected even on HTTP/1.0"

# ── eqIgnoreCase: cmpIgnoreCase(a, b) == 0, rejecting on length first ──
var gSeed = 0x9E3779B9'u32
proc rnd(n: int): int =
  ## xorshift32: a fixed, reproducible sequence.
  gSeed = gSeed xor (gSeed shl 13)
  gSeed = gSeed xor (gSeed shr 17)
  gSeed = gSeed xor (gSeed shl 5)
  int(gSeed mod uint32(n))

proc word(n: int): string =
  const alphabet = "aAbB-zZ@[`{0"
  result = ""
  for i in 0 ..< n: result.add alphabet[rnd(alphabet.len)]

section "eqIgnoreCase agrees with cmpIgnoreCase"
block:
  var mismatches = 0
  for round in 0 ..< 4000:
    let a = word(rnd(6))
    # Half the pairs are `a` re-cased, so equal-length matches are common.
    var b = ""
    if rnd(2) == 0:
      for c in a: b.add (if rnd(2) == 0: toUpperAscii(c) else: toLowerAscii(c))
    else:
      b = word(rnd(6))
    if eqIgnoreCase(a, b) != (cmpIgnoreCase(a, b) == 0): inc mismatches
  check mismatches == 0, $mismatches & " mismatches in 4000 random pairs"
  check eqIgnoreCase("Content-Length", "content-length"), "names match across case"
  check not eqIgnoreCase("Host", "Hosts"), "a prefix is not a match"
  check not eqIgnoreCase("@", "`"), "only A-Z fold: '@' and '`' differ"

# ── clear and in-place parsing: a reused Request carries nothing over ──
section "a reused Request"

block:
  var r = default(Request)
  r.httpMethod = "POST"
  r.target = "/t"
  r.version = Http10
  r.headers = @[Header(name: "A", value: "1"), Header(name: "B", value: "2")]
  r.headBytes = 99
  r.body = "body"
  r.pathParams = @[PathParam(key: "id", val: "7")]
  r.remoteAddress = "10.0.0.1"
  r.startNanos = 5
  clear(r)
  check r.httpMethod == "" and r.target == "" and r.version == default(HttpVersion) and
        r.headers.len == 0 and r.headBytes == 0 and r.body == "" and
        r.pathParams.len == 0 and r.remoteAddress == "" and r.startNanos == 0,
    "clear leaves every field at its default"

block:
  var r = default(Request)
  check parseRequestHead("GET /a HTTP/1.1\r\nHost: h\r\nX-One: 1\r\nX-Two: 2\r\n\r\n", r) == psOk,
    "a first request parses"
  clear(r)
  check parseRequestHead("GET /b HTTP/1.1\r\nHost: h\r\n\r\n", r) == psOk, "the next parses"
  check r.headers.len == 1 and nameAt(r, 0) == "Host" and r.target == "/b",
    "only the second request's headers remain"

finish()

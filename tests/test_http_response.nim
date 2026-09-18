## Unit tests for the HTTP/1.1 response serializer (RFC 9112 §3.1.2, §5).
##
## Contract (serialize):
##   - status-line "HTTP/1.x SP status SP reason CRLF";
##   - a default `Server: hashi` is added unless the handler set one;
##   - field lines "name: value CRLF" in order;
##   - a Content-Length matching the body is added unless already present;
##   - terminating CRLF, then the body.
##
## Written against the stub (serialize returns ""), so these are red until
## implemented (TDD).

import std/syncio
import std/times
import std/strutils
import std/http/httpdate
import hashi/http/request   # Response lives alongside Request (one-hop rule)
import testkit

const CRLF = "\r\n"
const SRV = "Server: hashi" & CRLF
  ## Default Server header (RFC 9110 §10.2.4): emitted after the status line
  ## (and after Date when present) whenever the handler set none.

# ── Connection: close on the last response ────────────────────────────
section "closing"

block:
  # RFC 9112 §9.6: a server that closes after this response says so, so the
  # client does not send another request into a socket about to close.
  let r = newResponse(200, "bye")
  let s = serialize(r, withDate = false, closing = true)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Connection: close" & CRLF &
             "Content-Length: 3" & CRLF & CRLF & "bye",
    "closing adds Connection: close"

block:
  var r = newResponse(200, "x")
  r.headers.add Header(name: "Connection", value: "close")
  let s = serialize(r, withDate = false, closing = true)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Connection: close" & CRLF &
             "Content-Length: 1" & CRLF & CRLF & "x",
    "a handler's own Connection header is not duplicated"

block:
  let s = serialize(newResponse(200, "x"), withDate = false)
  check not s.contains("Connection:"), "no Connection header when keeping alive"

# ── status line + auto Content-Length ──────────────────────────────────
section "status line"

block:
  let r = newResponse(200, "hello")
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Content-Length: 5" & CRLF & CRLF & "hello",
    "minimal 200 with body + auto Content-Length"

block:
  let r = newResponse(404)
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 404 Not Found" & CRLF & SRV & "Content-Length: 0" & CRLF & CRLF,
    "404 empty body, Content-Length: 0, default reason"

block:
  let r = newResponse(204)
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 204 No Content" & CRLF & SRV & CRLF,
    "204: no body, no Content-Length (RFC 9110 §6.4.1)"

# ── custom headers ─────────────────────────────────────────────────────
section "headers"

block:
  var r = newResponse(200, "{}")
  r.headers = @[Header(name: "Content-Type", value: "application/json")]
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV &
             "Content-Type: application/json" & CRLF &
             "Content-Length: 2" & CRLF & CRLF & "{}",
    "custom header preserved, then auto Content-Length"

block:
  # Caller-set Content-Length must not be duplicated.
  var r = newResponse(200, "hello")
  r.headers = @[Header(name: "Content-Length", value: "5")]
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Content-Length: 5" & CRLF & CRLF & "hello",
    "explicit Content-Length not duplicated"

# ── bodyless statuses: never a body, no fabricated Content-Length ───────
section "bodyless statuses (1xx/204/304)"

block:
  # A handler that wrongly attaches a body to a 304 must not corrupt framing.
  let r = newResponse(304, "should be dropped")
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 304 Not Modified" & CRLF & SRV & CRLF,
    "304: body dropped, no auto Content-Length"

block:
  var r = newResponse(100)
  r.reason = "Continue"
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 100 Continue" & CRLF & SRV & CRLF,
    "1xx: no body, no Content-Length"

# ── HEAD: same headers as GET (incl. Content-Length) but no body ───────
section "HEAD"

block:
  let r = newResponse(200, "hello")
  let s = serialize(r, "HEAD", withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Content-Length: 5" & CRLF & CRLF,
    "HEAD: Content-Length reflects the would-be body, body omitted"

block:
  let r = newResponse(200, "hello")
  let s = serialize(r, "GET", withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Content-Length: 5" & CRLF & CRLF & "hello",
    "GET still carries the body"

# ── Date (RFC 9110 §6.6.1): caller supplies the clock, formatter is pure ─
section "Date header"

block:
  # RFC 7231 §7.1.1.1 IMF-fixdate example vector.
  check formatHttpDate(fromUnix(784111777'i64)) == "Sun, 06 Nov 1994 08:49:37 GMT",
    "the Date formatter matches the RFC IMF-fixdate example"

block:
  check formatHttpDate(fromUnix(0'i64)) == "Thu, 01 Jan 1970 00:00:00 GMT",
    "the Date formatter at the epoch"

block:
  let r = newResponse(200, "hi")
  let s = serialize(r, "GET", fromUnix(784111777'i64))
  check s == "HTTP/1.1 200 OK" & CRLF &
             "Date: Sun, 06 Nov 1994 08:49:37 GMT" & CRLF & SRV &
             "Content-Length: 2" & CRLF & CRLF & "hi",
    "serialize auto-adds Date (then Server) when given a clock and none present"

block:
  # A handler-set Date wins; serialize must not duplicate it.
  var r = newResponse(200, "hi")
  r.headers = @[Header(name: "Date", value: "Mon, 01 Jan 2024 00:00:00 GMT")]
  let s = serialize(r, "GET", fromUnix(784111777'i64))
  # A handler-set Date is emitted in the headers loop, which runs after the
  # auto-Server line — so here Server precedes Date (only the *auto*-Date,
  # added before Server, precedes it). Field order across distinct names is
  # not semantically significant (RFC 9110 §5.3).
  check s == "HTTP/1.1 200 OK" & CRLF & SRV &
             "Date: Mon, 01 Jan 2024 00:00:00 GMT" & CRLF &
             "Content-Length: 2" & CRLF & CRLF & "hi",
    "explicit Date not duplicated"

block:
  # `withDate = false` → no Date (for callers that own the clock).
  let r = newResponse(200, "hi")
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV & "Content-Length: 2" & CRLF & CRLF & "hi",
    "no Date when withDate is off (Server still present)"

# ── Server (RFC 9110 §10.2.4): bare product token, handler-overridable ──
section "Server header"

block:
  # Default is the bare token `hashi` (no version), right after the status line.
  let r = newResponse(200, "x")
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & "Server: hashi" & CRLF &
             "Content-Length: 1" & CRLF & CRLF & "x",
    "default Server: hashi added when handler set none"

block:
  # A handler-set Server wins; serialize must not duplicate or override it.
  var r = newResponse(200, "x")
  r.headers = @[Header(name: "Server", value: "contrast")]
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & "Server: contrast" & CRLF &
             "Content-Length: 1" & CRLF & CRLF & "x",
    "explicit Server not overridden by the default"

# ── CRLF injection guard at the handler seam (response splitting) ───────
section "CRLF injection guard"

block:
  # An attacker-influenced header value must not be able to split the response.
  var r = newResponse(200, "ok")
  r.headers = @[Header(name: "X-Echo", value: "a\r\nInjected: 1")]
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV &
             "X-Echo: aInjected: 1" & CRLF &
             "Content-Length: 2" & CRLF & CRLF & "ok",
    "CR/LF stripped from header value — no injected line"

block:
  var r = newResponse(200, "ok")
  r.headers = @[Header(name: "X-A\r\nEvil", value: "b")]
  let s = serialize(r, withDate = false)
  check s == "HTTP/1.1 200 OK" & CRLF & SRV &
             "X-AEvil: b" & CRLF &
             "Content-Length: 2" & CRLF & CRLF & "ok",
    "CR/LF stripped from header name too"

finish()

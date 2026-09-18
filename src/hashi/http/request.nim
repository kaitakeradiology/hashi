## HTTP/1.1 request parser (RFC 9112). Pure: bytes in, `Request` out — no
## I/O, no allocation policy, no connection state. The reactor feeds it a
## buffer; it reports how much it consumed, or that it needs more.
##
## Spec: RFC 9112 (HTTP/1.1 message syntax). Read before changing:
##   - §3   request line: method SP request-target SP HTTP-version CRLF
##   - §5   field lines: name ":" OWS field-value OWS CRLF
##   - §2.2 message framing; the head ends at the first CRLFCRLF
##
## `parseRequestHead` parses the head only: request line and fields. Body
## framing (Content-Length / Transfer-Encoding) and the request-smuggling
## checks of RFC 9112 §11.2 are `bodyFraming` and `decodeChunked`, below.
##
## Data layout is array-of-structs: `Request` is built once and handed to
## one handler, never bulk-iterated, so a struct-of-arrays layout would be
## premature here. The reactor's connection table is the hot, SoA-candidate
## structure, not this.

import std/[strutils, uri, times]
import std/http/[httpdate, httpwire]

type
  HttpVersion* = enum
    HttpUnknown   ## Unset / not yet parsed.
    Http10        ## HTTP/1.0
    Http11        ## HTTP/1.1

  ParseStatus* = enum
    ## Result of `parseRequestHead` / `decodeChunked`.
    psError       ## Malformed or rejected; the connection must close.
    psIncomplete  ## No CRLFCRLF yet; read more bytes and retry.
    psOk          ## Complete request head parsed; `req` is filled.

  Header* = object
    ## One field line.
    name*: string   ## Field name as received; compare case-insensitively.
    value*: string  ## Field value with surrounding OWS trimmed.

  PathParam* = object
    ## A named path-segment capture (e.g. `:id` in `/users/:id`). Filled by the
    ## router on a match and read by the handler via `pathParam`.
    key*: string
    val*: string

  QueryParam* = object
    ## One decoded `key=value` pair from a query string.
    key*: string
    val*: string

  Request* = object
    ## A parsed HTTP request, as handed to a `Handler`.
    httpMethod*: string      ## e.g. "GET" (token, case-sensitive per spec).
    target*: string          ## The request-target, in origin-form.
    version*: HttpVersion
    headers*: seq[Header]
    headBytes*: int          ## Bytes consumed: request-line + fields + CRLFCRLF.
    body*: string            ## Decoded message body (Content-Length or chunked).
    pathParams*: seq[PathParam]  ## Router-captured `:name` segments; see `pathParam`.
    remoteAddress*: string   ## Client IP (dotted-quad or IPv6); set by the server.
    startNanos*: int64       ## Monotonic request-start instant (`getMonoTime().ticks`),
                             ## stamped by the driver before dispatch. Per-request,
                             ## so it survives a `.passive` suspension via the CPS
                             ## continuation: after-middleware can measure latency
                             ## without a threadvar a concurrent request would clobber.

  BodyKind* = enum
    bkNone        ## No body (no Content-Length, no Transfer-Encoding).
    bkLength      ## Content-Length framing; `length` bytes follow the head.
    bkChunked     ## Transfer-Encoding: chunked.
    bkError       ## Ambiguous or illegal framing; reject (smuggling defense).

  BodyInfo* = object
    ## Result of `bodyFraming`.
    kind*: BodyKind
    length*: int             ## Valid when `kind == bkLength`.

  Response* = object
    ## A response message, built by a `Handler` and turned into wire bytes by
    ## `serialize`. Lives in this module beside `Request` so a handler needs
    ## only one import.
    status*: int             ## Status code, e.g. 200.
    reason*: string          ## Reason phrase, e.g. "OK".
    headers*: seq[Header]    ## Response field lines, in order.
    body*: string            ## Response body.

const MaxRequestHead* = 64 * 1024
  ## Largest accepted request head (request-line + field block, up to and
  ## including the terminating CRLFCRLF). The connection driver rejects a
  ## connection that buffers more than this without completing a head — a
  ## slowloris / header-flood guard (driver replies 431, then closes).

const MaxBodySize* = 64 * 1024 * 1024
  ## Largest accepted request body — for Content-Length *and* the assembled
  ## chunked body. A DoS guard mirroring the WebSocket layer's
  ## MaxWsPayload/MaxWsMessage. A Content-Length above this is rejected by the
  ## driver (413); a chunk-size or cumulative chunked body above this is
  ## rejected here in `decodeChunked` (psError → driver replies 400) *before*
  ## any allocation or `dataStart + size` arithmetic, which also forecloses the
  ## int64 overflow a 16+ HEXDIG chunk-size would otherwise cause.

proc isOWS(c: char): bool =
  ## RFC 9110 OWS: optional whitespace = space or horizontal tab.
  result = c == ' ' or c == '\t'

proc versionOf(token: string): HttpVersion =
  ## Map an HTTP-version token to the supported set; HttpUnknown if not.
  result = HttpUnknown
  if token == "HTTP/1.1": result = Http11
  elif token == "HTTP/1.0": result = Http10

proc isTchar(c: char): bool =
  ## RFC 9110 §5.6.2 token character: ALPHA / DIGIT / "!#$%&'*+-.^_`|~".
  if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'):
    return true
  case c
  of '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
    result = true
  else:
    result = false

proc isToken(s: string): bool =
  ## RFC 9110 §5.6.2: token = 1*tchar (non-empty).
  if s.len == 0: return false
  for c in s:
    if not isTchar(c): return false
  result = true

proc parseField(line: string; h: var Header): bool =
  ## RFC 9112 §5: `field-name ":" OWS field-value OWS`, where field-name is a
  ## token (RFC 9110 §5.6.2: 1*tchar) — so no whitespace (smuggling defense)
  ## and no other non-tchar bytes are permitted before the colon. Returns
  ## false on a malformed line.
  result = false
  let colon = find(line, ':')
  if colon <= 0:
    return false                      # no colon, or empty field name
  let name = substr(line, 0, colon - 1)
  if not isToken(name):
    return false                      # non-token field-name byte (incl. WS)
  var vs = colon + 1
  var ve = line.len
  while vs < ve and isOWS(line[vs]): inc vs
  while ve > vs and isOWS(line[ve-1]): dec ve
  h = Header(name: name, value: substr(line, vs, ve - 1))
  result = true

proc parseRequestHead*(data: string; req: var Request): ParseStatus =
  ## Parse the request line and field block from the front of `data`.
  ##
  ## Returns `psOk` and fills `req` (including `headBytes`, the length of
  ## the consumed head up to and including the terminating CRLFCRLF) when
  ## the full head is present; `psIncomplete` if the terminating CRLFCRLF
  ## has not arrived yet; `psError` if the bytes seen so far are already
  ## invalid (bad method/target/version, malformed field line, etc.).
  result = psError

  let headEnd = find(data, "\r\n\r\n")
  if headEnd < 0:
    return psIncomplete               # no CRLFCRLF yet — caller reads more

  # Request line: method SP request-target SP HTTP-version (§3).
  let lineEnd = find(data, "\r\n", 0, headEnd + 1)
  if lineEnd < 0:
    return psError
  # Exactly two single SPs split the three tokens; any other count (extra
  # token, missing version, embedded space) is rejected — also a request-
  # smuggling defense (RFC 9112 §11).
  var sp1 = -1
  var sp2 = -1
  var spCount = 0
  for i in 0 ..< lineEnd:
    if data[i] == ' ':
      inc spCount
      if sp1 < 0: sp1 = i
      elif sp2 < 0: sp2 = i
  if spCount != 2:
    return psError
  let meth = substr(data, 0, sp1 - 1)
  let target = substr(data, sp1 + 1, sp2 - 1)
  let version = versionOf(substr(data, sp2 + 1, lineEnd - 1))
  if not isToken(meth) or target.len == 0 or version == HttpUnknown:
    return psError                     # method must be a token (§3.1)

  # Field block: lines between the request line and the CRLFCRLF (§5).
  var headers = default(seq[Header])
  var pos = lineEnd + 2
  while pos < headEnd:
    let fEnd = find(data, "\r\n", pos, headEnd + 1)
    let lim = if fEnd < 0: headEnd else: fEnd
    var h = default(Header)
    if not parseField(substr(data, pos, lim - 1), h):
      return psError
    headers.add h
    pos = lim + 2

  # Host (RFC 9112 §3.2): an HTTP/1.1 request must carry exactly one; more
  # than one is invalid — a request-routing ambiguity / smuggling vector.
  var hostCount = 0
  for h in headers:
    if cmpIgnoreCase(h.name, "Host") == 0: inc hostCount
  if hostCount > 1: return psError
  if version == Http11 and hostCount == 0: return psError

  req.httpMethod = meth
  req.target = target
  req.version = version
  req.headers = headers
  req.headBytes = headEnd + 4
  result = psOk

const CRLF = "\r\n"

proc pathParam*(req: Request; key: string): string =
  ## The captured value for a named path segment (`:key`), or "" if absent.
  ## Case-sensitive on `key` (it's the literal name from the route pattern).
  result = ""
  for p in req.pathParams:
    if p.key == key: return p.val

proc rawPath(target: string): string =
  ## The request-target up to the first `?`.
  let q = find(target, '?')
  result = if q < 0: target else: substr(target, 0, q - 1)

proc path*(req: Request): string =
  ## The percent-decoded path (query string stripped). `/a%20b?x=1` → `/a b`.
  ## A malformed escape (`%` not followed by two hex digits) is not a URI
  ## and decodes to ""; `+` stays literal, as it is in a path.
  result = ""
  discard decodeUrl(rawPath(req.target), result)

proc query*(req: Request): string =
  ## The raw query string (after `?`), undecoded. "" if none.
  let q = find(req.target, '?')
  result = if q < 0: "" else: substr(req.target, q + 1)

proc queryParams*(req: Request): seq[QueryParam] =
  ## The query's `key=value` pairs, each side percent-decoded with `+` as a
  ## space (`std/uri.decodeQuery`): a bare key has an empty value, empty
  ## pairs are dropped, a pair with a malformed escape is skipped, and
  ## repeated keys are kept in order.
  result = @[]
  for (k, v) in decodeQuery(query(req)):
    result.add QueryParam(key: k, val: v)

proc queryParam*(req: Request; key: string): string =
  ## First value for query key `key`, or "" if absent.
  result = ""
  for (k, v) in decodeQuery(query(req)):
    if k == key: return v

proc header*(req: Request; name: string): string =
  ## First header value for `name` (case-insensitive), or "" if absent.
  result = ""
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0: return h.value

proc headers*(req: Request; name: string): seq[string] =
  ## All header values for `name` (case-insensitive), in received order.
  result = @[]
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0: result.add h.value

proc hasHeader*(req: Request; name: string): bool =
  ## Whether a header named `name` (case-insensitive) is present.
  result = false
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0: return true

proc newResponse*(status: int; body = ""): Response =
  ## A response with the conventional reason phrase for `status` and no
  ## headers.
  result = default(Response)
  result.status = status
  result.reason = reasonPhrase(status)
  result.body = body

proc isBodylessStatus(status: int): bool =
  ## RFC 9110 §6.4.1 / §15.3.5 / §15.4.5: 1xx, 204 and 304 never carry a
  ## message body (and so must not get a fabricated Content-Length).
  result = (status >= 100 and status < 200) or status == 204 or status == 304

proc sanitizeFieldText(s: string): string =
  ## Strip CR/LF from a field name or value — a response-splitting guard at
  ## the handler seam (RFC 9110 §5.5: field values are visible-ASCII + OWS,
  ## never CR/LF). Without this, attacker-influenced header data could inject
  ## extra header lines or a body.
  result = ""
  for c in s:
    if c != '\r' and c != '\n':
      result.add c

proc serialize*(resp: Response; httpMethod = ""; now = getTime();
                withDate = true; closing = false): string =
  ## Serialize `resp` to HTTP/1.1 wire bytes: status-line, field lines, the
  ## terminating CRLF, then the body. We are an HTTP/1.1 server, so the
  ## status-line version is always `HTTP/1.1`. The caller may supply the
  ## clock (`now`) and the request method, so this stays testable.
  ##
  ## Conformance applied here:
  ##   - `Date` (RFC 9110 §6.6.1) is added from `now` when `withDate` and the
  ##     handler set none.
  ##   - `Server` (RFC 9110 §10.2.4) defaults to the bare product token `hashi`
  ##     when the handler set none. A bare token (no version) identifies the
  ##     transport for debugging without the fingerprinting surface of a
  ##     version string; a handler may override it (e.g. an app's own name).
  ##   - 1xx/204/304 carry no body and get no fabricated Content-Length
  ##     (guards keep-alive framing against a stray handler body).
  ##   - a HEAD response keeps the Content-Length it would send for GET but
  ##     omits the body (RFC 9110 §9.3.2).
  ##   - `closing` adds `Connection: close` (RFC 9112 §9.6) when the handler
  ##     set no Connection header: the server will close after this response.
  ##   - CR/LF are stripped from field names/values (response-splitting guard).
  let bodyless = isBodylessStatus(resp.status)
  let isHead = httpMethod == "HEAD"
  result = "HTTP/1.1 " & $resp.status & " " & resp.reason & CRLF
  var hasCL = false
  var hasDate = false
  var hasServer = false
  var hasConn = false
  for h in resp.headers:
    if cmpIgnoreCase(h.name, "Content-Length") == 0: hasCL = true
    if cmpIgnoreCase(h.name, "Date") == 0: hasDate = true
    if cmpIgnoreCase(h.name, "Server") == 0: hasServer = true
    if cmpIgnoreCase(h.name, "Connection") == 0: hasConn = true
  if withDate and not hasDate:
    result.add "Date: " & formatHttpDate(now) & CRLF
  if not hasServer:
    result.add "Server: hashi" & CRLF
  if closing and not hasConn:
    result.add "Connection: close" & CRLF
  for h in resp.headers:
    result.add sanitizeFieldText(h.name) & ": " & sanitizeFieldText(h.value) & CRLF
  if not hasCL and not bodyless:
    # Content-Length is the body's length even for HEAD (the would-be GET body).
    result.add "Content-Length: " & $resp.body.len & CRLF
  result.add CRLF
  if not bodyless and not isHead:
    result.add resp.body

proc parseContentLength(s: string): int =
  ## ASCII digits only — no sign, no spaces, no comma-lists. Returns -1 on
  ## anything invalid (incl. empty), and on absurd lengths (>18 digits) to
  ## avoid int overflow.
  if s.len == 0 or s.len > 18:
    return -1
  var n = 0
  for c in s:
    if c < '0' or c > '9':
      return -1
    n = n * 10 + (c.ord - '0'.ord)
  result = n

proc bodyFraming*(req: Request): BodyInfo =
  ## Decide how the request body is framed from its headers:
  ##   - `bkLength` with `length` from a single valid Content-Length;
  ##   - `bkChunked` if Transfer-Encoding is exactly chunked;
  ##   - `bkNone` if neither header is present;
  ##   - `bkError` for anything ambiguous or illegal (Content-Length *and*
  ##     Transfer-Encoding together, duplicate Content-Length, non-digit
  ##     Content-Length, a non-chunked or repeated Transfer-Encoding) — the
  ##     request-smuggling defenses of RFC 9112 §11.
  var clCount = 0
  var clValue = -1
  var teCount = 0
  var teChunked = false
  var teOther = false
  for h in req.headers:
    if cmpIgnoreCase(h.name, "Content-Length") == 0:
      inc clCount
      clValue = parseContentLength(h.value)
    elif cmpIgnoreCase(h.name, "Transfer-Encoding") == 0:
      inc teCount
      if cmpIgnoreCase(h.value, "chunked") == 0:
        teChunked = true
      else:
        teOther = true

  # CL and TE together, or either appearing more than once: ambiguous → reject.
  if clCount > 0 and teCount > 0:
    return BodyInfo(kind: bkError, length: 0)
  if teCount > 0:
    if teCount == 1 and teChunked and not teOther:
      return BodyInfo(kind: bkChunked, length: 0)
    return BodyInfo(kind: bkError, length: 0)
  if clCount > 1:
    return BodyInfo(kind: bkError, length: 0)
  if clCount == 1:
    if clValue < 0:
      return BodyInfo(kind: bkError, length: 0)
    return BodyInfo(kind: bkLength, length: clValue)
  result = BodyInfo(kind: bkNone, length: 0)

proc hexVal(c: char): int =
  if c >= '0' and c <= '9': return c.ord - '0'.ord
  if c >= 'a' and c <= 'f': return c.ord - 'a'.ord + 10
  if c >= 'A' and c <= 'F': return c.ord - 'A'.ord + 10
  result = -1

proc decodeChunked*(data: string; start: int; body: var string;
                    maxBody = MaxBodySize): (ParseStatus, int) =
  ## Decode a chunked body from `data[start ..]` (RFC 9112 §7.1):
  ##   chunked-body = *chunk last-chunk trailer-section CRLF
  ##   chunk        = chunk-size [chunk-ext] CRLF chunk-data CRLF
  ## Returns `(psOk, consumed)` with `body` filled and `consumed` the number of
  ## bytes from `start` through the terminating CRLF; `(psIncomplete, 0)` if
  ## more bytes are needed; `(psError, 0)` if malformed. chunk-ext and trailer
  ## fields are skipped (not surfaced).
  body = ""
  var pos = start
  while true:
    let lineEnd = find(data, "\r\n", pos)
    if lineEnd < 0:
      return (psIncomplete, 0)
    # chunk-size = 1*HEXDIG, up to ';' (chunk-ext) or CRLF
    var size = 0
    var k = pos
    var any = false
    while k < lineEnd and data[k] != ';':
      let v = hexVal(data[k])
      if v < 0:
        return (psError, 0)
      size = size * 16 + v
      if size > maxBody:
        return (psError, 0)               # oversized chunk-size (DoS / pre-overflow guard)
      any = true
      k = k + 1
    if not any:
      return (psError, 0)                 # missing chunk-size
    if size == 0:
      # last-chunk: consume trailer-section, then the terminating CRLF
      var tpos = lineEnd + 2
      while true:
        let tEnd = find(data, "\r\n", tpos)
        if tEnd < 0:
          return (psIncomplete, 0)
        if tEnd == tpos:                  # empty line ends the trailers
          return (psOk, tEnd + 2 - start)
        tpos = tEnd + 2                   # skip a trailer field line
    else:
      if body.len + size > maxBody:
        return (psError, 0)               # cumulative chunked body over cap (DoS guard)
      let dataStart = lineEnd + 2
      let dataEnd = dataStart + size
      if dataEnd + 2 > data.len:
        return (psIncomplete, 0)          # need chunk-data + its CRLF
      if data[dataEnd] != '\r' or data[dataEnd + 1] != '\n':
        return (psError, 0)               # chunk-data not CRLF-terminated
      body.add substr(data, dataStart, dataEnd - 1)
      pos = dataEnd + 2

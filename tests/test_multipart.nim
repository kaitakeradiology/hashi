## Unit tests for the multipart/form-data parser (RFC 7578).
##
## Covers: boundary extraction (plain + quoted + non-multipart), single and
## multi-part bodies, a field with no filename, a part with no Content-Type,
## CRLF header/body framing, the close-delimiter (no spurious trailing empty
## part), graceful handling of malformed/empty input, and that a boundary-
## looking substring *inside* part data doesn't cause a false split.

import std/syncio
import hashi/http/request
import hashi/http/multipart
import testkit

const CRLF = "\r\n"

# ── parseBoundary ──────────────────────────────────────────────────────
section "parseBoundary"

block:
  let b = parseBoundary("multipart/form-data; boundary=----WebKitFormBoundaryABC123")
  check b == "----WebKitFormBoundaryABC123", "plain boundary extracted"

block:
  let b = parseBoundary("multipart/form-data; boundary=\"abc123\"")
  check b == "abc123", "quoted boundary extracted, quotes stripped"

block:
  let b = parseBoundary("application/json")
  check b == "", "non-multipart content-type -> empty"

block:
  let b = parseBoundary("multipart/form-data")
  check b == "", "multipart/form-data with no parameters -> empty"

block:
  let b = parseBoundary("multipart/form-data; charset=utf-8")
  check b == "", "multipart/form-data with no boundary param -> empty"

block:
  let b = parseBoundary("Multipart/Form-Data; boundary=XYZ")
  check b == "XYZ", "media type match is case-insensitive"

# ── single file part ────────────────────────────────────────────────────
section "single file part"

block:
  let body = "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"todoFile\"; filename=\"todo.txt\"" & CRLF &
             "Content-Type: text/plain" & CRLF &
             CRLF &
             "line one" & CRLF &
             CRLF &
             "line three" & CRLF &
             "--BOUNDARY--" & CRLF
  let parts = parseMultipartForm(body, "BOUNDARY")
  check parts.len == 1, "one part parsed"
  check parts[0].name == "todoFile", "name from Content-Disposition"
  check parts[0].filename == "todo.txt", "filename from Content-Disposition"
  check parts[0].contentType == "text/plain", "content-type captured"
  check parts[0].data == "line one" & CRLF & CRLF & "line three",
        "trailing CRLF before boundary stripped, internal blank line preserved"

# ── multiple parts (field + file), no filename, no content-type ────────
section "multiple parts"

block:
  let body = "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"description\"" & CRLF &
             CRLF &
             "hello world" & CRLF &
             "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"todoFile\"; filename=\"todo.txt\"" & CRLF &
             "Content-Type: text/plain" & CRLF &
             CRLF &
             "file contents" & CRLF &
             "--BOUNDARY--" & CRLF
  let parts = parseMultipartForm(body, "BOUNDARY")
  check parts.len == 2, "two parts parsed, in order"
  check parts[0].name == "description", "first part name"
  check parts[0].filename == "", "plain field has no filename"
  check parts[0].contentType == "", "plain field has no content-type"
  check parts[0].data == "hello world", "first part data"
  check parts[1].name == "todoFile", "second part name"
  check parts[1].filename == "todo.txt", "second part filename"
  check parts[1].contentType == "text/plain", "second part content-type"
  check parts[1].data == "file contents", "second part data"

# ── close-delimiter: no spurious trailing empty part ────────────────────
section "close delimiter"

block:
  let body = "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"a\"" & CRLF &
             CRLF &
             "x" & CRLF &
             "--BOUNDARY--" & CRLF
  let parts = parseMultipartForm(body, "BOUNDARY")
  check parts.len == 1, "close-delimiter does not produce a spurious empty part"

# ── boundary-looking substring inside part data ─────────────────────────
section "no false split on embedded boundary text"

block:
  let body = "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"text\"" & CRLF &
             CRLF &
             "some text --BOUNDARY not a real delimiter" & CRLF &
             "--BOUNDARY--" & CRLF
  let parts = parseMultipartForm(body, "BOUNDARY")
  check parts.len == 1, "one part, not split on embedded boundary-like text"
  check parts[0].data == "some text --BOUNDARY not a real delimiter",
        "embedded boundary text preserved verbatim (only real CRLF--boundary splits)"

# ── graceful handling of malformed / empty input ────────────────────────
section "graceful handling"

block:
  check parseMultipartForm("", "BOUNDARY").len == 0, "empty body -> empty seq"

block:
  check parseMultipartForm("nothing here", "BOUNDARY").len == 0,
        "no boundary match in body -> empty seq"

block:
  check parseMultipartForm("--BOUNDARY" & CRLF & "junk with no separator", "BOUNDARY").len == 0,
        "no header/body separator -> empty seq"

block:
  check parseMultipartForm("some body", "").len == 0, "empty boundary -> empty seq"

block:
  let boundary = parseBoundary("multipart/form-data; charset=utf-8")
  check parseMultipartForm("--anything--", boundary).len == 0,
        "content-type without boundary param -> empty seq end to end"

# ── parseMultipart(req) convenience ─────────────────────────────────────
section "parseMultipart(req)"

block:
  var req = default(Request)
  req.httpMethod = "POST"
  req.target = "/api/todo/import"
  req.version = Http11
  req.headers = @[Header(name: "Content-Type",
                         value: "multipart/form-data; boundary=BOUNDARY")]
  req.body = "--BOUNDARY" & CRLF &
             "Content-Disposition: form-data; name=\"todoFile\"; filename=\"todo.txt\"" & CRLF &
             "Content-Type: text/plain" & CRLF &
             CRLF &
             "buy milk" & CRLF &
             "--BOUNDARY--" & CRLF
  let parts = parseMultipart(req)
  check parts.len == 1, "parseMultipart pulls Content-Type + body from the request"
  check parts[0].name == "todoFile", "field name via convenience proc"
  check parts[0].data == "buy milk", "data via convenience proc"

block:
  var req = default(Request)
  req.httpMethod = "POST"
  req.target = "/"
  req.version = Http11
  req.headers = @[Header(name: "Content-Type", value: "application/json")]
  req.body = "{}"
  check parseMultipart(req).len == 0, "non-multipart request -> empty seq"

finish()

## `multipart/form-data` parser (RFC 7578): what a browser's `FormData`
## sends on a file-upload POST. Pure — strings in, `seq[Part]` out, no I/O,
## no allocation policy, no connection state (mirrors `hashi/http/request`).
##
## Scope is form-data only; the general MIME multipart tree (nested
## `multipart/mixed`, `multipart/alternative`, etc.) is out of scope, a
## rabbit hole RFC 7578 deliberately narrows away from.
##
## Error handling is deliberately silent: malformed input — no `boundary`,
## no delimiter found, a header block with no blank-line terminator, a
## truncated final part — stops parsing and returns whatever parts were
## cleanly parsed before the problem (typically none, for a body that is
## garbage from the start). Nothing here raises. A file-upload endpoint sits
## on the front line of attacker-controlled input; refusing to parse should
## look like "no files were uploaded", not a crashed request.

import std/strutils
import hashi/http/request

type
  Part* = object
    ## One decoded part of a `multipart/form-data` body.
    name*: string         ## Form field name, from Content-Disposition `name=`; "" if absent.
    filename*: string     ## From Content-Disposition `filename=`; "" if this part isn't a file.
    contentType*: string  ## The part's Content-Type header value; "" if it had none.
    data*: string          ## Raw part body. The CRLF just before the boundary is stripped;
                           ## internal CRLFs (blank lines, multi-line text) are not.

proc paramValue(s: string; key: string): string =
  ## Find the value of parameter `key` in a `;`-separated parameter list (a
  ## Content-Type or Content-Disposition header value, e.g.
  ## `form-data; name="f"; filename="x.txt"`). Case-insensitive on `key`,
  ## quotes stripped if the value is quoted. "" if `key` isn't present.
  ##
  ## Splits on `;` first and compares whole parameter names — a naive
  ## substring search for `"key="` would false-match `name=` inside
  ## `filename=`.
  result = ""
  let lowerKey = toLowerAscii(key)
  let n = s.len
  var i = 0
  while i < n:
    while i < n and (s[i] == ' ' or s[i] == '\t' or s[i] == ';'):
      i = i + 1
    if i >= n: break
    var j = i
    var inQuotes = false
    while j < n and (inQuotes or s[j] != ';'):
      if s[j] == '"': inQuotes = not inQuotes
      j = j + 1
    let paramStr = substr(s, i, j - 1)
    var eq = -1
    var k = 0
    while k < paramStr.len:
      if paramStr[k] == '=':
        eq = k
        break
      k = k + 1
    if eq > 0:
      let pkey = toLowerAscii(strip(substr(paramStr, 0, eq - 1)))
      if pkey == lowerKey:
        var v = strip(substr(paramStr, eq + 1))
        if v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"':
          v = substr(v, 1, v.len - 2)
        return v
    i = j + 1

proc parseBoundary*(contentType: string): string =
  ## Extract the `boundary` parameter from a `Content-Type` header value,
  ## e.g. `multipart/form-data; boundary=----WebKitFormBoundaryABC123` or a
  ## quoted `boundary="…"`. Returns "" if `contentType`'s media type isn't
  ## (case-insensitively) `multipart/form-data`, or it has no boundary.
  result = ""
  let semi = find(contentType, ';')
  let mediaType = strip(if semi < 0: contentType else: substr(contentType, 0, semi - 1))
  if toLowerAscii(mediaType) != "multipart/form-data":
    return
  if semi < 0: return
  result = paramValue(substr(contentType, semi + 1), "boundary")

proc splitHeaderLines(headerBlock: string): seq[string] =
  ## Split a CRLF-joined header block (as found before a part's blank-line
  ## separator) into individual field lines. Empty lines contribute nothing.
  result = @[]
  let n = headerBlock.len
  var start = 0
  var i = 0
  while i < n:
    if i + 1 < n and headerBlock[i] == '\r' and headerBlock[i + 1] == '\n':
      if i > start:
        result.add substr(headerBlock, start, i - 1)
      i = i + 2
      start = i
    else:
      i = i + 1
  if start < n:
    result.add substr(headerBlock, start, n - 1)

proc splitHeaderField(line: string; hname, hvalue: var string): bool =
  ## `name: value` for one part-header line, OWS-trimmed. False if there's
  ## no colon (malformed line — the caller skips it).
  let colon = find(line, ':')
  if colon <= 0:
    return false
  hname = strip(substr(line, 0, colon - 1))
  hvalue = strip(substr(line, colon + 1))
  result = true

proc parseMultipartForm*(body, boundary: string): seq[Part] =
  ## Parse a `multipart/form-data` body (RFC 7578) delimited by `boundary`
  ## (as returned by `parseBoundary`, without the leading `--`).
  ##
  ## Body layout per part: `--boundary CRLF` then header lines (`name:
  ## value CRLF`) up to a blank `CRLF CRLF`, then the part body, up to the
  ## `CRLF` immediately before the next `--boundary` (which is stripped from
  ## `data`). The final part is followed by the close-delimiter
  ## `--boundary--` rather than another part.
  ##
  ## See the module doc comment for the error-handling contract: any
  ## structural problem stops parsing and returns the parts cleanly parsed
  ## so far (often none).
  result = @[]
  if boundary.len == 0 or body.len == 0:
    return

  let delim = "--" & boundary
  var pos = find(body, delim)
  if pos < 0:
    return
  pos = pos + delim.len

  while true:
    # Close-delimiter: "--" immediately follows this boundary occurrence —
    # no more parts, and NOT a spurious trailing empty part.
    if pos + 1 < body.len and body[pos] == '-' and body[pos + 1] == '-':
      break
    if pos + 1 >= body.len or body[pos] != '\r' or body[pos + 1] != '\n':
      break                                  # not followed by CRLF — malformed, stop

    pos = pos + 2                            # skip the boundary line's CRLF

    let sep = find(body, "\r\n\r\n", pos)
    if sep < 0:
      break                                  # no header/body separator — truncated, stop
    let headerBlock = substr(body, pos, sep - 1)
    let dataStart = sep + 4

    # The real end-of-part delimiter is CRLF immediately followed by the
    # boundary text — this is what keeps an incidental occurrence of the
    # boundary bytes *inside* a part's data from causing a false split.
    let nextDelim = find(body, "\r\n" & delim, dataStart)
    if nextDelim < 0:
      break                                  # unterminated final part — stop
    let partData = substr(body, dataStart, nextDelim - 1)

    var part = Part(name: "", filename: "", contentType: "", data: partData)
    let lines = splitHeaderLines(headerBlock)
    var li = 0
    while li < lines.len:
      var hname = ""
      var hvalue = ""
      if splitHeaderField(lines[li], hname, hvalue):
        if toLowerAscii(hname) == "content-disposition":
          part.name = paramValue(hvalue, "name")
          part.filename = paramValue(hvalue, "filename")
        elif toLowerAscii(hname) == "content-type":
          part.contentType = hvalue
      li = li + 1
    result.add part

    pos = nextDelim + 2 + delim.len          # step past CRLF + this boundary's text

proc parseMultipart*(req: Request): seq[Part] =
  ## Convenience: read the boundary from `req`'s Content-Type header and
  ## parse `req.body`. Empty seq if the request isn't `multipart/form-data`
  ## (see `parseBoundary`) or the body doesn't parse (see
  ## `parseMultipartForm`).
  let boundary = parseBoundary(header(req, "Content-Type"))
  result = parseMultipartForm(req.body, boundary)

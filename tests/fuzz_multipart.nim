## Fuzzer for the `multipart/form-data` parser (RFC 7578). Arms:
##   1. random bodies and boundaries never crash `parseMultipartForm` or
##      `parseBoundary`;
##   2. a body assembled from random parts parses back to the same names,
##      filenames, content types and data, byte for byte, including data
##      that contains CRLFs and the boundary text itself.
##
##   ../nimony/bin/nimony c -r tests/fuzz_multipart.nim

import std/syncio
import hashi/http/request
import hashi/http/multipart
import testkit
import fuzzkit

seedFuzz(0x3C6EF372FE94F82B'i64)
const iterations = 2000

section "parseMultipartForm on random input (no crash)"
block:
  var parts = 0
  for it in 0 ..< iterations:
    let boundary = if rnd(3) == 0: "" else: randomAlnum(12)
    var body = ""
    case rnd(3)
    of 0: body = randomBytes(120)
    of 1: body = "--" & boundary & randomBytes(60)
    else: body = "--" & boundary & "\r\nContent-Disposition: " & randomBytes(30) & "\r\n\r\n" & randomBytes(40)
    parts = parts + parseMultipartForm(body, boundary).len
    discard parseBoundary(randomBytes(40))
    discard parseBoundary("multipart/form-data; boundary=" & randomBytes(20))
  check parts >= 0, "parser survived " & $iterations & " random bodies"

section "round-trip"
block:
  var bad = 0
  for it in 0 ..< iterations:
    let boundary = "----" & randomAlnum(16)
    var names: seq[string] = @[]
    var files: seq[string] = @[]
    var types: seq[string] = @[]
    var datas: seq[string] = @[]
    var body = ""
    for k in 0 ..< 1 + rnd(5):
      let name = randomAlnum(8)
      let file = if rnd(2) == 0: randomAlnum(6) & ".bin" else: ""
      let ctype = if rnd(2) == 0: "application/" & randomAlnum(5) else: ""
      # Data with CRLFs and a decoy copy of the boundary text inside it. The
      # decoy must not follow a CRLF: `CRLF--boundary` IS the delimiter, and
      # RFC 7578 makes it the encoder's job to pick a boundary that never
      # occurs that way in the data.
      var data = randomBytes(30)
      if rnd(2) == 0: data.add "\r\n" & randomBytes(10)
      if rnd(3) == 0:
        if data.len > 0 and data[data.len - 1] == '\n': data.add 'x'
        data.add "--" & boundary & randomBytes(5)
      names.add name; files.add file; types.add ctype; datas.add data
      body.add "--" & boundary & "\r\n"
      body.add "Content-Disposition: form-data; name=\"" & name & "\""
      if file.len > 0: body.add "; filename=\"" & file & "\""
      body.add "\r\n"
      if ctype.len > 0: body.add "Content-Type: " & ctype & "\r\n"
      body.add "\r\n" & data & "\r\n"
    body.add "--" & boundary & "--\r\n"
    let got = parseMultipartForm(body, boundary)
    if got.len != names.len:
      inc bad
    else:
      for k in 0 ..< names.len:
        if got[k].name != names[k] or got[k].filename != files[k] or
           got[k].contentType != types[k] or got[k].data != datas[k]:
          inc bad
    let ct = "multipart/form-data; boundary=" & boundary
    if parseBoundary(ct) != boundary: inc bad
  check bad == 0, "all " & $iterations & " generated forms round-trip exactly"

finish()

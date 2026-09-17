## Unit tests for request body framing + smuggling defenses (RFC 9112 §6, §11).
##
## bodyFraming(req) reads the framing headers and returns:
##   - bkNone    : no Content-Length, no Transfer-Encoding
##   - bkLength  : single valid Content-Length (length set)
##   - bkChunked : Transfer-Encoding final coding is chunked
##   - bkError   : ambiguous/illegal (CL+TE, dup/bad CL, non-chunked TE)
##
## Red against the stub (always bkError) until implemented.

import std/syncio
import hashi/http/request
import testkit

proc reqWith(hs: seq[Header]): Request =
  result = default(Request)
  result.httpMethod = "POST"
  result.target = "/"
  result.version = Http11
  result.headers = hs

# ── no body ─────────────────────────────────────────────────────────────
section "no body"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Host", value: "x")]))
  check bi.kind == bkNone, "no CL and no TE -> bkNone"

# ── Content-Length ───────────────────────────────────────────────────────
section "content-length"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Content-Length", value: "5")]))
  check bi.kind == bkLength, "valid CL -> bkLength"
  check bi.length == 5, "CL length parsed"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "content-length", value: "0")]))
  check bi.kind == bkLength, "CL is case-insensitive"
  check bi.length == 0, "CL zero"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Content-Length", value: "12345")]))
  check bi.kind == bkLength and bi.length == 12345, "multi-digit CL"

# ── chunked ──────────────────────────────────────────────────────────────
section "chunked"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Transfer-Encoding", value: "chunked")]))
  check bi.kind == bkChunked, "TE: chunked -> bkChunked"

# ── smuggling / illegal framing (§11) ────────────────────────────────────
section "rejected"

block:
  let bi = bodyFraming(reqWith(@[
    Header(name: "Content-Length", value: "5"),
    Header(name: "Transfer-Encoding", value: "chunked")]))
  check bi.kind == bkError, "CL + TE together rejected (smuggling)"

block:
  let bi = bodyFraming(reqWith(@[
    Header(name: "Content-Length", value: "5"),
    Header(name: "Content-Length", value: "6")]))
  check bi.kind == bkError, "conflicting duplicate Content-Length rejected"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Content-Length", value: "5x")]))
  check bi.kind == bkError, "non-digit Content-Length rejected"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Content-Length", value: "")]))
  check bi.kind == bkError, "empty Content-Length rejected"

block:
  let bi = bodyFraming(reqWith(@[Header(name: "Transfer-Encoding", value: "gzip")]))
  check bi.kind == bkError, "non-chunked Transfer-Encoding rejected (length unknown)"

# ── chunked decoding (RFC 9112 §7.1) ──────────────────────────────────────
section "chunked decoding"

const CRLF = "\r\n"

proc dec(s: string): (ParseStatus, string, int) =
  var body = ""
  let (st, n) = decodeChunked(s, 0, body)
  result = (st, body, n)

block:
  let (st, body, n) = dec("5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF)
  check st == psOk, "single chunk decodes"
  check body == "hello", "chunk data concatenated"
  check n == 15, "consumed whole chunked body"

block:
  let (st, body, _) = dec("5" & CRLF & "Hello" & CRLF & "6" & CRLF & " world" & CRLF & "0" & CRLF & CRLF)
  check st == psOk, "multiple chunks decode"
  check body == "Hello world", "chunks concatenated in order"

block:
  let (st, body, _) = dec("0" & CRLF & CRLF)
  check st == psOk, "empty body (immediate last-chunk)"
  check body == "", "no data"

block:
  let (st, body, _) = dec("A" & CRLF & "0123456789" & CRLF & "0" & CRLF & CRLF)
  check st == psOk, "hex chunk-size (0xA = 10) decodes"
  check body == "0123456789", "10 bytes read"

block:
  let (st, body, _) = dec("5;ext=1" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF)
  check st == psOk, "chunk-ext ignored"
  check body == "hello", "data after chunk-ext"

block:
  let (st, _, _) = dec("5" & CRLF & "he")        # data not all here yet
  check st == psIncomplete, "partial chunk data -> incomplete"

block:
  let (st, _, _) = dec("5" & CRLF & "hello")      # missing trailing CRLF + last-chunk
  check st == psIncomplete, "missing chunk CRLF -> incomplete"

block:
  let (st, _, _) = dec("3" & CRLF)                # size line only
  check st == psIncomplete, "size line without data -> incomplete"

block:
  let (st, _, _) = dec("zz" & CRLF & "x" & CRLF)  # non-hex size
  check st == psError, "non-hex chunk-size rejected"

block:
  let (st, _, _) = dec("5" & CRLF & "helloXX0" & CRLF & CRLF)  # bad post-data bytes
  check st == psError, "chunk-data not CRLF-terminated rejected"

block:
  # trailer fields after the last chunk are consumed (and skipped)
  let (st, body, _) = dec("5" & CRLF & "hello" & CRLF & "0" & CRLF &
                          "X-Trailer: v" & CRLF & CRLF)
  check st == psOk, "trailer section consumed"
  check body == "hello", "body unaffected by trailer"

# ── chunk-size DoS guards (RFC 9112 §7.1, smuggling/DoS §11) ──────────────
# A chunk-size is 1*HEXDIG with no spec bound, so an unbounded accumulator can
# (a) buffer arbitrarily much for a size the client never delivers, and
# (b) overflow int64 (16+ hex digits), risking a negative dataEnd / OOB read.
# decodeChunked must reject a chunk-size (or cumulative body) above MaxBodySize
# *before* allocating or computing dataEnd. These values exceed the 64 MiB cap
# but stay well inside int64, so the red run returns psIncomplete (no overflow
# arithmetic) and the fix flips them to psError.
section "chunked size limits"

block:
  let (st, _, _) = dec("10000000" & CRLF)        # 0x10000000 = 256 MiB > cap
  check st == psError, "chunk-size above MaxBodySize rejected"

block:
  let (st, _, _) = dec("7ffffff0" & CRLF)        # ~2 GiB, still > cap
  check st == psError, "large chunk-size rejected before buffering"

block:
  # the same accumulation cap stops the int64-overflow case (16 'f's) early,
  # since size crosses MaxBodySize after ~7 hex digits and bails first.
  let (st, _, _) = dec("ffffffff" & CRLF)        # 0xffffffff = 4 GiB > cap
  check st == psError, "chunk-size that would overflow on more digits rejected"

finish()

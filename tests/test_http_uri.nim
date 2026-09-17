## Unit tests for the Request accessors: path and query decoding (through
## `std/uri`) and the header conveniences. All pure.

import std/syncio
import hashi/http/request
import testkit

# ── path / query decoding through std/uri ────────────────────────────────
section "path decoding"
proc reqWith(target: string): Request =
  result = default(Request)
  result.httpMethod = "GET"
  result.target = target
block: check reqWith("/hello").path == "/hello", "plain passthrough"
block: check reqWith("/a%20b").path == "/a b", "%20 -> space"
block: check reqWith("/x%2Fy").path == "/x/y", "%2F -> slash"
block: check reqWith("/%41%42").path == "/AB", "consecutive escapes"
block: check reqWith("/%E2%9C%93").path == "/\xE2\x9C\x93", "utf-8 bytes preserved"
block: check reqWith("/a+b").path == "/a+b", "plus stays literal in a path"
block: check reqWith("/%2g").path == "", "a malformed escape is not a path"
block: check reqWith("/%").path == "", "a trailing percent is not a path"
block: check reqWith("/%61bc").path == "/abc", "escape then literals"

section "query parsing"
block:
  let q = reqWith("/?a=1&b=2").queryParams
  check q.len == 2, "two pairs"
  check q[0].key == "a" and q[0].val == "1", "first pair"
  check q[1].key == "b" and q[1].val == "2", "second pair"
block:
  let q = reqWith("/?a=1&a=2").queryParams
  check q.len == 2 and q[0].val == "1" and q[1].val == "2", "repeated key kept"
block:
  let q = reqWith("/?flag").queryParams
  check q.len == 1 and q[0].key == "flag" and q[0].val == "", "bare key -> empty value"
block:
  let q = reqWith("/?q=hi+there&x=%2F").queryParams
  check q[0].val == "hi there", "plus -> space in query value"
  check q[1].val == "/", "percent-decoded query value"
block:
  check reqWith("/").queryParams.len == 0, "no query -> none"
  check reqWith("/").query == "", "no query -> empty raw query"
block:
  check reqWith("/?a=1&").queryParams.len == 1, "trailing & ignored"
block:
  check reqWith("/?a=%2g&b=2").queryParams.len == 1, "a pair with a malformed escape is skipped"

# ── Request accessors ─────────────────────────────────────────────────────
section "request accessors"

block:
  check reqWith("/a%20b?x=1").path == "/a b", "decoded path strips query"
block:
  check reqWith("/plain").path == "/plain", "path without query"
block:
  check reqWith("/s?q=hi+there").queryParam("q") == "hi there", "queryParam decode"
block:
  check reqWith("/s?a=1&b=2").queryParam("b") == "2", "queryParam by key"
block:
  check reqWith("/s").queryParam("missing") == "", "missing query param -> empty"

# ── header convenience ────────────────────────────────────────────────────
section "header accessors"

proc reqHdrs(): Request =
  result = default(Request)
  result.headers = @[
    Header(name: "Content-Type", value: "text/plain"),
    Header(name: "X-Tag", value: "a"),
    Header(name: "x-tag", value: "b"),
  ]

block:
  check reqHdrs().header("content-type") == "text/plain", "header lookup is case-insensitive"
block:
  check reqHdrs().header("X-Missing") == "", "absent header -> empty"
block:
  let vs = reqHdrs().headers("X-Tag")
  check vs.len == 2 and vs[0] == "a" and vs[1] == "b", "headers() returns all values"
block:
  check reqHdrs().hasHeader("X-TAG"), "hasHeader case-insensitive"
block:
  check not reqHdrs().hasHeader("nope"), "hasHeader false when absent"

finish()

## Unit tests for the HTTP router (pure match + dispatch; no reactor).

import std/syncio
import std/opt   # before-middleware short-circuit signal (dispatchFull tests)
import hashi/http/request
import hashi/http/router
import testkit
import fuzzkit
import std/strutils

proc h1(req: Request): Response {.nimcall, raises.} = newResponse(200, "h1")
proc h2(req: Request): Response {.nimcall, raises.} = newResponse(200, "h2")

proc reqOf(meth, target: string): Request =
  result = default(Request)
  result.httpMethod = meth
  result.target = target
  result.version = Http11

var r = default(Router)
r.get("/", h1)
r.get("/about", h2)
r.post("/submit", h1)

# ── match (exact method + path) ───────────────────────────────────────────
section "match"

block:
  check r.match("GET", "/") == 0, "GET / -> first route"
block:
  check r.match("GET", "/about") == 1, "GET /about -> second route"
block:
  check r.match("POST", "/submit") == 2, "POST /submit -> third route"
block:
  check r.match("GET", "/missing") == -1, "unknown path -> -1"
block:
  check r.match("POST", "/about") == -1, "method mismatch -> -1"
block:
  check r.match("get", "/") == -1, "method is case-sensitive"
block:
  check (default(Router)).match("GET", "/") == -1, "empty router -> -1"

# ── dispatch (calls the matched handler, else 404) ────────────────────────
section "dispatch"

block:
  let resp = r.dispatch(reqOf("GET", "/about"))
  check resp.status == 200, "matched dispatch -> handler status"
  check resp.body == "h2", "dispatch calls the correct handler"
block:
  let resp = r.dispatch(reqOf("POST", "/submit"))
  check resp.body == "h1", "POST dispatch -> correct handler"
block:
  let resp = r.dispatch(reqOf("DELETE", "/"))
  check resp.status == 405, "known path, wrong method -> 405"
block:
  let resp = r.dispatch(reqOf("GET", "/nope"))
  check resp.status == 404, "unknown path -> 404"
block:
  check r.match("GET", "/about?x=1&y=2") == 1, "query string ignored in match"

# ── HEAD falls back to the GET handler (RFC 9110 §9.1) ─────────────────────
section "dispatch — HEAD/GET"

block:
  # No HEAD route registered; HEAD should run the GET handler (body stripped
  # later by serialize, not here).
  let resp = r.dispatch(reqOf("HEAD", "/about"))
  check resp.status == 200, "HEAD falls back to GET handler -> 200"
  check resp.body == "h2", "HEAD runs the GET handler (body suppressed on the wire)"
block:
  let resp = r.dispatch(reqOf("HEAD", "/nope"))
  check resp.status == 404, "HEAD on unknown path -> 404"
block:
  # Path exists but only for POST: HEAD has no GET to fall back to -> 405.
  let resp = r.dispatch(reqOf("HEAD", "/submit"))
  check resp.status == 405, "HEAD with no GET handler -> 405"

# ── named params + wildcards ──────────────────────────────────────────────
section "match — params & wildcards"

var rp = default(Router)
rp.get("/users/:id", h1)            # 0
rp.get("/files/*", h2)              # 1  single-segment wildcard
rp.get("/static/**", h1)           # 2  catch-all
rp.get("/users/:id/posts/:pid", h2) # 3  multiple params

block:
  check rp.match("GET", "/users/42") == 0, ":id matches one segment"
block:
  check rp.match("GET", "/users") == -1, ":id requires a segment"
block:
  check rp.match("GET", "/users/42/extra") == -1, ":id does not span segments"
block:
  check rp.match("GET", "/files/x") == 1, "* matches one segment"
block:
  check rp.match("GET", "/files/x/y") == -1, "* is single-segment only"
block:
  check rp.match("GET", "/static/a/b/c") == 2, "** matches the remainder"
block:
  check rp.match("GET", "/static") == 2, "** matches zero remaining segments"
block:
  check rp.match("GET", "/users/7/posts/99") == 3, "multiple params match"

# ── param capture via dispatch ────────────────────────────────────────────
section "dispatch — param capture"

proc echoId(req: Request): Response {.nimcall, raises.} = newResponse(200, pathParam(req, "id"))
proc echoTwo(req: Request): Response {.nimcall, raises.} =
  newResponse(200, pathParam(req, "id") & "/" & pathParam(req, "pid"))

var rc = default(Router)
rc.get("/users/:id", echoId)
rc.get("/users/:id/posts/:pid", echoTwo)

block:
  let resp = rc.dispatch(reqOf("GET", "/users/99"))
  check resp.body == "99", "dispatch captures :id"
block:
  let resp = rc.dispatch(reqOf("GET", "/users/7/posts/42"))
  check resp.body == "7/42", "dispatch captures multiple params"
block:
  let resp = rc.dispatch(reqOf("GET", "/users/abc"))
  check pathParam(reqOf("GET", "/x"), "id") == "", "missing param -> empty string"

# ── verb helpers ──────────────────────────────────────────────────────────
section "verb helpers"

var rv = default(Router)
rv.put("/x", h1)
rv.delete("/x", h2)
rv.head("/x", h1)
rv.options("/x", h2)
rv.patch("/x", h1)

block:
  check rv.match("PUT", "/x") == 0, "put"
block:
  check rv.match("DELETE", "/x") == 1, "delete"
block:
  check rv.match("HEAD", "/x") == 2, "head"
block:
  check rv.match("OPTIONS", "/x") == 3, "options"
block:
  check rv.match("PATCH", "/x") == 4, "patch"

# ── error handling: a handler that raises an ErrorCode ─────────────────────
section "dispatch — error mapping"

proc raiseNotFound(req: Request): Response {.nimcall, raises.} = raise NameNotFound
proc raiseBadReq(req: Request): Response {.nimcall, raises.} = raise BadOperation
proc raiseFail(req: Request): Response {.nimcall, raises.} = raise Failure

var re = default(Router)
re.get("/nf", raiseNotFound)
re.get("/bad", raiseBadReq)
re.get("/boom", raiseFail)

block: check errorCodeToHttp(NameNotFound) == 404, "errorCodeToHttp NameNotFound -> 404"
block: check errorCodeToHttp(BadOperation) == 400, "errorCodeToHttp BadOperation -> 400"
block: check errorCodeToHttp(Failure) == 500, "errorCodeToHttp Failure -> 500"
block: check errorCodeToHttp(ValueError) == 500, "errorCodeToHttp unknown -> 500"
block:
  check re.dispatch(reqOf("GET", "/nf")).status == 404, "raise NameNotFound -> 404"
block:
  check re.dispatch(reqOf("GET", "/bad")).status == 400, "raise BadOperation -> 400"
block:
  check re.dispatch(reqOf("GET", "/boom")).status == 500, "raise Failure -> 500"

section "dispatch — custom error handler"
proc myErr(req: Request; e: ErrorCode): Response {.nimcall.} =
  newResponse(503, "custom error")
var rce = default(Router)
rce.get("/x", raiseFail)
rce.setErrorHandler(myErr)
block:
  let resp = rce.dispatch(reqOf("GET", "/x"))
  check resp.status == 503, "custom error handler sets status"
  check resp.body == "custom error", "custom error handler sets body"

section "dispatchFull — middleware chain"

proc passBefore(req: Request): Opt[Response] {.nimcall.} =
  ## Always falls through to the next middleware / handler.
  result = none[Response]()

proc gateBefore(req: Request): Opt[Response] {.nimcall.} =
  ## Short-circuits `/admin` with 401; everything else falls through.
  if req.target == "/admin": result = some(newResponse(401, "denied"))
  else: result = none[Response]()

proc addHdr(req: Request; resp: Response): Response {.nimcall.} =
  result = resp
  result.headers.add Header(name: "X-Test", value: "1")

proc hasHdr(resp: Response; name: string): bool =
  result = false
  var i = 0
  while i < resp.headers.len:
    if resp.headers[i].name == name: result = true
    i = i + 1

var rm = default(Router)
rm.get("/ok", h1)
rm.addBefore(passBefore)
rm.addBefore(gateBefore)
rm.addAfter(addHdr)

block:
  let resp = rm.dispatchFull(reqOf("GET", "/ok"))
  check resp.status == 200, "fall-through reaches the handler"
  check resp.body == "h1", "fall-through calls the matched handler"
  check hasHdr(resp, "X-Test"), "after-middleware runs on the handler response"
block:
  let resp = rm.dispatchFull(reqOf("GET", "/admin"))
  check resp.status == 401, "before-middleware short-circuits dispatch"
  check resp.body == "denied", "short-circuit response is used"
  check hasHdr(resp, "X-Test"), "after-middleware runs on a short-circuit too"
block:
  var plain = default(Router)
  plain.get("/ok", h1)
  check plain.dispatchFull(reqOf("GET", "/ok")).status == 200,
        "no middleware -> plain dispatch (handler)"
  check plain.dispatchFull(reqOf("GET", "/nope")).status == 404,
        "no middleware -> plain dispatch (404)"

# ── route: dispatchFull on a request the caller owns ──────────────────────
section "route"

proc paramCount(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "params=" & $req.pathParams.len)

block:
  var rr = default(Router)
  rr.get("/", h1)
  rr.get("/user/:id", echoId)
  rr.setNotFound(paramCount)
  var mismatches = 0
  for t in ["/", "/user/7", "/user/abc", "/missing", "/user"]:
    for m in ["GET", "HEAD", "POST"]:
      var owned = reqOf(m, t)
      let a = route(rr, owned)
      let b = dispatchFull(rr, reqOf(m, t))
      if a.status != b.status or a.body != b.body: inc mismatches
  check mismatches == 0, "route and dispatchFull agree on every request"

block:
  # The driver reuses one Request per connection: a match's path params
  # must not leak into the next request's fallback.
  var rr = default(Router)
  rr.get("/user/:id", echoId)
  rr.setNotFound(paramCount)
  var req = reqOf("GET", "/user/42")
  check route(rr, req).body == "42", "the first request gets its param"
  req.target = "/nope"
  check route(rr, req).body == "params=0", "the next request's fallback sees none"

# ── matchRoute agrees with the segment-splitting matcher it replaced ────
section "matchRoute agrees with the reference matcher"

proc refTryMatch(pattern, path: seq[string]): (bool, seq[PathParam]) =
  var params: seq[PathParam] = @[]
  var i = 0
  var j = 0
  while true:
    if i >= pattern.len: return ((j >= path.len), params)
    let p = pattern[i]
    if p == "**": return (true, params)
    if j >= path.len: return (false, params)
    if p.len >= 1 and p[0] == ':':
      params.add PathParam(key: substr(p, 1), val: path[j])
    elif p == "*": discard
    elif p != path[j]: return (false, params)
    i = i + 1
    j = j + 1

proc refMatchRoute(r: Router; meth, target: string): MatchResult =
  result = MatchResult(found: false, methodMismatch: false, idx: -1, params: @[])
  let q = find(target, '?')
  let path = if q < 0: target else: substr(target, 0, q - 1)
  let pathSegs = splitSegments(path)
  for i in 0 ..< r.routes.len:
    let (ok, params) = refTryMatch(r.routes[i].segs, pathSegs)
    if ok:
      if r.routes[i].meth == meth:
        return MatchResult(found: true, methodMismatch: false, idx: i, params: params)
      result.methodMismatch = true

proc samePairs(a, b: seq[PathParam]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].key != b[i].key or a[i].val != b[i].val: return false
  result = true

proc pick(xs: openArray[string]): string = xs[rnd(xs.len)]

block:
  seedFuzz(0x3C6EF372FE94F82B'i64)
  const words = ["a", "b", "users", "x1", "", "?"]
  var mismatches = 0
  for it in 0 ..< 3000:
    var rr = default(Router)
    for k in 0 ..< 1 + rnd(4):
      var pat = ""
      for s in 0 ..< rnd(4):
        pat.add "/" & pick([":id", ":p" & $rnd(3), "*", "**", "a", "b", "users"])
      addRoute(rr, pick(["GET", "POST"]), (if pat.len == 0: "/" else: pat), h1)
    var target = ""
    for s in 0 ..< rnd(5):
      target.add pick(["/", "//", "/a", "/b", "/users", "/x1", "/" & randomAlnum(3)])
    if rnd(3) == 0: target.add "?" & pick(words) & "=" & randomAlnum(2)
    let meth = pick(["GET", "POST", "HEAD"])
    let a = matchRoute(rr, meth, target)
    let b = refMatchRoute(rr, meth, target)
    if a.found != b.found or a.methodMismatch != b.methodMismatch or a.idx != b.idx or
       not samePairs(a.params, b.params):
      inc mismatches
  check mismatches == 0, $mismatches & " mismatches in 3000 random routers and targets"

finish()

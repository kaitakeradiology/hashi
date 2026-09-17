## Routing demo: named path params, wildcards, the verb helpers, and the
## 405-vs-404 distinction. Register routes, then `serve`.

import hashi

proc home(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "home\n")

proc userById(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "user " & pathParam(req, "id") & "\n")

proc userPost(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "user " & pathParam(req, "id") &
                   " post " & pathParam(req, "pid") & "\n")

proc anyStatic(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "static: " & req.target & "\n")

proc created(req: Request): Response {.nimcall, raises.} =
  newResponse(201, "created\n")

proc whoami(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "you are " & req.remoteAddress & "\n")

proc search(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "q=" & req.queryParam("q") & "\n")

proc record(req: Request): Response {.nimcall, raises.} =
  ## Demonstrates raising an ErrorCode: only id "1" exists; anything else
  ## `raise NameNotFound`, which dispatch maps to 404 (server stays up).
  if pathParam(req, "id") != "1":
    raise NameNotFound
  newResponse(200, "record 1\n")

get("/", home)
get("/whoami", whoami)
get("/search", search)
get("/record/:id", record)
get("/users/:id", userById)
get("/users/:id/posts/:pid", userPost)
get("/static/**", anyStatic)
post("/users", created)

serve(8080'u16)

## Minimal hashi HTTP/1.1 server with routing + access logging.
import hashi

proc home(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "Hello, hashi\n")

proc about(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "hashi \xE6\xA9\x8B\n")

get("/", home)
get("/about", about)
serve(8080'u16)

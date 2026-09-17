## Raw-throughput bench: the production server path (router/dispatch/parse/
## serialize) with the per-request access log suppressed (logLevel=error) so the
## number reflects protocol throughput, not logging. No artificial delay.
import hashi

logLevel = error

proc root(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "abcdefghijklmnopqrstuvwxyz")

get("/", root)
serve(8080'u16)

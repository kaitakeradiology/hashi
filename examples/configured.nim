## Per-server configuration demo: override the size caps and the nodelay toggle,
## then `serve(port, config)`.

import hashi

proc upload(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "got " & $req.body.len & " bytes\n")

post("/upload", upload)

var cfg = defaultServerConfig()
cfg.maxBodySize = 16        # tiny body cap for the demo (default is 64 MiB)
cfg.tcpNoDelay = false      # show the toggle (default on)
serve(8080'u16, cfg)

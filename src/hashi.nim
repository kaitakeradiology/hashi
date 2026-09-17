## Hashi: an HTTP/1.1 and WebSocket server for Nimony, built on `.passive`
## procs over `std/ioring`'s worker pool.
##
## `import hashi` brings in the application-facing API:
##
## - `hashi/http/server`: `serve`, route registration, middleware, the
##   passive handler chain, secondary WebSocket listeners, trusted proxies
## - `hashi/http/request`: `Request`, `Response`, `newResponse`, accessors
## - `hashi/http/router`: matching semantics and the object-based router
## - `hashi/http/config`: `ServerConfig`
## - `hashi/http/multipart`: `multipart/form-data` parsing
## - `hashi/ws/session` and `hashi/ws/session_io`: the WebSocket handler API
## - `hashi/ws/outq` and `hashi/ws/outq_writer`: the optional outbound queue
## - `hashi/sse/session`: Server-Sent Events
## - `hashi/loop`: the loop lifecycle and raw `waitRead`/`waitWrite` for handlers that own
##   a socket
##
## Each module can also be imported on its own for a narrower surface. The
## internals (`hashi/net`, the frame codec, the protocol
## state machine, the connection registry, the access log) are imported here
## so that `doc/gen` documents them, but are not re-exported; import them
## explicitly if you need them.

import hashi/http/server
export server
import hashi/http/request
export request
import hashi/http/router
export router
import hashi/http/config
export config
import hashi/http/forwarded
export forwarded
import hashi/http/multipart
export multipart
import hashi/ws/session
export session
import hashi/ws/session_io
export session_io
import hashi/ws/outq
export outq
import hashi/ws/outq_writer
export outq_writer
import hashi/sse/session
export session
import hashi/loop
export loop
import hashi/log
export log

import hashi/http/connreg
import hashi/http/httplog
import hashi/ws/frame
import hashi/ws/protocol
import hashi/ws/handshake
import hashi/ws/outq_pacing
import hashi/net
import hashi/buffer

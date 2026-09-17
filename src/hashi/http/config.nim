## Per-server configuration: size limits, TCP keepalive, and the idle reaper.
##
## Set once via `serve(port, config)` (or `setServerConfig`) before the
## reactor starts; the connection driver and the WebSocket session layer read
## it from worker threads thereafter. Because it is set before `serve` and
## only read during serving, no lock is needed.
##
## Worker-thread count is not configured here: it is `std/threadpool`'s
## compile-time `WorkerCount`.

import hashi/http/request
import hashi/ws/frame
import hashi/ws/protocol

type
  ServerConfig* = object
    ## Limits and socket options applied by `serve`. See `defaultServerConfig`.
    maxRequestHead*: int   ## Max request-head bytes; exceeded → 431.
    maxBodySize*: int      ## Max request body (Content-Length and chunked); exceeded → 413/400.
    maxWsPayload*: int     ## Max single WebSocket frame payload; exceeded → protocol error.
    maxWsMessage*: int     ## Max assembled (fragmented) WebSocket message; exceeded → close 1009.
    tcpNoDelay*: bool      ## Disable Nagle on accepted sockets.
    # Kernel dead-peer detection, applied per accepted socket (all 0 = off).
    # When the kernel errors a dead peer, the connection driver's normal <=0
    # read unwind closes it — no reaper involvement. Write-stall / dead-peer
    # detection is deliberately the kernel's job, not an app-layer write
    # deadline: see `timedRead` in `hashi/http/server`.
    keepaliveIdleSec*: int   ## SO_KEEPALIVE + TCP_KEEPIDLE (s); 0 = keepalive off.
    keepaliveIntvlSec*: int  ## TCP_KEEPINTVL (s) between probes; 0 = kernel default.
    keepaliveCnt*: int       ## TCP_KEEPCNT probes before drop; 0 = kernel default.
    userTimeoutMs*: int      ## TCP_USER_TIMEOUT (ms): cap unacked data before reset; 0 = off.
    # Application-level idle reaper (0 = disabled): bounds a connection blocked
    # on a read with no inbound bytes, whether idle keep-alive between
    # requests or a slowloris sending nothing. Any inbound byte resets the
    # window, so only genuine silence is reaped. See `hashi/http/connreg`.
    idleTimeoutMs*: int      ## Max silence on a blocked read; 0 = off.
    reapIntervalMs*: int     ## Reaper sweep period; 0 means 1000 while `idleTimeoutMs` is set.

proc defaultServerConfig*(): ServerConfig =
  ## The built-in defaults: size limits from each layer's own consts, TCP
  ## keepalive and the idle reaper off.
  result = ServerConfig(maxRequestHead: MaxRequestHead,
                        maxBodySize: MaxBodySize,
                        maxWsPayload: MaxWsPayload,
                        maxWsMessage: MaxWsMessage,
                        tcpNoDelay: true,
                        keepaliveIdleSec: 0,
                        keepaliveIntvlSec: 0,
                        keepaliveCnt: 0,
                        userTimeoutMs: 0,
                        idleTimeoutMs: 0,
                        reapIntervalMs: 0)

var gServerConfig* = defaultServerConfig()
  ## The active config. Set before `serve`; read-only during serving.

proc setServerConfig*(c: ServerConfig) =
  ## Replace the active server config. Call before `serve`.
  gServerConfig = c

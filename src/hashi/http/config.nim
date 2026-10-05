## Per-server configuration: size limits, TCP keepalive, the idle reaper,
## the WebSocket keepalive and the lingering close after a rejection.
##
## Set once via `serve(port, config)` (or `setServerConfig`) before the
## reactor starts; the connection driver and the WebSocket session layer read
## it from worker threads thereafter. Because it is set before `serve` and
## only read during serving, no lock is needed.
##
## Worker-thread count is not configured here: `std/threadpool.initPool`
## sizes the pool at run time, one worker fewer than `countProcessors()`.
##
## `serve` refuses to start on a config `validateServerConfig` rejects.

import hashi/http/request
import hashi/ws/frame
import hashi/ws/protocol

type
  ServerConfig* = object
    ## Limits and socket options applied by `serve`. See `defaultServerConfig`.
    maxRequestHead*: int   ## Max request-head bytes, through the terminating
                           ## CRLFCRLF; exceeded → 431. A malformed head is 400
                           ## when its CRLFCRLF arrives by the read that crosses
                           ## the cap; past that the driver stops reading and
                           ## answers 431. Must be positive.
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
    userTimeoutMs*: int      ## TCP_USER_TIMEOUT (ms): reset a connection whose sent
                             ## data stays unacknowledged, or whose peer keeps a
                             ## zero window, this long; 0 = off. Applies to HTTP
                             ## and WebSocket connections alike.
    # Application-level idle reaper (0 = disabled): bounds an HTTP connection
    # blocked on a read with no inbound bytes, whether idle keep-alive between
    # requests or a slowloris sending nothing. Any inbound byte resets the
    # window, so only genuine silence is reaped. See `hashi/http/connreg`.
    # WebSocket reads are bounded by `wsIdleTimeoutMs` instead.
    idleTimeoutMs*: int      ## Max silence on a blocked HTTP read; 0 = off.
    reapIntervalMs*: int     ## Reaper sweep period; 0 means 1000 while `idleTimeoutMs`
                             ## or `wsIdleTimeoutMs` is set.
    maxInflightBytes*: int   ## Refuse new connections at this many bytes buffered
                             ## across all connections (see `hashi/http/connreg`);
                             ## 0 = no budget.
    # WebSocket keepalive, run by a `wsRecv` parked for inbound bytes. Both
    # clocks count from the last inbound byte only: a write succeeding proves
    # just that the kernel buffered it. See `recvMessage` in
    # `hashi/ws/session_io`.
    wsPingIntervalMs*: int   ## Send a PING after this much inbound silence, and
                             ## again each interval while it lasts; 0 = no pings.
    wsIdleTimeoutMs*: int    ## After this much inbound silence send CLOSE 1001 and
                             ## end the connection; 0 = never. At least twice
                             ## `wsPingIntervalMs` when both are set, so a peer
                             ## gets a ping before it can be closed.
    wsKeepalivePollMs*: int  ## Longest single keepalive wait, clamped to
                             ## 1..`MaxKeepalivePollMs` (<= 0 means the max).
                             ## Lowered only by tests that measure the timer heap.
    # Lingering close after a rejection the client may still be sending into
    # (413, 431, 426, 403, and a claimed upgrade or SSE request with bytes
    # behind it): the driver half-closes, then reads and discards so the
    # close is not a reset that loses the response. See `handleConn` in
    # `hashi/http/server`; `lingeringNow` in `hashi/http/connreg` counts
    # the connections doing it.
    lingerMs*: int           ## Longest a rejected connection lingers, in ms;
                             ## 0 = off: close at once. At most `MaxLingerMs`.
    lingerIdleMs*: int       ## Stop lingering once the client sends nothing for
                             ## this long, in ms. Positive and at most `lingerMs`
                             ## while lingering is on.

const MaxKeepalivePollMs* = 20_000
  ## Upper bound on one keepalive wait. Every wait is a ring poll with a
  ## deadline, and `std/ioring` drops a finished poll's timer entry only once
  ## it reaches the top of the lane's heap, so the heap holds every deadline
  ## armed within the longest wait still pending. Capping the wait caps the
  ## heap at roughly the poll rate times this, whatever the configured
  ## intervals.

const MaxLingerMs* = 60_000
  ## Upper bound on `ServerConfig.lingerMs`: a lingering connection holds an
  ## fd, so its life is capped like any other wait on a client.

proc defaultServerConfig*(): ServerConfig =
  ## The built-in defaults: size limits from each layer's own consts, the
  ## idle reaper and kernel dead-peer detection on (`TCP_USER_TIMEOUT`
  ## 60 s), a 1 GiB aggregate budget for bytes buffered across connections,
  ## and the WebSocket keepalive on: a PING after 20 s of inbound silence,
  ## CLOSE 1001 after 60 s, and a lingering close of up to 5 s (1 s of
  ## silence ends it) after a rejection.
  result = ServerConfig(maxRequestHead: MaxRequestHead,
                        maxBodySize: MaxBodySize,
                        maxWsPayload: MaxWsPayload,
                        maxWsMessage: MaxWsMessage,
                        tcpNoDelay: true,
                        keepaliveIdleSec: 60,
                        keepaliveIntvlSec: 10,
                        keepaliveCnt: 3,
                        userTimeoutMs: 60_000,
                        idleTimeoutMs: 30_000,
                        reapIntervalMs: 0,
                        maxInflightBytes: 1_073_741_824,
                        wsPingIntervalMs: 20_000,
                        wsIdleTimeoutMs: 60_000,
                        wsKeepalivePollMs: MaxKeepalivePollMs,
                        lingerMs: 5000,
                        lingerIdleMs: 1000)

proc validateServerConfig*(c: ServerConfig): string =
  ## "" when `c` is usable, else a one-line reason. Refuses a
  ## `maxRequestHead` that is not positive, a negative `maxInflightBytes`,
  ## `wsPingIntervalMs` or `wsIdleTimeoutMs`, a `wsIdleTimeoutMs` under twice
  ## `wsPingIntervalMs` when both are set, a `lingerMs` outside
  ## 0..`MaxLingerMs`, and, while `lingerMs` is set, a `lingerIdleMs` that is
  ## not positive or exceeds it.
  result = ""
  if c.maxRequestHead <= 0:
    result = "maxRequestHead must be positive (got " & $c.maxRequestHead & ")"
  elif c.maxInflightBytes < 0:
    result = "maxInflightBytes must not be negative (got " & $c.maxInflightBytes & ")"
  elif c.wsPingIntervalMs < 0:
    result = "wsPingIntervalMs must not be negative (got " & $c.wsPingIntervalMs & ")"
  elif c.wsIdleTimeoutMs < 0:
    result = "wsIdleTimeoutMs must not be negative (got " & $c.wsIdleTimeoutMs & ")"
  elif c.wsPingIntervalMs > 0 and c.wsIdleTimeoutMs > 0 and
       c.wsIdleTimeoutMs div 2 < c.wsPingIntervalMs:     # idle < 2 * ping, without overflow
    result = "wsIdleTimeoutMs (" & $c.wsIdleTimeoutMs &
             ") must be at least twice wsPingIntervalMs (" & $c.wsPingIntervalMs & ")"
  elif c.lingerMs < 0 or c.lingerMs > MaxLingerMs:
    result = "lingerMs must be between 0 and " & $MaxLingerMs & " (got " & $c.lingerMs & ")"
  elif c.lingerMs > 0 and c.lingerIdleMs <= 0:
    result = "lingerIdleMs must be positive while lingerMs is set (got " & $c.lingerIdleMs & ")"
  elif c.lingerMs > 0 and c.lingerIdleMs > c.lingerMs:
    result = "lingerIdleMs (" & $c.lingerIdleMs & ") must not exceed lingerMs (" &
             $c.lingerMs & ")"

var gServerConfig* = defaultServerConfig()
  ## The active config. Set before `serve`; read-only during serving.

proc setServerConfig*(c: ServerConfig) =
  ## Replace the active server config. Call before `serve`.
  gServerConfig = c

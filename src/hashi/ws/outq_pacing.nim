## Pacing knob for the outbound queue: bounds what the kernel will hold for
## one WebSocket connection.
##
## `hashi/ws/outq`'s STREAM-lane byte bound keeps most of the backlog in the
## queue, where lanes are meaningful, but the writer still pops and writes as
## fast as the socket accepts — so bytes also accumulate in the kernel send
## buffer, where they cannot be reordered. A control message that jumps the
## queue still waits behind whatever is already in `SO_SNDBUF`. `setWsSendBuf`
## caps that buffer so the residual wait stays small: too small and the link
## idles between writes, too large and lane prioritising stops mattering.
## `useOutQueue` applies `OutQueue.pacingBytes` through this proc at accept.

from std/posix/posix import SOL_SOCKET, SockLen

proc setsockopt(s, level, optname: cint; optval: pointer; optlen: SockLen): cint {.
  importc, header: "<sys/socket.h>".}

const
  SO_SNDBUFloc = 7.cint    ## Linux SOL_SOCKET/SO_SNDBUF.

proc setWsSendBuf*(fd: cint; bytes: int): bool =
  ## Cap `fd`'s socket send buffer at `bytes` and disable send-buffer
  ## autotuning for it. Returns false if `bytes <= 0` or the `setsockopt`
  ## call failed; callers should treat that as "pacing unavailable", not as
  ## fatal — an unpaced connection is slow-but-correct.
  ##
  ## Linux doubles the requested value for bookkeeping and enforces a floor
  ## of roughly 4608 bytes, so a later `getsockopt` will not echo back
  ## exactly what was set here.
  if bytes <= 0: return false
  var v = bytes.cint
  result = setsockopt(fd, SOL_SOCKET, SO_SNDBUFloc, addr v,
                      SockLen(sizeof(v))) == 0

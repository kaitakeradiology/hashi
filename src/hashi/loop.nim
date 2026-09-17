## The loop lifecycle and the `.passive` operations on a file descriptor.
##
## `std/ioring`'s worker pool is the scheduler; there is no hand-rolled
## event loop. `initLoop` brings up the pool and the ring, `spawnTask`
## starts a passive proc on the pool, and `runLoop` pumps completions on the
## calling thread until the pool is shut down. Both modules are re-exported,
## so `submit`, `shutdownPool`, `submitTimeout` and friends come with this
## one import.
##
## `waitAccept`, `waitRead` and `waitWrite` each submit their request
## together with the continuation and a pointer to `result`, which lives in
## the suspended frame. An ioring worker performs the syscall, writes the
## count through the pointer and resumes the continuation; idle workers
## block in the kernel.
##
## Continuations resume on the worker pool, not on one thread, so state
## shared between handlers needs a lock. Import this module from any handler
## that does raw socket I/O or needs a timer.

import hashi/buffer
import std/threadpool
export threadpool
import std/ioring
export ioring

when defined(posix):
  proc usleepMicroseconds(usec: cuint): cint {.importc: "usleep", header: "<unistd.h>".}
else:
  import std/windows/winlean

var gLoopUp = false

proc initLoop*() =
  ## Bring up the worker pool and the I/O ring. Idempotent.
  if gLoopUp: return
  initPool()
  initIoRing()
  gLoopUp = true

proc pumpIo*(timeoutMs = 0): bool {.discardable.} =
  ## Run the calling thread's share of completions, waiting up to
  ## `timeoutMs` for one. Returns whether anything was processed. The main
  ## thread must call this, or `runLoop`, for its own lane to progress.
  gReactor(timeoutMs)

proc runLoop*() =
  ## Pump completions until `shutdownPool` is called. `serve` calls this.
  while not stopped():
    if not pumpIo(100):
      when defined(posix):
        discard usleepMicroseconds(10_000)
      else:
        sleep(10)

template spawnTask*(call: untyped) =
  ## Start the passive proc call `call` on the pool and return at once.
  complete(delay(call))

proc sleepMs*(ms: int) {.passive.} =
  ## Suspend the calling passive proc for `ms` milliseconds. To run something
  ## periodically, resubmit from the callee:
  ## `discard submitTimeout(afterMs(1000), delay tick())`.
  let c = delay()
  discard submitTimeout(afterMs(ms), c)
  suspend()

proc waitAccept*(listenFd: cint): int {.passive.} =
  ## Suspend until a connection arrives; returns the new client fd (<0 err).
  result = -1
  let c = delay()
  discard submitAccept(listenFd, never, c, addr result)
  suspend()

proc waitRead*(fd: cint; buf: pointer; len: int): int {.passive.} =
  ## Suspend until the read completes; returns bytes read (0 = peer closed).
  result = -1
  let c = delay()
  discard submitRead(fd, buf, len, never, c, addr result)
  suspend()

proc waitWrite*(fd: cint; buf: pointer; len: int): int {.passive.} =
  ## Suspend until the write completes; returns bytes written.
  result = -1
  let c = delay()
  discard submitWrite(fd, buf, len, never, c, addr result)
  suspend()

proc writeAll*(fd: cint; data: string): bool {.passive.} =
  ## Write all of `data` to `fd`, handling short writes; false once the
  ## peer is gone. Copies through a fixed buffer, since a string is not
  ## addressable across a suspension.
  result = true
  var wbuf = default(array[4096, char])
  var off = 0
  var cont = true
  while off < data.len and cont:
    var clen = data.len - off
    if clen > 4096: clen = 4096
    copyOut(addr wbuf[0], data, off, clen)
    var wOff = 0
    while wOff < clen and cont:
      let w = waitWrite(fd, addr wbuf[wOff], clen - wOff)
      if w <= 0:
        result = false
        cont = false
      else:
        wOff = wOff + w
    off = off + clen

## The loop lifecycle and the `.passive` operations on a file descriptor.
##
## `std/ioring`'s worker pool is the scheduler; there is no hand-rolled
## event loop. `initLoop` brings up the pool and the ring, `spawnTask`
## starts a passive proc on the pool, and `runLoop` makes the calling thread
## one more worker until the pool is shut down. Both modules are re-exported,
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

when (defined(release) or defined(danger)) and not defined(windows):
  # A release build of a hashi program is optimised across modules: the
  # request path crosses many small procs in several modules, and link-time
  # optimisation inlines them. The flags reach every C unit and the link.
  {.passC: "-flto".}
  {.passL: "-flto".}

when defined(posix):
  from std/posix/posix import read, write, pcall, EAGAIN, EINTR, IOVec
  proc cWritev(fd: cint; iov: pointer; iovcnt: cint): int {.importc: "writev".}
    ## `iov` points at `IOVec`s, which have `struct iovec`'s layout.
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

proc workTurn*(): bool {.discardable.} =
  ## One worker's turn on the calling thread: run queued pool tasks, then
  ## drive this thread's lane, waiting up to 1 ms for a completion when there
  ## was no task to run. Returns whether tasks ran.
  result = poolHelp()
  let fired = pumpIo(if result: 0 else: 1)
  if not fired and not result and not gReactorWaits:
    when defined(posix):
      discard usleepMicroseconds(1_000)
    else:
      sleep(1)

proc runLoop*() =
  ## Take worker turns on the calling thread until `shutdownPool` is called,
  ## so the thread that runs the loop works alongside the pool rather than
  ## only waiting. `serve` calls this.
  while not stopped():
    workTurn()

template spawnTask*(call: untyped) =
  ## Start the passive proc call `call` on the pool and return at once.
  submit(delay(call))

proc sleepMs*(ms: int) {.passive.} =
  ## Suspend the calling passive proc for `ms` milliseconds. To run something
  ## periodically, resubmit from the callee:
  ## `discard submitTimeout(afterMs(1000), delay tick())`.
  let c = delay()
  discard submitTimeout(afterMs(ms), c)
  suspend()

proc yieldTask*() {.passive.} =
  ## Let the other queued tasks run before the caller continues: its
  ## continuation goes to the back of the pool's queue.
  let c = delay()
  submit(c)
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

const ReadLater* = -2
  ## `readNow`'s answer when nothing has arrived yet.

proc readNow*(fd: cint; buf: pointer; len: int): int =
  ## Read what has already arrived on the non-blocking `fd` into `buf`, up to
  ## `len` bytes, without waiting. Returns the bytes read, 0 when the peer
  ## has closed, -1 on an error, or `ReadLater` when nothing is there yet.
  ## Where there is no direct read (Windows) it always returns `ReadLater`.
  result = ReadLater
  when defined(posix):
    var done = false
    while not done:
      let n = pcall(read(fd, buf, len))
      if n >= 0:
        result = int(n)
        done = true
      elif n == -clong(EAGAIN): done = true
      elif n != -clong(EINTR):
        result = -1
        done = true

proc writeNow*(fd: cint; data: string; off: int): int =
  ## Write as much of `data[off ..]` to the non-blocking `fd` as the kernel
  ## takes without waiting. Returns the bytes written, 0 when it took none
  ## (a full socket buffer), or -1 on an error such as a closed peer. Where
  ## there is no direct write (Windows), it writes nothing and returns 0.
  result = 0
  when defined(posix):
    var done = false
    while not done and off + result < data.len:
      let n = pcall(write(fd, readRawData(data, off + result), data.len - off - result))
      if n > 0: result = result + int(n)
      elif n == -clong(EINTR): discard
      elif n == -clong(EAGAIN) or n == 0: done = true
      else:
        result = -1
        done = true

proc writevNow*(fd: cint; head: pointer; headLen: int; body: string): int =
  ## `writeNow` for the `headLen` bytes at `head` followed by `body`, sent
  ## with one gather write so the body is not copied behind the head.
  ## Returns the bytes of the two taken together, 0 when none, or -1 on an
  ## error. Where there is no direct write (Windows) it returns 0.
  result = 0
  when defined(posix):
    let total = headLen + body.len
    var done = false
    while not done and result < total:
      var iov {.noinit.}: array[2, IOVec]
      var cnt = 0
      if result < headLen:
        iov[0] = IOVec(iov_base: cast[pointer](cast[uint](head) + uint(result)),
                       iov_len: csize_t(headLen - result))
        cnt = 1
      let bodyOff = max(0, result - headLen)
      if bodyOff < body.len:
        iov[cnt] = IOVec(iov_base: readRawData(body, bodyOff),
                         iov_len: csize_t(body.len - bodyOff))
        cnt = cnt + 1
      let n = pcall(cWritev(fd, addr iov[0], cint(cnt)))
      if n > 0: result = result + int(n)
      elif n == -clong(EINTR): discard
      elif n == -clong(EAGAIN) or n == 0: done = true
      else:
        result = -1
        done = true

proc writeRest(fd: cint; data: string; start: int): bool {.passive.} =
  ## `writeAll` from `start` on, through the ring: copies through a fixed
  ## buffer, since a string is not addressable across a suspension.
  result = true
  var wbuf {.noinit.}: array[4096, char]
  var off = start
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

proc writeAll*(fd: cint; data: string): bool {.passive.} =
  ## Write all of `data` to `fd`, handling short writes; false once the
  ## peer is gone. What the socket buffer takes is written at once
  ## (`writeNow`); only the rest waits on the ring.
  let n = writeNow(fd, data, 0)
  if n < 0: result = false
  elif n == data.len: result = true
  else: result = writeRest(fd, data, n)

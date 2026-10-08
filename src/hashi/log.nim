## Logging: a level filter, one callback, and a stderr default.
##
## Every hashi log line goes through the installed callback. The default,
## `stderrLog`, formats a timestamped line and hands it to the kernel in one
## `write` call, so lines from concurrent worker threads stay whole. An
## application with its own logger installs it with `setLogCallback`; hashi
## then never touches stderr itself.
##
## `log` is a template: nothing below the level set by `setLogLevel` builds its
## message, so a filtered call costs one relaxed atomic load. When the compiler
## provides `instantiationInfo`, the callback receives the caller's file and
## line; otherwise it receives an empty file and line zero.

import std/[times, strutils, atomics]
when defined(posix):
  from std/posix/posix import write
else:
  import std/syncio

type
  LogLevel* {.pure.} = enum
    trace, debug, info, warn, error, critical

  LogCallback* = proc (level: LogLevel; file: string; line: int; msg: string) {.nimcall.}
    ## Receives every record that passes the level. `file` is the caller's
    ## source file as the compiler reports it, or "" when unknown.

var gLogLevel = ord(LogLevel.info)   # only through atomicLoad/atomicStore

proc setLogLevel*(level: LogLevel) =
  ## Drop records below `level` at the call site, before the message is
  ## built. The default is `info`. Safe from any thread.
  atomicStore(gLogLevel, ord(level), moRelaxed)

proc logEnabled*(level: LogLevel): bool =
  ## Whether a record at `level` passes the level set by `setLogLevel`.
  ord(level) >= atomicLoad(gLogLevel, moRelaxed)

const monthAbbrev = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc pad(s: var string; v, width: int) =
  let digits = $v
  var zeros = width - digits.len
  while zeros > 0:
    s.add '0'
    dec zeros
  s.add digits

proc addTimestamp(s: var string) =
  ## "MMM dd HH:mm:ss.fff", UTC, from the wall clock now.
  let t = getTime()
  let dt = utc(t)
  s.add monthAbbrev[int(dt.month) - 1]
  s.add ' '
  pad(s, dt.monthday.int, 2); s.add ' '
  pad(s, dt.hour.int, 2); s.add ':'
  pad(s, dt.minute.int, 2); s.add ':'
  pad(s, dt.second.int, 2); s.add '.'
  pad(s, t.nanosecond div 1_000_000, 3)

proc addSource(s: var string; file: string; line: int) =
  ## " (module:line)", with the module named without its `.nim` suffix.
  if file.len == 0: return
  var n = file.len
  if n > 4 and file[n-4] == '.' and file[n-3] == 'n' and file[n-2] == 'i' and
     file[n-1] == 'm':
    n = n - 4
  s.add " ("
  var i = 0
  while i < n:
    s.add file[i]
    inc i
  s.add ':'
  s.add $line
  s.add ')'

proc stderrLog*(level: LogLevel; file: string; line: int; msg: string) {.nimcall.} =
  ## The default callback: one formatted line to stderr per record, e.g.
  ## `Jun 05 04:25:40.658 INFO  (server:640) hashi http listening on 127.0.0.1:8080 (fd=5)`.
  var s = ""
  addTimestamp(s)
  s.add ' '
  let name = toUpperAscii($level)
  s.add name
  s.add repeat(' ', max(0, 5 - name.len))
  addSource(s, file, line)
  s.add ' '
  s.add msg
  s.add '\n'
  when defined(posix):
    var off = 0
    while off < s.len:
      let n = write(2.cint, cast[pointer](cast[int](toCString(s)) + off), s.len - off)
      if n <= 0: break
      off = off + n
  else:
    stderr.write(s)
    flushFile(stderr)

type CallbackBox = object
  cb: LogCallback

var gLogCallback: int
  ## Address of the installed `CallbackBox`, 0 for the stderr default. Only
  ## through atomicLoad/atomicStore. A box is never freed, so a worker mid-`emit`
  ## can outlive a replacement; a proc value cannot itself be stored atomically.

proc setLogCallback*(cb: LogCallback) =
  ## Route every record that passes the level to `cb` instead of stderr.
  ## Safe from any thread; install before `serve` so no record is missed.
  let box = cast[ptr CallbackBox](alloc0(sizeof(CallbackBox)))
  box[].cb = cb
  atomicStore(gLogCallback, cast[int](box), moRelease)

proc emit*(level: LogLevel; file: string; line: int; msg: string) =
  ## What the `log` template calls once a record has passed the level.
  let p = atomicLoad(gLogCallback, moAcquire)
  if p == 0:
    stderrLog(level, file, line, msg)
  else:
    let cb = cast[ptr CallbackBox](p)[].cb
    cb(level, file, line, msg)

template log*(level: LogLevel; msg: string) =
  ## Emit `msg` at `level` if it passes the level set by `setLogLevel`. `msg`
  ## is not evaluated otherwise.
  if logEnabled(level):
    when declared(instantiationInfo):
      let pos = instantiationInfo()
      emit(level, pos.filename, pos.line, msg)
    else:
      emit(level, "", 0, msg)

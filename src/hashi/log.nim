## Logging: a level filter, one callback, and a stderr default.
##
## Every hashi log line goes through `logCallback`. The default,
## `stderrLog`, formats a timestamped line and hands it to the kernel in one
## `write` call, so lines from concurrent worker threads stay whole. An
## application with its own logger installs it with `setLogCallback`; hashi
## then never touches stderr itself.
##
## `log` is a template: nothing below `logLevel` builds its message, so a
## filtered call costs one comparison. When the compiler provides
## `instantiationInfo`, the callback receives the caller's file and line;
## otherwise it receives an empty file and line zero.

import std/[times, strutils]
when defined(posix):
  from std/posix/posix import write
else:
  import std/syncio

type
  LogLevel* {.pure.} = enum
    trace, debug, info, warn, error, critical

  LogCallback* = proc (level: LogLevel; file: string; line: int; msg: string) {.nimcall.}
    ## Receives every record that passes `logLevel`. `file` is the caller's
    ## source file as the compiler reports it, or "" when unknown.

var logLevel* = LogLevel.info
  ## Records below this level are dropped at the call site, before the
  ## message is built.

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
  ## The default callback: one formatted line to stderr per record,
  ## e.g. `Jun 05 04:25:40.658 INFO  (server:726) hashi http listening on :8080`.
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

var logCallback: LogCallback = stderrLog

proc setLogCallback*(cb: LogCallback) =
  ## Route every record that passes `logLevel` to `cb` instead of stderr.
  ## Install before `serve`; the server's worker threads read it without a
  ## lock.
  logCallback = cb

template log*(level: LogLevel; msg: string) =
  ## Emit `msg` at `level` if it passes `logLevel`. `msg` is not evaluated
  ## otherwise.
  if level >= logLevel:
    when declared(instantiationInfo):
      let pos = instantiationInfo()
      logCallback(level, pos.filename, pos.line, msg)
    else:
      logCallback(level, "", 0, msg)

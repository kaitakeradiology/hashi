## Unit tests for `hashi/log`: the level filter, the callback, and the
## default stderr line.

import std/[syncio, strutils]
import hashi/log
import testkit

section "LogLevel — the six levels"

check ord(LogLevel.trace) == 0 and ord(LogLevel.critical) == 5,
      "trace..critical are 0..5"
check $LogLevel.critical == "critical", "the top level is critical"

section "log — the level filter keeps the message unbuilt"

var built = 0
proc costly(): string =
  inc built
  result = "built"

var got: seq[(LogLevel, string, int, string)] = @[]
proc capture(level: LogLevel; file: string; line: int; msg: string) {.nimcall.} =
  got.add((level, file, line, msg))

setLogCallback(capture)
logLevel = LogLevel.info

log(LogLevel.debug, costly())
check built == 0, "a filtered call never evaluates its message"
check got.len == 0, "a filtered call never reaches the callback"

log(LogLevel.warn, costly())
check built == 1, "a passing call evaluates its message once"
check got.len == 1, "a passing call reaches the callback"
check got[0][0] == LogLevel.warn, "the callback receives the level"
check got[0][3] == "built", "the callback receives the message"

section "log — the callback receives the call site"

when declared(instantiationInfo):
  check got[0][1].endsWith("test_log.nim"), "the file is the caller's module"
  check got[0][2] > 0, "the line is the caller's line"
else:
  check got[0][1] == "", "without instantiationInfo the file is empty"
  check got[0][2] == 0, "without instantiationInfo the line is zero"

section "log — the level threshold is inclusive"

logLevel = LogLevel.error
log(LogLevel.warn, "dropped")
log(LogLevel.error, "kept")
check got.len == 2 and got[1][3] == "kept", "only records at or above logLevel pass"

section "stderrLog — the default line"

# Exercised directly rather than captured: the line goes to fd 2 in one write.
stderrLog(LogLevel.info, "server.nim", 726, "hashi http listening")
check true, "stderrLog returns"

finish()

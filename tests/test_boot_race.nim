## `publish` racing `sealBootConfig`: every publish lands before the seal or is
## refused. None succeeds after it.
##
## An aborting refusal would end the process, so the test turns on the
## `bootprobe` hook (refusals are counted, nothing is stored) and runs each
## round in a child process: this binary re-run with `child`, because the seal
## is one-way. In a child, two pool workers publish in a loop while main seals,
## reads the value the instant the seal returns, lets the publishers run into
## the seal, and checks the value did not move. A publish whose check passed
## just before the seal and whose store came after it would move it. The window
## is a few instructions wide, so a round only sometimes catches a broken
## `bootcfg`; the rounds make it likely, not certain.
import std/[syncio, cmdline, atomics]
import hashi/bootcfg
import hashi/private/bootprobe
import hashi/loop
import testkit

proc cSystem(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
proc cUsleep(us: cuint): cint {.importc: "usleep", header: "<unistd.h>".}
proc cSysconf(name: cint): clong {.importc: "sysconf", header: "<unistd.h>".}

const Publishers = 2
const Rounds = 60
const ScNprocessorsOnln = 84.cint   ## _SC_NPROCESSORS_ONLN on Linux

var gFr: Frozen[int]
var gStarted: int   # accessed atomically
var gStop: bool     # accessed atomically

proc publisher() {.passive.} =
  discard atomicFetchAdd(gStarted, 1, moAcquireRelease)
  var i = 1
  while not atomicLoad(gStop, moAcquire):
    publish(gFr, i)
    i = i + 1
    if i mod 64 == 0: yieldTask()   # lets the pool start the other publisher

proc child(): int =
  discard cAlarm(30)
  countLateRefusals()
  initLoop()
  var n = 0
  while n < Publishers:
    spawnTask publisher()
    n = n + 1
  var waited = 0
  while atomicLoad(gStarted, moAcquire) < Publishers and waited < 2000:
    discard cUsleep(1000)
    waited = waited + 1
  if atomicLoad(gStarted, moAcquire) < Publishers: return 2
  discard cUsleep(uint32(200 + (waited * 37) mod 300))
  sealBootConfig()
  let atSeal = snapshot(gFr)
  waited = 0
  while lateRefusals() < Publishers and waited < 2000:
    discard cUsleep(1000)
    waited = waited + 1
  atomicStore(gStop, true, moRelease)
  discard cUsleep(2000)
  if lateRefusals() == 0: return 2           # the publishers never reached the seal
  if snapshot(gFr) != atSeal: return 1       # a publish succeeded after the seal
  result = 0

if paramCount() >= 1 and paramStr(1) == "child":
  quit(child())

section "publish racing the seal"
if cSysconf(ScNprocessorsOnln) < 3:
  writeLine(stderr, "SKIPPED test_boot_race: needs 3 processors (this is NOT a pass)")
  quit(0)
var slips = 0
var broken = 0
var r = 0
while r < Rounds:
  var cmd = paramStr(0) & " child"
  let w = (int(cSystem(toCString(cmd))) shr 8) and 0xff
  if w == 1: slips = slips + 1
  elif w != 0: broken = broken + 1
  r = r + 1
check broken == 0, "every round ran to its end (" & $broken & " did not)"
check slips == 0, "no publish succeeded after the seal (" & $slips & " of " & $Rounds & " rounds)"
finish()

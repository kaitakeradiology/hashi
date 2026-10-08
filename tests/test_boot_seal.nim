## A registration after the boot config is sealed aborts the process.
##
## `serve` seals the registries before it accepts, so a route, handler or
## setting registered later would race the workers; it must fail loudly instead
## (FATAL on fd 2, then abort). Each case runs in a child process, the test
## binary re-run with a mode argument: one registers after `sealBootConfig()`,
## one registers from the boot task of a real `serve`.
import std/[syncio, cmdline, strutils]
from std/posix/posix import close
import hashi
import hashi/bootcfg
import hashi/net
import testkit

proc cSystem(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}
proc cGetpid(): cint {.importc: "getpid", header: "<unistd.h>".}
proc cUnlink(path: cstring): cint {.importc: "unlink", header: "<unistd.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}

proc late(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "late")

proc lateRoute() {.passive.} =
  ## Runs on the reactor once `serve` is listening, i.e. after the seal.
  get("/late", late)

proc childAfterSeal() =
  get("/early", late)            # before the seal: fine
  sealBootConfig()
  get("/late", late)             # aborts
  quit(0)

proc childServe() =
  let lr = tryListenTcp(0'u16, bindAddr = "127.0.0.1")
  let port = boundPort(lr.fd)
  discard close(lr.fd)
  setBootTask(lateRoute)
  serve(port, bindAddr = "127.0.0.1")

proc runChild(mode: string): (int, string) =
  ## The child's exit status as a shell reports it (128 + signal), and its stderr.
  var err = "/tmp/hashi_seal_" & $cGetpid().int & "_" & mode & ".err"
  var cmd = paramStr(0) & " " & mode & " 2>" & err & "; exit $?"
  let w = int(cSystem(toCString(cmd)))
  var text = ""
  try:
    text = readFile(err)
  except:
    discard
  discard cUnlink(toCString(err))
  result = ((w shr 8) and 0xff, text)

if paramCount() >= 1:
  discard cAlarm(30)             # a child that neither aborts nor exits must not hang the suite
  if paramStr(1) == "after-seal": childAfterSeal()
  elif paramStr(1) == "serve": childServe()
  quit(2)

section "registration after the seal"
check not bootConfigSealed(), "nothing is sealed in a fresh process"
let direct = runChild("after-seal")
check direct[0] == 134, "a route registered after sealBootConfig aborts (exit " & $direct[0] & ")"
check "FATAL" in direct[1], "and says so on stderr"
let served = runChild("serve")
check served[0] == 134, "a route registered once serve is listening aborts (exit " & $served[0] & ")"
check "FATAL" in served[1], "and says so on stderr"

finish()

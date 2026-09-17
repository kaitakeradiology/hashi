## Minimal test harness for hashi under Nimony.
##
## Nimony has no Testament/Atlas (those are Nim 2 tooling), so tests are
## plain programs run via `../nimony/bin/nimony c -r tests/test_*.nim`.
## Each test file imports this kit, calls `check`/`section`, and ends with
## `quit(testSummary())` so a non-zero exit marks failure for the runner.
##
## Usage:
##   import testkit
##   section "request line"
##   check parseRequestHead(req, r) == psOk, "GET parses"
##   finish()   # prints the tally and exits non-zero if anything failed
##
## Divergence from nimony's own conventions (reviewed, kept deliberately):
## nimony's tests use plain `std/assertions` `assert` plus golden `.output`
## files diffed by a Nim `tester.nim`. We keep this bespoke kit instead because
## `check` **continues on failure and reports every failing case + a tally** —
## the right ergonomics for conformance tables (the RFC-6455 case set, fuzz
## invariants) where `assert`'s abort-at-first-failure would hide the rest.
## The kit is intentionally tiny; `tests/run` (bash) aggregates by exit code,
## matching nimony's model. Migration trigger: when we need golden-output
## capture for exact wire bytes / parsed dumps at scale, adopt nimony's
## `.output` + `--overwrite` infra (a Nim `tester.nim`) and fold `check` into
## it — until then this stays.

import std/[syncio, envvars, terminal]

# Colour iff stdout is a terminal and NO_COLOR is unset (https://no-color.org),
# decided once at load.
let hkColor = isatty(stdout) and not existsEnv("NO_COLOR")

proc paint(s: string; fg: ForegroundColor; bright = false; bold = false): string =
  ## Wrap `s` in an SGR colour escape (reset after) when colour is enabled.
  if not hkColor: return s
  result = ansiForegroundColorCode(fg, bright)
  if bold: result.add ansiStyleCode(styleBright)
  result.add s
  result.add ansiStyleCode(0)

var
  hkPassed = 0
  hkFailed = 0
  hkSecPassed = 0
  hkSecFailed = 0
  hkSection = ""

proc rollUp() =
  ## Emit the just-finished section's tally (green if clean, red if any failed).
  if hkSection.len == 0: return
  let total = hkSecPassed + hkSecFailed
  if hkSecFailed == 0:
    echo "   ", paint("✓ " & $hkSecPassed & "/" & $total, fgGreen),
         " ", paint(hkSection, fgBlack, bright = true)
  else:
    echo "   ", paint("✗ " & $hkSecPassed & "/" & $total & " (" &
         $hkSecFailed & " failed)", fgRed, bold = true), " ", paint(hkSection, fgBlack, bright = true)

proc section*(name: string) =
  ## Start a named group: roll up the previous one, then print a header. Checks
  ## that follow are tallied under it and printed live as they run.
  rollUp()
  hkSecPassed = 0
  hkSecFailed = 0
  hkSection = name
  echo ""
  echo paint("── " & name, fgCyan, bold = true)

template check*(cond: bool; msg: string) =
  ## Record + print one assertion live. Keeps going on failure so one run
  ## reports every failing case, not just the first.
  if cond:
    hkPassed = hkPassed + 1
    hkSecPassed = hkSecPassed + 1
    echo "  ", paint("✓", fgGreen), " ", msg
  else:
    hkFailed = hkFailed + 1
    hkSecFailed = hkSecFailed + 1
    echo "  ", paint("✗ FAIL", fgRed, bold = true), " ", paint(msg, fgRed, bright = true)

proc finish*() {.noreturn.} =
  ## Roll up the last section, print the overall tally, and exit: 0 if every
  ## check passed, 1 if any failed (the runner treats non-zero as failure).
  rollUp()
  echo ""
  let total = hkPassed + hkFailed
  if hkFailed > 0:
    echo paint("✗ " & $hkFailed & " failed", fgRed, bold = true),
         ", ", $hkPassed, " passed of ", $total
    quit(1)
  else:
    echo paint("✓ all " & $total & " passed", fgGreen, bold = true)
    quit(0)

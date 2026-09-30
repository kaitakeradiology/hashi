#!/usr/bin/env python3
"""Gate on an Autobahn fuzzingclient report.

Reads reports/index.json (or the path given), prints the tally, and exits 1
if any case failed: a behaviour other than OK, NON-STRICT, INFORMATIONAL or
UNIMPLEMENTED (permessage-deflate, which hashi does not offer), or a close
behaviour other than OK or INFORMATIONAL.
"""
import collections
import json
import pathlib
import sys

PASSING = {"OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED"}
PASSING_CLOSE = {"OK", "INFORMATIONAL"}

here = pathlib.Path(__file__).resolve().parent
path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here / "reports" / "index.json"
report = json.loads(path.read_text())

failed = False
for agent, cases in report.items():
    tally = collections.Counter(c["behavior"] for c in cases.values())
    print(f"{agent}: {len(cases)} cases, " + ", ".join(f"{k} {v}" for k, v in sorted(tally.items())))
    for case_id, c in sorted(cases.items()):
        if c["behavior"] not in PASSING or c["behaviorClose"] not in PASSING_CLOSE:
            print(f"  FAIL {case_id}: {c['behavior']} / close {c['behaviorClose']}")
            failed = True

if not report:
    print("no agent in the report")
    failed = True
sys.exit(1 if failed else 0)

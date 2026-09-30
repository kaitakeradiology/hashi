#!/usr/bin/env bash
# Run the Autobahn WebSocket conformance suite against the hashi echo server.
#
# Prereq (one-time): a container runtime + the Autobahn image, e.g.
#   docker pull crossbario/autobahn-testsuite
# (or `podman pull docker.io/crossbario/autobahn-testsuite`).
#
# Usage:
#   ../nimony/bin/nimony c examples/hello.nim     # build the server
#   nimcache/.../hello &                          # run it on :8080
#   tests/conformance/autobahn/run.sh                        # then open reports/index.html
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/reports"
RUNTIME="${RUNTIME:-docker}"   # set RUNTIME=podman to use podman

TTY=""
[ -t 0 ] && [ -t 1 ] && TTY="-it"   # interactive only; CI has no terminal

"$RUNTIME" run $TTY --rm --network host \
  -v "$HERE/fuzzingclient.json:/config/fuzzingclient.json:ro" \
  -v "$HERE/reports:/reports" \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

echo "Report: $HERE/reports/index.html"
python3 "$HERE/check.py" "$HERE/reports/index.json"

#!/usr/bin/env bash
# hashi vs Mummy benchmark driver (see doc/benchmarks.md).
#
#   bench/run.sh
#
# Builds both servers, runs wrk at -c100 and -c1000, prints req/s + latency.
# Needs: wrk, a Nim 2 `nim` (for Mummy), the nimony compiler, and a Mummy
# checkout. Override paths via env: NIMONY, MUMMY, PORT, DUR.
set -u
cd "$(dirname "$0")/.." || exit 2

# Nimony compiler resolution (same convention as tests/run):
# NIMONY= override, else the sibling checkout, else `nimony` on PATH.
if [ -z "${NIMONY:-}" ]; then
  if [ -x ../nimony/bin/nimony ]; then
    NIMONY=../nimony/bin/nimony
  elif command -v nimony >/dev/null; then
    NIMONY=$(command -v nimony)
  fi
fi
NIMONY="${NIMONY:-../nimony/bin/nimony}"
MUMMY="${MUMMY:-$HOME/Projects/Develop/mummy}"
PORT="${PORT:-8080}"
URL="http://127.0.0.1:$PORT/"
DUR="${DUR:-10s}"

command -v wrk >/dev/null || { echo "wrk not found"; exit 2; }
[ -x "$NIMONY" ] || { echo "nimony not found at $NIMONY"; exit 2; }
[ -d "$MUMMY" ] || { echo "mummy checkout not found at $MUMMY"; exit 2; }

free_port() { ! ss -ltn 2>/dev/null | grep -q ":$PORT "; }
wait_up()   { for _ in $(seq 1 20); do curl -fsS -m1 -o /dev/null "$URL" 2>/dev/null && return 0; sleep 0.3; done; return 1; }
# Stop a server by EXACT process name (pkill -f would match this script — its
# command line contains the names — and kill the runner itself).
stop()      { pkill -x "$1" 2>/dev/null; sleep 1; }

bench() { # name url
  echo "  -c100 :"; wrk -t10 -c100  -d"$DUR" --latency "$2" 2>&1 | grep -E "Requests/sec|Latency "
  echo "  -c1000:"; wrk -t10 -c1000 -d"$DUR" --latency "$2" 2>&1 | grep -E "Requests/sec|Latency "
}

echo "== building =="
# Both sides in release: Mummy is built -d:release below, and nimony's default
# is -O1, so an unflagged hashi build would compare a debug binary against an
# optimised one.
$NIMONY c -d:release bench/bench_server.nim   >/tmp/h_delay.log 2>&1 || { echo "hashi delay build failed"; exit 1; }
$NIMONY c -d:release examples/bench_raw.nim    >/tmp/h_raw.log   2>&1 || { echo "hashi raw build failed"; exit 1; }
H_DELAY=$(find nimcache -name bench_server -type f | head -1)
H_RAW=$(find nimcache -name bench_raw -type f | head -1)
( cd "$MUMMY" && nim c --mm:orc --threads:on -d:release --path:src -o:/tmp/wrk_mummy tests/wrk_mummy.nim ) >/tmp/m.log 2>&1 \
  || { echo "mummy build failed"; exit 1; }
# Mummy without the 10 ms sleep: the raw counterpart of examples/bench_raw.nim.
sed 's/^        sleep(10)$//' "$MUMMY/tests/wrk_mummy.nim" > /tmp/wrk_mummy_raw.nim
( cd "$MUMMY" && nim c --mm:orc --threads:on -d:release --path:src --path:tests -o:/tmp/wrk_mummy_raw /tmp/wrk_mummy_raw.nim ) >/tmp/m_raw.log 2>&1 \
  || { echo "mummy raw build failed"; exit 1; }

run_one() { # label binary
  free_port || { echo "port $PORT busy"; return 1; }
  "$2" >/tmp/bench_srv.log 2>&1 &
  local pid=$!
  wait_up || { echo "$1 did not come up"; kill "$pid" 2>/dev/null; return 1; }
  echo "== $1 =="; bench "$1" "$URL"
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 1
}

run_one "Mummy (sleep 10ms, 100 threads)" /tmp/wrk_mummy
run_one "hashi (async 10ms sleepMs park)" "$H_DELAY"
# raw (no delay): the production router/dispatch path
run_one "Mummy raw (no delay, 100 threads)" /tmp/wrk_mummy_raw
run_one "hashi raw (no delay, prod path)" "$H_RAW"

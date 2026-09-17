# bench/ — hashi vs Mummy

Reproducible throughput / concurrency-under-latency benchmark. Results and
analysis live in [doc/benchmarks.md](../doc/benchmarks.md); this is the runner.

## Run

```bash
bench/run.sh          # builds both servers, runs wrk at -c100 and -c1000
```

Needs `wrk`, a Nim 2 `nim` (for Mummy), the nimony compiler, and a Mummy
checkout. Override via env: `NIMONY=…`, `MUMMY=…`, `PORT=…`, `DUR=…`.

## Servers

| | source | workload |
|---|---|---|
| Mummy | `$MUMMY/tests/wrk_mummy.nim` | `sleep(10)` + 26-byte body, `workerThreads=100` |
| hashi (delay) | `bench/bench_server.nim` | async 10 ms (`sleepMs`, parked on the ring timer) + 26 bytes |
| hashi (raw) | `examples/bench_raw.nim` | production router/dispatch path, no delay, access log off |

## Headline (Jun 7 2026, unpinned toolchain)

| Workload | Mummy | hashi |
|---|---|---|
| Raw, `-c100` | 206k req/s | **515k req/s** (2.5×) |
| 10 ms, `-c100` | 9.8k @ 10 ms | 9.9k @ 10 ms (parity — connection-bound) |
| 10 ms, **`-c1000`** | 9.9k @ **96 ms** | **55.8k @ 11.9 ms** (5.6× tput, ~8× latency) |

The `-c100` 10 ms test is connection-bound (100 conns × 1 in-flight × 10 ms ≈
10k/s for anyone). `-c1000` is where the concurrency models diverge: Mummy's 100
threads saturate and the rest queue; hashi parks one cheap continuation per
request.

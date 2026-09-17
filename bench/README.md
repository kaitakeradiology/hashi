# bench/ — hashi vs Mummy vs cps-http

Reproducible throughput / concurrency-under-latency benchmark. Results and
method live in [doc/benchmarks.md](../doc/benchmarks.md); this is the runner.

## Run

```bash
bench/run.sh          # builds the hashi and Mummy servers, runs wrk at -c100 and -c1000
```

Needs `wrk`, a Nim 2 `nim` (for Mummy), the nimony compiler, and a Mummy
checkout. Override via env: `NIMONY=…`, `MUMMY=…`, `PORT=…`, `DUR=…`.

## Servers

| | source | workload |
|---|---|---|
| Mummy | `$MUMMY/tests/wrk_mummy.nim` | `sleep(10)` + 26-byte body, `workerThreads=100` |
| hashi (delay) | `bench/bench_server.nim` | async 10 ms (`sleepMs`, parked on the ring timer) + 26 bytes |
| hashi (raw) | `examples/bench_raw.nim` | production router/dispatch path, no delay, access log off |
| cps-http (delay) | `bench/cps_delay.nim` | `await cpsSleep(10)` + 26 bytes, multi-thread runtime; built by hand, see doc/benchmarks.md |
| cps-http (raw) | `bench/cps_raw.nim` | no delay, multi-thread runtime; built by hand |

## Headline (18 September 2026)

| Workload | Mummy | cps-http | hashi |
|---|---|---|---|
| Raw, `-c100` | 91.8k req/s | 95.6k req/s | **276k req/s** |
| 10 ms, `-c100` | 9.5k @ 10.5 ms | 9.8k @ 10.1 ms | 9.9k @ 10.05 ms |
| 10 ms, `-c1000` | 9.7k @ 97.7 ms | 71.4k @ 14.0 ms | **95.1k @ 10.2 ms** |

The `-c100` 10 ms test is connection-bound (100 conns × 1 in-flight × 10 ms ≈
10k/s for anyone). `-c1000` is where the concurrency models diverge: a fixed
thread pool serves its pool's worth and queues the rest; a continuation-based
server parks one cheap continuation per request.

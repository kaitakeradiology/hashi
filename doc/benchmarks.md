# Benchmarks — hashi vs Mummy (Jun 6 2026; re-confirmed Jun 7 on the unpinned toolchain)

Throughput for the Phase-1 HTTP/1.1 server. Two reactor generations measured:
the original **busy-poll dispatcher** and the **workers-resume** scheduler
(continuations resumed directly on `std/ioring`'s worker pool — no hand-rolled
loop). The workers-resume reactor
is the current design and the headline below.

## Method

- Load: `wrk -t10 -c100 -d10s http://127.0.0.1:8080/` (the standard Mummy
  benchmark invocation), plus a `-c1000` high-concurrency run.
- **Mummy**: `tests/wrk_mummy.nim`, the canonical benchmark server, built
  `nim c --mm:orc --threads:on -d:release` — `workerThreads = 100`, handler
  does `sleep(10)` (≈10 ms work) and returns a 26-byte body.
- **hashi**: `bench/bench_server.nim` on `src/hashi/http/`, built
  `../nimony/bin/nimony c -d:release`. Handler-equivalent does an **async**
  10 ms delay (`sleepMs`, a continuation parked on the ring's timer — the
  CPS analogue of Mummy's blocking `sleep(10)`), returns 26 bytes.
- A **raw** variant (no delay) measures pure request/response throughput.
- Same box, loopback.

## Refresh — Sep 16 2026

Rerun with `bench/run.sh` after the September cleanup (bulk copies on
the I/O path, the delay side now `sleepMs` on ioring's `submitTimeout`
rather than a timerfd, both servers built in release). The box carried a
desktop load average near 10 on 16 cores during the run, so every absolute
figure, Mummy's included, is below the June ones; the same-session ratios
are the comparable numbers.

| Workload | Mummy | hashi | ratio |
|---|---|---|---|
| Raw (no delay), `-c100` | 90,874 req/s @ 1.10 ms | **267,163 req/s @ 0.47 ms** | **2.9×** |
| Raw (no delay), `-c1000` | 82,665 @ 17.9 ms | **242,313 @ 2.9 ms** | **2.9× tput, 6× latency** |
| 10 ms work, `-c100` | 9,651 @ 10.35 ms | 9,844 @ 10.13 ms | parity (connection-bound) |
| 10 ms work, **`-c1000`** | 9,826 @ **96 ms** | **93,920 @ 10.2 ms** | **9.6× tput, 9.4× latency** |

The `-c1000` 10 ms row is the one that moved: parking a thousand
continuations on the ring's own timer instead of a thousand timerfds
nearly doubles the throughput hashi reached in June, at the same latency
as `-c100`. `bench/run.sh` now also builds the Mummy raw variant, so the
raw ratio is measured in one session rather than against a remembered
figure. The A/B of the raw path before and after the alignment pass was
within noise on the same compiler; the pass cost nothing on the hot path.

## Refresh — Jun 7 2026

Re-ran the headline workloads after the reactor race fix. Confirms the
workers-resume column below; reproducible via `bench/run.sh`.

| Workload | Mummy | hashi | ratio |
|---|---|---|---|
| Raw (no delay), `-c100` | 206,529 req/s @ 0.52 ms | **515,284 req/s @ 0.22 ms** | **2.5×** |
| 10 ms work, `-c100` | 9,811 @ 10.13 ms | 9,885 @ 10.06 ms | parity (connection-bound) |
| 10 ms work, **`-c1000`** | 9,916 @ **96 ms** | **55,756 @ 11.9 ms** | **5.6× tput, ~8× latency** |

hashi: 8 ioring workers. Mummy:
`wrk_mummy.nim`, `workerThreads = 100`. Raw hashi side is the production server
path (`examples/bench_raw.nim`, access log at `error` so logging isn't measured);
delay side is `bench/bench_server.nim` (async timerfd park).

## Results (original Jun 6 run)

| Workload | Mummy | hashi (busy-poll) | hashi (workers-resume) |
|---|---|---|---|
| Raw (no delay), `-c100` | ~200,800 req/s | ~202,800 req/s | **~516,000 req/s** |
| 10 ms work, `-c100` (official) | 9,827 @ 10.1 ms | 9,856 @ 10.1 ms | 9,902 @ 10.1 ms |
| 10 ms work, **`-c1000`** | 9,923 @ 94 ms | 50,872 @ 19 ms | **50,008 @ ~13 ms** |
| **Idle CPU** (no traffic) | — | ~100% (1 core spun) | **~2%** |

- Threads at `-c100` (10 ms): Mummy ≈ 161; hashi ≈ 10.
- The workers-resume reactor parallelises across the worker pool, so it lifts
  raw throughput ~2.5× over the busy-poll dispatcher (which resumed on a
  single thread) **and** drops idle CPU from a spun core to ~nothing.

## Reading the numbers

- **Raw throughput: hashi ~2.6× Mummy** (~516k vs ~201k). The workers-resume
  reactor runs continuations across the whole pool; Mummy's per-request
  thread-pool handoff costs more. (The busy-poll reactor was at parity ~203k
  — single-threaded resume capped it.)
- **The official `-c100` 10 ms test is connection-limited.** 100 keep-alive
  connections, each serialized at one 10 ms request at a time, cap any server
  at ~100 × 100 = ~10k req/s. Everyone sits there; it doesn't separate the
  concurrency models.
- **`-c1000` is where the models diverge — ~5×.** Mummy's 100 worker threads
  saturate; the extra 900 connections queue (throughput stays ~10k, latency
  balloons to 94 ms). hashi parks 1000 timer continuations cheaply (no thread
  per request) → ~50k req/s. The CPS thesis: concurrency bounded by memory
  (one frame per parked request), not by a thread pool.
- **Idle CPU ~2%.** No hand-rolled poll loop — idle workers block in
  `epoll_wait`. (The busy-poll reactor spun a whole core at rest.)

## Caveats

1. **Per-request allocation.** The driver's byte copies are bulk now
   (`hashi/buffer`), but `serialize` still builds a fresh string per
   response that is copied again into the write buffer, and the head
   parser allocates a string per field. Both are headroom on raw
   throughput.
2. **Fixed handler.** Benchmarks a constant response (fine for throughput). The
   customizable handler seam is **done** (router + dispatch landed; the
   "proc-value bug" was the reactor race, now fixed) — `bench_raw.nim` runs the
   real router/dispatch path.
3. **Workers-resume ⇒ multi-threaded handlers.** Shared server state will need
   locks (the single-dispatcher no-locks property is gone).
4. Mummy is Nim 2 + a mature tuned server; hashi is days-old on Nimony.

## Takeaway

With the workers-resume scheduler, hashi **beats Mummy on both** raw
throughput (~2.6×) and concurrency-under-latency (~5× at `-c1000`), at ~2%
idle CPU and ~10 threads vs Mummy's ~161. The two enabling ioring fixes
(`resPtr` + fd-spread) are upstream. The `.passive`/CPS bet is validated on
performance, decisively.

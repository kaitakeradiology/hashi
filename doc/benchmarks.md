# Benchmarks

Plaintext HTTP/1.1 keep-alive throughput and concurrency under latency,
measured with `wrk` against three servers: hashi, [Mummy](https://github.com/guzba/mummy)
(Nim 2, a fixed pool of worker threads) and [cps-http](https://github.com/gabearro/cps-http)
(Nim 2, continuations from a `{.cps.}` macro on its own runtime). Mummy is
the server the Kaitake applications ran on before hashi; cps-http is the
nearest design to hashi's in the Nim ecosystem. The runner is
[`bench/run.sh`](../bench/run.sh).

## Method

- `wrk -t10 -c100 -d10s --latency http://127.0.0.1:8080/` (Mummy's own
  benchmark invocation) and the same at `-c1000`. Loopback, all servers
  in one session on a 16-core Linux box under light desktop load.
- Two workloads, each returning a 26-byte body:
  - **raw**: no work per request, so the number is the request/response
    path itself;
  - **10 ms work**: each request waits 10 ms before responding. Mummy
    blocks a worker thread (`sleep(10)`); hashi and cps-http park the
    continuation on a timer (`sleepMs(10)`, `await cpsSleep(10)`).
- Servers and builds:

| Server | Source | Build |
|---|---|---|
| hashi 0.1.0 | [`examples/bench_raw.nim`](../examples/bench_raw.nim), [`bench/bench_server.nim`](../bench/bench_server.nim) | `nimony c -d:release` |
| Mummy 0.4.8 | `tests/wrk_mummy.nim` in the Mummy repository, `workerThreads = 100`; the raw variant drops the `sleep(10)` | Nim 2.2.6, `--mm:orc --threads:on -d:release` |
| cps-http 2.0.2 | [`bench/cps_raw.nim`](../bench/cps_raw.nim), [`bench/cps_delay.nim`](../bench/cps_delay.nim), on its multi-thread runtime with a listener shard per core | Nim 2.2.6, its production recipe: `--mm:atomicArc --threads:on -d:danger --opt:speed --passC:-march=native --passC:-flto --passL:-flto` |

## Results — 18 September 2026

| Workload | Mummy | cps-http | hashi |
|---|---|---|---|
| Raw, `-c100` | 91,800 req/s, 1.09 ms | 95,600 req/s, 1.28 ms | 276,000 req/s, 0.49 ms |
| Raw, `-c1000` | 75,600 req/s, 24.4 ms | 78,100 req/s, 13.7 ms | 267,000 req/s, 2.55 ms |
| 10 ms work, `-c100` | 9,500 req/s, 10.5 ms | 9,800 req/s, 10.1 ms | 9,900 req/s, 10.05 ms |
| 10 ms work, `-c1000` | 9,700 req/s, 97.7 ms | 71,400 req/s, 14.0 ms | 95,100 req/s, 10.2 ms |

Latency is the mean. Threads under load: hashi 16, cps-http 17, Mummy
101. No socket errors or non-2xx responses on any run.

## Reading the numbers

- The `-c100` / 10 ms row is bounded by the client: 100 connections, one
  request in flight each, 10 ms per request is about 10,000 req/s for any
  server.
- The `-c1000` / 10 ms row is where the concurrency models separate. A
  pool of 100 threads serves 100 requests at a time and queues the rest,
  so throughput stays near 10,000 and latency grows with the queue. A
  server that parks each waiting request as a continuation is bounded by
  memory rather than by threads, and both hashi and cps-http serve the
  thousand connections at close to the 10 ms floor.
- The raw rows measure the cost of the request path with nothing to
  park. hashi's path is Nimony's compiler-native `.passive` transform
  resumed on `std/ioring`'s completion pool, with no event loop of its
  own; the difference between the two continuation-based servers here is
  the cost of the path, not of the model.
- cps-http was built with its own optimised production flags and sends a
  shorter response (`Content-Length` only, no `Date` or `Server` header),
  so the comparison does not favour hashi on either count.

## Reproducing

`bench/run.sh` builds and runs the hashi and Mummy servers; it needs
`wrk`, the Nimony compiler, a Nim 2 `nim` and a Mummy checkout. The
cps-http servers are built by hand with the flags above and the
cps-runtime, cps-tls, cps-quic, checksums and zippy sources on `--path`
(cps-http's own repository documents the layout). Nimony's default C
build is `-O1`; always benchmark hashi with `-d:release`.

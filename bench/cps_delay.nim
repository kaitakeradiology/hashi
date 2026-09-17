## cps-http counterpart of bench/bench_server.nim: GET / waits 10 ms on the
## runtime timer (await cpsSleep) and returns a 26-byte body. Its multi-thread
## runtime with one listener shard per core, as in cps-http's own
## benchmarks/bench_http_cps_mt_server.nim.
##
## Needs a Nim 2 toolchain and the cps-runtime, cps-tls, cps-quic, checksums
## and zippy sources on --path; the build flags are in doc/benchmarks.md.
import std/os
import cps/runtime
import cps/mt
import cps/http/server/dsl
import cps/http/server/server

proc startShard(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    let handler = router:
      get "/":
        await cpsSleep(10)
        respond 200, "abcdefghijklmnopqrstuvwxyz"
    let server = newHttpServer(handler, host = "127.0.0.1", port = 8080,
                               enableHttp2 = false, reusePort = true,
                               tcpNoDelay = true)
    server.bindAndListen()
    discard server.start()

proc main() =
  let runtime = newMultiThreadRuntime()
  setMainRuntime(runtime)
  setCurrentRuntime(runtime)
  runtime.startMtNetworkShards(startShard)
  while true:
    sleep(1000)

main()

## Benchmark server matching Mummy's wrk_mummy.nim workload: 10 ms delay per
## request, 26-byte body. The delay is ASYNC — a per-connection timerfd that
## the reactor waits on (waitRead), so the dispatcher parks the continuation
## instead of blocking. This is the CPS equivalent of Mummy's blocking
## sleep(10) across 100 worker threads.
##
##   ../nimony/bin/nimony c -r bench/bench_server.nim
##   wrk -t10 -c100 -d10s http://127.0.0.1:8080/

import hashi/http/request
import hashi/log
import hashi/loop

const Body = "abcdefghijklmnopqrstuvwxyz"

proc writeAll(clientFd: cint; data: string): bool {.passive.} =
  result = true
  var wbuf = default(array[4096, char])
  var off = 0
  var cont = true
  while off < data.len and cont:
    var clen = data.len - off
    if clen > 4096: clen = 4096
    var j = 0
    while j < clen:
      wbuf[j] = data[off + j]
      j = j + 1
    var wOff = 0
    while wOff < clen and cont:
      let w = waitWrite(clientFd, addr wbuf[wOff], clen - wOff)
      if w <= 0:
        result = false
        cont = false
      else:
        wOff = wOff + w
    off = off + clen

proc handleConn(clientFd: cint) {.passive.} =
  var rbuf = default(array[4096, byte])
  var acc = ""
  var keepGoing = true
  while keepGoing:
    var req = default(Request)
    var st = parseRequestHead(acc, req)
    while st == psIncomplete and keepGoing:
      let n = waitRead(clientFd, addr rbuf[0], rbuf.len)
      if n <= 0:
        keepGoing = false
      else:
        var i = 0
        while i < n:
          acc.add char(rbuf[i])
          i = i + 1
        st = parseRequestHead(acc, req)

    if keepGoing:
      var ok = true
      var need = req.headBytes
      if st == psError:
        keepGoing = false
        ok = false
      else:
        let bi = bodyFraming(req)
        if bi.kind == bkError or bi.kind == bkChunked:
          keepGoing = false
          ok = false
        elif bi.kind == bkLength:
          need = req.headBytes + bi.length

      while ok and keepGoing and acc.len < need:
        let n = waitRead(clientFd, addr rbuf[0], rbuf.len)
        if n <= 0:
          keepGoing = false
        else:
          var i = 0
          while i < n:
            acc.add char(rbuf[i])
            i = i + 1

      if ok and keepGoing:
        # async 10 ms "work"
        sleepMs(10)
        let resp = newResponse(200, Body)
        let wok = writeAll(clientFd, serialize(resp))
        if not wok:
          keepGoing = false
        else:
          var rest = ""
          var k = need
          while k < acc.len:
            rest.add acc[k]
            k = k + 1
          acc = rest

  closeFd(clientFd)

proc acceptLoop(listenFd: cint) {.passive.} =
  while true:
    let clientFd = waitAccept(listenFd)
    if clientFd >= 0:
      setNonBlocking(clientFd.cint)
      spawnTask handleConn(clientFd.cint)

proc main() =
  initLoop()
  let listenFd = listenTcp(8080'u16)
  log(info, "hashi bench (10ms async delay) on :8080 (fd=" & $listenFd.int & ")")
  spawnTask acceptLoop(listenFd)
  runLoop()

main()

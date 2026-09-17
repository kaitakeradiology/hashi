# Running the Autobahn WebSocket conformance suite

The official RFC 6455 conformance suite. Drives the hashi WebSocket **echo
server** (`examples/ws_echo`) through 517 cases and writes an HTML report.
Runs the `crossbario/autobahn-testsuite` image through a container runtime
(podman/docker). The suite itself is Python 2 on PyPy; the PyPI
`autobahntestsuite` package, 25.10.1 included, is still Python 2 source, so
the image is the only practical way to run it.

## 1. One-time: rootless podman (Debian)

```bash
sudo apt install uidmap slirp4netns fuse-overlayfs
podman system migrate
podman pull docker.io/crossbario/autobahn-testsuite
```

(`uidmap` is the usual missing piece — it ships `newuidmap`/`newgidmap` with the
capabilities rootless podman needs. Verify `grep "^$USER:" /etc/subuid` shows a
range.) Docker works too: `docker pull crossbario/autobahn-testsuite`.

Inside an unprivileged LXC container the default `/etc/subuid` range
(`100000:65536`) lies outside the container's own uid map, so rootless podman
fails with `newuidmap: write to uid_map failed: Operation not permitted`.
Shrink the range to fit (e.g. `<user>:20000:40000` in `/etc/subuid` and
`/etc/subgid`, then `podman system migrate`). Failing that, the image can be
unpacked to a directory (skopeo + umoci, or any layer puller) and `wstest` run
from it without a runtime, since only a single-uid user namespace is needed:

```bash
unshare -Urm sh -c "mount --rbind /proc $R/proc && mount --rbind /dev $R/dev &&
  mount --bind $PWD/tests/conformance/autobahn/fuzzingclient.json $R/config/fuzzingclient.json &&
  mount --bind $PWD/tests/conformance/autobahn/reports $R/reports &&
  exec /usr/sbin/chroot $R /usr/bin/env PATH=/opt/pypy/bin:/usr/bin:/bin \
    wstest -m fuzzingclient -s /config/fuzzingclient.json"    # R = the unpacked rootfs
```

## 2. Start the hashi echo server

```bash
../nimony/bin/nimony c examples/ws_echo.nim        # build
$(find nimcache -name ws_echo -type f | head -1)    # run — listens on 0.0.0.0:8080
```

It binds all interfaces, so it can be reached from another host.

## 3. Point the suite at the server

`fuzzingclient.json` defaults to `ws://127.0.0.1:8080` — correct when the
server and the container run on the **same** host (the runner uses
`--network host`). If the server is on a different box (e.g. hashi on the dev
box, podman elsewhere), set the `url` to `ws://<server-ip>:8080`.

## 4. Run

```bash
RUNTIME=podman tests/conformance/autobahn/run.sh    # omit RUNTIME, or set =docker, as needed
```

The full run takes about a minute.

Or directly:

```bash
podman run -it --rm --network host \
  -v "$PWD/tests/conformance/autobahn/fuzzingclient.json:/config/fuzzingclient.json:ro" \
  -v "$PWD/tests/conformance/autobahn/reports:/reports" \
  docker.io/crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json
```

## 5. Read the report

Open `tests/conformance/autobahn/reports/index.html`. Each case shows Pass /
Non-Strict / Fail / Unimplemented. Sections 12 and 13 (permessage-deflate)
are expected to be Unimplemented: hashi has no compression extension. The
current result is recorded in `doc/conformance.md`.

Quick local pre-check without the suite: `python3 tests/conformance/ws_conformance.py
<hello-bin>` (39 cases over raw sockets — not authoritative, but catches
regressions fast).

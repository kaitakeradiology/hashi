#!/usr/bin/env python3
"""Before-middleware on WebSocket upgrades, end to end over raw sockets.

Starts tests/smoke_ws_before (built) on two free loopback ports and checks
that the before-middleware chain runs on the main listener's upgrades and not
on a secondary `addWsListener` listener's, and that a non-canonical target is
refused with 400 before any of it.

  ws_before.py <smoke_ws_before-bin>
"""
import base64, os, select, signal, socket, struct, subprocess, sys, time

BIN = sys.argv[1]
HOST = "127.0.0.1"
TEXT = 0x1
results = []


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


def chk(name, cond, detail=""):
    results.append((name, cond))
    print(f"  {'PASS' if cond else 'FAIL'} {name}{(' -- ' + detail) if (detail and not cond) else ''}")


def recvn(s, n, buf):
    """`n` bytes, taking `buf` (bytes already read) first; raises EOFError."""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf[:n], buf[n:]


def read_head(s):
    """The response head and whatever followed it in the same reads."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(4096)
        if not c:
            raise EOFError(f"EOF before a full head ({buf!r})")
        buf += c
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head.decode("latin-1"), rest


def read_to_eof(s, buf):
    while True:
        c = s.recv(4096)
        if not c:
            return buf
        buf += c


def read_frame(s, buf):
    """One unmasked server frame: (opcode, payload)."""
    b, buf = recvn(s, 2, buf)
    n = b[1] & 0x7F
    if n == 126:
        e, buf = recvn(s, 2, buf)
        n = struct.unpack(">H", e)[0]
    elif n == 127:
        e, buf = recvn(s, 8, buf)
        n = struct.unpack(">Q", e)[0]
    pl, buf = recvn(s, n, buf)
    return b[0] & 0x0F, pl


def connect(port):
    s = socket.create_connection((HOST, port), timeout=3)
    s.settimeout(3)
    return s


def upgrade(port, target):
    s = connect(port)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {target} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
    return s


def plain_get(port, target):
    s = connect(port)
    s.sendall(f"GET {target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    return s


def status_line(head):
    return head.split("\r\n", 1)[0]


def content_length(head):
    for line in head.split("\r\n")[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "content-length":
            return int(value.strip())
    return None


# -- cases ---------------------------------------------------------------------

def t1_main_deny(main):
    name = "T1 main listener: upgrade to /deny -> 403, body is the client address, no frame"
    try:
        s = upgrade(main, "/deny")
        head, rest = read_head(s)
        rest = read_to_eof(s, rest)
        s.close()
        sl = status_line(head)
        cl = content_length(head)
        ok = (sl.startswith("HTTP/1.1 403") and cl == len(b"127.0.0.1")
              and rest == b"127.0.0.1")
        chk(name, ok, f"status={sl!r} content-length={cl} after-head={rest!r}")
    except (OSError, EOFError) as e:
        chk(name, False, repr(e))


def t_handler(name, port, target, expect):
    try:
        s = upgrade(port, target)
        head, rest = read_head(s)
        sl = status_line(head)
        if not sl.startswith("HTTP/1.1 101"):
            rest = read_to_eof(s, rest)
            s.close()
            chk(name, False, f"status={sl!r} after-head={rest!r}")
            return
        op, pl = read_frame(s, rest)
        s.close()
        chk(name, op == TEXT and pl == expect, f"frame op={op} payload={pl!r}")
    except (OSError, EOFError) as e:
        chk(name, False, repr(e))


def t4_noncanonical(main):
    cases = [("GET //a", lambda: plain_get(main, "//a")),
             ("GET /a/../b", lambda: plain_get(main, "/a/../b")),
             ("GET /a%2Fb", lambda: plain_get(main, "/a%2Fb")),
             ("upgrade to //deny", lambda: upgrade(main, "//deny"))]
    for label, open_ in cases:
        name = f"T4 main listener: {label} -> 400"
        try:
            s = open_()
            head, _ = read_head(s)
            s.close()
            sl = status_line(head)
            chk(name, sl.startswith("HTTP/1.1 400"), f"status={sl!r}")
        except (OSError, EOFError) as e:
            chk(name, False, repr(e))


def wait_ready(p, timeout):
    """True once the server prints "ready" on stdout."""
    deadline = time.monotonic() + timeout
    line = b""
    while time.monotonic() < deadline:
        r, _, _ = select.select([p.stdout], [], [], 0.1)
        if r:
            c = os.read(p.stdout.fileno(), 256)
            if not c:
                return False
            line += c
            if b"ready\n" in line:
                return True
        if p.poll() is not None:
            return False
    return False


def main():
    main_port, extra_port = free_port(), free_port()
    while extra_port == main_port:
        extra_port = free_port()
    p = subprocess.Popen([BIN, str(main_port), str(extra_port)],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        if not wait_ready(p, 10):
            print(f"server did not become ready (exit={p.poll()})")
            sys.exit(1)
        t1_main_deny(main_port)
        t_handler("T2 main listener: upgrade to /ok -> 101, main handler runs",
                  main_port, "/ok", b"main-handler")
        t_handler("T3 secondary listener: upgrade to /deny -> 101, its handler runs",
                  extra_port, "/deny", b"extra-handler")
        t4_noncanonical(main_port)
    finally:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    passed = sum(1 for _, c in results if c)
    print(f"\n{passed}/{len(results)} before-middleware checks passed")
    sys.exit(0 if passed == len(results) else 1)


main()

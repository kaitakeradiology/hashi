#!/usr/bin/env python3
"""WebSocket smoke test for the hashi echo server (RFC 6455). Validates the
handshake + framing/echo/ping/close/fragmentation paths without Autobahn.

  ws_check.py <hashi-bin>
"""
import socket, subprocess, sys, os, time, signal, struct, base64, hashlib

BIN = sys.argv[1]
HOST, PORT = "127.0.0.1", 8080
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OK = opTEXT, opBIN, opCLOSE, opPING, opPONG = 0x1, 0x2, 0x8, 0x9, 0xA
results = []

def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("closed")
        b += c
    return b

def cframe(opcode, payload, fin=True, key=b"\x12\x34\x56\x78"):
    b0 = (0x80 if fin else 0) | opcode
    n = len(payload)
    out = bytes([b0])
    if n < 126:
        out += bytes([0x80 | n])
    elif n <= 0xFFFF:
        out += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        out += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(payload[i] ^ key[i % 4] for i in range(n))
    return out + key + masked

def rframe(s):
    b = recvn(s, 2)
    b0, b1 = b[0], b[1]
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recvn(s, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recvn(s, 8))[0]
    payload = recvn(s, n) if n else b""
    return (b0 & 0x0F, b0 & 0x80 != 0, payload)

def handshake():
    s = socket.create_connection((HOST, PORT), timeout=2)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(256)
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    ok = b"101" in buf and expect.encode() in buf
    return s, ok

def chk(name, cond):
    results.append((name, cond))
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")

def main():
    subprocess.run(["pkill", "-9", "-x", os.path.basename(BIN)], stderr=subprocess.DEVNULL)
    p = subprocess.Popen([BIN], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    time.sleep(1.0)
    try:
        # handshake
        s, ok = handshake()
        chk("handshake 101 + correct accept key", ok)

        # text echo
        s.sendall(cframe(opTEXT, b"Hello"))
        op, fin, pl = rframe(s)
        chk("text echo", op == opTEXT and fin and pl == b"Hello")

        # binary echo
        s.sendall(cframe(opBIN, b"\x00\x01\x02\xff"))
        op, _, pl = rframe(s)
        chk("binary echo", op == opBIN and pl == b"\x00\x01\x02\xff")

        # large (16-bit length) echo
        big = b"a" * 1000
        s.sendall(cframe(opBIN, big))
        op, _, pl = rframe(s)
        chk("1000-byte echo", op == opBIN and pl == big)

        # fragmented text -> single echo
        s.sendall(cframe(opTEXT, b"Hel", fin=False))
        s.sendall(cframe(0x0, b"lo", fin=True))   # continuation
        op, _, pl = rframe(s)
        chk("fragmented message reassembled", op == opTEXT and pl == b"Hello")

        # ping -> pong
        s.sendall(cframe(opPING, b"hi"))
        op, _, pl = rframe(s)
        chk("ping -> pong", op == opPONG and pl == b"hi")

        # close -> close echo
        s.sendall(cframe(opCLOSE, b"\x03\xe8"))   # 1000
        op, _, pl = rframe(s)
        chk("close -> close echo (1000)", op == opCLOSE and pl[:2] == b"\x03\xe8")
        s.close()

        # unmasked frame -> close 1002
        s2, _ = handshake()
        # build an UNmasked text frame manually
        s2.sendall(bytes([0x81, 0x05]) + b"Hello")
        op, _, pl = rframe(s2)
        chk("unmasked client frame -> close 1002",
            op == opCLOSE and pl[:2] == b"\x03\xea")
        s2.close()

        # invalid UTF-8 text -> close 1007
        s3, _ = handshake()
        s3.sendall(cframe(opTEXT, b"\xc3\x28"))    # bad utf-8
        op, _, pl = rframe(s3)
        chk("invalid UTF-8 text -> close 1007",
            op == opCLOSE and pl[:2] == b"\x03\xef")
        s3.close()
    finally:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        p.wait()

    passed = sum(1 for _, c in results if c)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)

main()

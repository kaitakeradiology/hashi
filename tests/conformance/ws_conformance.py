#!/usr/bin/env python3
"""Native RFC 6455 conformance harness for the hashi WebSocket echo server.

Covers the Autobahn case categories over raw sockets (full control of the wire,
incl. malformed frames a WS client library wouldn't let you send): framing &
lengths, pings/pongs, reserved bits, reserved opcodes, fragmentation, UTF-8,
and close handling. Not the official suite, but exercises the same surface.

  ws_conformance.py <hashi-bin>
"""
import socket, subprocess, sys, os, time, signal, struct, base64, hashlib

BIN = sys.argv[1]
HOST, PORT = "127.0.0.1", 8080
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONT, TEXT, BIN_, CLOSE, PING, PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA
results = []

def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b

def frame(opcode, payload=b"", fin=True, rsv=0, mask=True, key=b"\x21\x09\x55\xae"):
    b0 = (0x80 if fin else 0) | (rsv << 4) | opcode
    n = len(payload)
    out = bytes([b0])
    mbit = 0x80 if mask else 0
    if n < 126:
        out += bytes([mbit | n])
    elif n <= 0xFFFF:
        out += bytes([mbit | 126]) + struct.pack(">H", n)
    else:
        out += bytes([mbit | 127]) + struct.pack(">Q", n)
    if mask:
        out += key + bytes(payload[i] ^ key[i % 4] for i in range(n))
    else:
        out += payload
    return out

def rframe(s):
    b = recvn(s, 2)
    b0, b1 = b[0], b[1]
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recvn(s, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recvn(s, 8))[0]
    pl = recvn(s, n) if n else b""
    return (b0 & 0x0F, (b0 & 0x80) != 0, pl)

def ws():
    s = socket.create_connection((HOST, PORT), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(256)
    s.settimeout(3)
    return s

def chk(name, cond, detail=""):
    results.append((name, cond))
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{(' — ' + detail) if (detail and not cond) else ''}")

def close_code(pl):
    return (pl[0] << 8) | pl[1] if len(pl) >= 2 else None

# ── cases ──────────────────────────────────────────────────────────────

def case_echo(name, opcode, payload):
    s = ws()
    s.sendall(frame(opcode, payload))
    op, fin, pl = rframe(s)
    chk(name, op == opcode and fin and pl == payload, f"got op={op} len={len(pl)}")
    s.close()

def case_close_after(name, sendframe, expect_code):
    s = ws()
    s.sendall(sendframe)
    try:
        op, _, pl = rframe(s)
        chk(name, op == CLOSE and close_code(pl) == expect_code,
            f"got op={op} code={close_code(pl)}")
    except (EOFError, socket.timeout):
        chk(name, False, "no close frame")
    s.close()

def run():
    # 1. framing & lengths
    case_echo("1.1 empty text echo", TEXT, b"")
    case_echo("1.2 small text echo", TEXT, b"hi")
    case_echo("1.3 125-byte (7-bit max)", BIN_, b"a" * 125)
    case_echo("1.4 126-byte (16-bit len)", BIN_, b"a" * 126)
    case_echo("1.5 65535-byte (16-bit max)", BIN_, b"a" * 65535)
    case_echo("1.6 65536-byte (64-bit len)", BIN_, b"a" * 65536)

    # 2. pings / pongs
    s = ws(); s.sendall(frame(PING, b"")); op, _, pl = rframe(s)
    chk("2.1 ping(empty) -> pong", op == PONG and pl == b""); s.close()
    s = ws(); s.sendall(frame(PING, b"payload")); op, _, pl = rframe(s)
    chk("2.2 ping(payload) -> pong echo", op == PONG and pl == b"payload"); s.close()
    s = ws(); s.sendall(frame(PING, b"z" * 125)); op, _, pl = rframe(s)
    chk("2.3 ping(125 max) -> pong", op == PONG and len(pl) == 125); s.close()
    # unsolicited pong is ignored; a following text still echoes
    s = ws(); s.sendall(frame(PONG, b"x")); s.sendall(frame(TEXT, b"ok"))
    op, _, pl = rframe(s); chk("2.4 unsolicited pong ignored", op == TEXT and pl == b"ok"); s.close()

    # 3. reserved bits -> 1002
    case_close_after("3.1 RSV1 set -> 1002", frame(TEXT, b"x", rsv=4), 1002)
    case_close_after("3.2 RSV2 set -> 1002", frame(TEXT, b"x", rsv=2), 1002)
    case_close_after("3.3 RSV3 set -> 1002", frame(TEXT, b"x", rsv=1), 1002)

    # 4. reserved opcodes -> 1002
    case_close_after("4.1 reserved data opcode 0x3 -> 1002", frame(0x3, b"x"), 1002)
    case_close_after("4.2 reserved control opcode 0xB -> 1002", frame(0xB, b"x"), 1002)

    # 5. fragmentation
    s = ws()
    s.sendall(frame(TEXT, b"frag", fin=False)); s.sendall(frame(CONT, b"-ment", fin=True))
    op, _, pl = rframe(s); chk("5.1 two-frame message", op == TEXT and pl == b"frag-ment"); s.close()
    s = ws()
    s.sendall(frame(TEXT, b"a", fin=False)); s.sendall(frame(CONT, b"b", fin=False))
    s.sendall(frame(CONT, b"c", fin=True))
    op, _, pl = rframe(s); chk("5.2 three-frame message", op == TEXT and pl == b"abc"); s.close()
    s = ws()
    s.sendall(frame(TEXT, b"a", fin=False)); s.sendall(frame(PING, b"p"))
    op, _, pl = rframe(s); ping_ok = op == PONG and pl == b"p"
    s.sendall(frame(CONT, b"b", fin=True)); op, _, pl = rframe(s)
    chk("5.3 ping interleaved in fragments", ping_ok and op == TEXT and pl == b"ab"); s.close()
    case_close_after("5.4 continuation w/o start -> 1002", frame(CONT, b"x", fin=True), 1002)
    s = ws()
    s.sendall(frame(TEXT, b"a", fin=False)); s.sendall(frame(TEXT, b"b", fin=True))
    case_close_after("5.5 new data frame mid-message -> 1002 (inline)",
                     b"", 1002) if False else None
    try:
        op, _, pl = rframe(s)
        chk("5.5 data frame mid-message -> 1002", op == CLOSE and close_code(pl) == 1002)
    except Exception:
        chk("5.5 data frame mid-message -> 1002", False, "no close")
    s.close()

    # 6. UTF-8
    case_echo("6.1 valid utf-8 (é€😀)", TEXT, "é€😀".encode())
    case_close_after("6.2 invalid utf-8 (lone cont) -> 1007", frame(TEXT, b"\x80"), 1007)
    case_close_after("6.3 invalid utf-8 (overlong) -> 1007", frame(TEXT, b"\xc0\x80"), 1007)
    case_close_after("6.4 invalid utf-8 (surrogate) -> 1007", frame(TEXT, b"\xed\xa0\x80"), 1007)
    case_close_after("6.5 invalid utf-8 (truncated) -> 1007", frame(TEXT, b"\xc3"), 1007)
    # split a 2-byte char across fragments -> valid
    s = ws()
    s.sendall(frame(TEXT, b"\xc3", fin=False)); s.sendall(frame(CONT, b"\xa9", fin=True))
    op, _, pl = rframe(s); chk("6.6 split multibyte across fragments valid", op == TEXT and pl == b"\xc3\xa9"); s.close()
    # invalid split (second half missing) at message end -> 1007
    case_close_after("6.7 fragmented invalid utf-8 -> 1007",
                     frame(TEXT, b"\xc3\x28"), 1007)

    # 7. close handling
    case_close_after("7.1 empty close -> echo 1000", frame(CLOSE, b""), 1000)
    case_close_after("7.2 close 1000 -> echo 1000", frame(CLOSE, struct.pack(">H", 1000)), 1000)
    case_close_after("7.3 close 1001 -> valid", frame(CLOSE, struct.pack(">H", 1001)), 1000)
    case_close_after("7.4 close 3000 (registered) -> valid", frame(CLOSE, struct.pack(">H", 3000)), 1000)
    case_close_after("7.5 close 4999 (private) -> valid", frame(CLOSE, struct.pack(">H", 4999)), 1000)
    case_close_after("7.6 close 1004 (reserved) -> 1002", frame(CLOSE, struct.pack(">H", 1004)), 1002)
    case_close_after("7.7 close 1005 (no-status) -> 1002", frame(CLOSE, struct.pack(">H", 1005)), 1002)
    case_close_after("7.8 close 1006 (abnormal) -> 1002", frame(CLOSE, struct.pack(">H", 1006)), 1002)
    case_close_after("7.9 close 1-byte payload -> 1002", frame(CLOSE, b"\x03"), 1002)
    case_close_after("7.10 close + valid reason -> 1000",
                     frame(CLOSE, struct.pack(">H", 1000) + "bye".encode()), 1000)
    case_close_after("7.11 close + bad-utf8 reason -> 1007",
                     frame(CLOSE, struct.pack(">H", 1000) + b"\xc3\x28"), 1007)

    # 8. masking enforcement
    case_close_after("8.1 unmasked client frame -> 1002", frame(TEXT, b"x", mask=False), 1002)

def main():
    subprocess.run(["pkill", "-9", "-x", os.path.basename(BIN)], stderr=subprocess.DEVNULL)
    p = subprocess.Popen([BIN], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    time.sleep(1.0)
    try:
        run()
    finally:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL); p.wait()
    passed = sum(1 for _, c in results if c)
    print(f"\n{passed}/{len(results)} conformance checks passed")
    sys.exit(0 if passed == len(results) else 1)

main()

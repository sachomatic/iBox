#!/usr/bin/env python3
"""Tiny RFB 3.8 server for testing iBox's VNC viewer without a real desktop.

Serves an animated test pattern using the ZRLE encoding (raw, solid and plain-RLE
tiles) and Hextile, so the decoder paths iBox relies on are exercised.

    python tools/vnc_test_server.py [port]      # then connect iBox to <this-pc-ip>:<port>
"""
import socket
import struct
import sys
import threading
import time
import zlib

W, H = 640, 360


def pixel(x, y, t):
    # Vertical colour bars, a moving white box and a grey ramp at the bottom.
    if y > H - 60:
        g = (x * 255) // W
        return (g, g, g)
    if (t * 40) % W <= x < (t * 40) % W + 80 and 100 <= y < 180:
        return (255, 255, 255)
    bars = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255)]
    return bars[(x * len(bars)) // W]


def cpixel(rgb):  # 32bpp xRGB little-endian, depth 24 -> 3 bytes B,G,R
    r, g, b = rgb
    return bytes((b, g, r))


def zrle_tiles(t):
    out = bytearray()
    for ty in range(0, H, 64):
        for tx in range(0, W, 64):
            tw, th = min(64, W - tx), min(64, H - ty)
            pixels = [pixel(tx + x, ty + y, t) for y in range(th) for x in range(tw)]
            if all(p == pixels[0] for p in pixels):
                out += b"\x01" + cpixel(pixels[0])          # solid tile
            elif ty >= H - 64:
                out += b"\x00" + b"".join(cpixel(p) for p in pixels)  # raw tile
            else:
                out += b"\x80"                               # plain RLE tile
                i = 0
                while i < len(pixels):
                    j = i
                    while j + 1 < len(pixels) and pixels[j + 1] == pixels[i]:
                        j += 1
                    run = j - i + 1
                    out += cpixel(pixels[i])
                    run -= 1
                    while run >= 255:
                        out += b"\xff"
                        run -= 255
                    out += bytes((run,))
                    i = j + 1
    return bytes(out)


def serve(conn):
    conn.sendall(b"RFB 003.008\n")
    conn.recv(12)
    conn.sendall(b"\x01\x01")                # one security type: None
    conn.recv(1)
    conn.sendall(struct.pack(">I", 0))       # SecurityResult OK
    conn.recv(1)                             # ClientInit
    name = b"iBox test pattern"
    pf = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    conn.sendall(struct.pack(">HH", W, H) + pf + struct.pack(">I", len(name)) + name)
    comp = zlib.compressobj()
    t = 0
    buf = b""
    while True:
        data = conn.recv(4096)
        if not data:
            return
        buf += data
        while buf:
            kind = buf[0]
            size = {0: 20, 2: 4, 3: 10, 4: 8, 5: 6}.get(kind)
            if kind == 2 and len(buf) >= 4:
                size = 4 + 4 * struct.unpack(">H", buf[2:4])[0]
            if kind == 6 and len(buf) >= 8:
                size = 8 + struct.unpack(">I", buf[4:8])[0]
            if size is None or len(buf) < size:
                break
            msg, buf = buf[:size], buf[size:]
            if kind == 2:
                encs = struct.unpack(">%di" % ((size - 4) // 4), msg[4:])
                print("client encodings:", encs, flush=True)
            if kind == 3:
                time.sleep(0.1)
                raw = zrle_tiles(t)
                data = comp.compress(raw) + comp.flush(zlib.Z_SYNC_FLUSH)
                rect = struct.pack(">HHHHi", 0, 0, W, H, 16) + struct.pack(">I", len(data)) + data
                conn.sendall(struct.pack(">BxH", 0, 1) + rect)
                t += 1
                if t % 20 == 0:
                    print("sent", t, "frames", flush=True)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5901
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(2)
    print("RFB test server on port", port, flush=True)
    while True:
        conn, addr = srv.accept()
        print("client", addr, flush=True)
        threading.Thread(target=lambda: (serve(conn), conn.close()), daemon=True).start()


if __name__ == "__main__":
    main()

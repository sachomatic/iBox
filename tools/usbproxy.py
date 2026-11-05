#!/usr/bin/env python3
"""Forward local TCP ports to the iPhone over USB (like libimobiledevice's iproxy).

Talks to usbmuxd, which on Windows is Apple Mobile Device Service (127.0.0.1:27015),
and on macOS/Linux is /var/run/usbmuxd. No third-party dependencies.

    python tools/usbproxy.py 2222:22 8080:8080
    ssh -p 2222 root@127.0.0.1
"""
import os
import plistlib
import socket
import struct
import sys
import threading

PLIST_MSG = 8


def mux_connect():
    if os.name == "nt":
        return socket.create_connection(("127.0.0.1", 27015))
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/var/run/usbmuxd")
    return s


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("usbmuxd closed the connection")
        buf += chunk
    return buf


def mux_request(s, payload, tag=1):
    payload.setdefault("ClientVersionString", "ibox-usbproxy")
    payload.setdefault("ProgName", "ibox-usbproxy")
    body = plistlib.dumps(payload)
    s.sendall(struct.pack("<IIII", 16 + len(body), 1, PLIST_MSG, tag) + body)
    length, _ver, _msg, _tag = struct.unpack("<IIII", recv_exact(s, 16))
    return plistlib.loads(recv_exact(s, length - 16))


def first_device_id():
    s = mux_connect()
    try:
        reply = mux_request(s, {"MessageType": "ListDevices"})
    finally:
        s.close()
    devices = [d for d in reply.get("DeviceList", [])
               if d.get("Properties", {}).get("ConnectionType", "USB") == "USB"]
    if not devices:
        raise ConnectionError("no iOS device found over USB")
    return devices[0]["DeviceID"]


def open_device_port(device_id, port):
    s = mux_connect()
    swapped = ((port & 0xFF) << 8) | (port >> 8)
    reply = mux_request(s, {"MessageType": "Connect", "DeviceID": device_id, "PortNumber": swapped})
    if reply.get("Number", 1) != 0:
        s.close()
        raise ConnectionError("device refused port %d (usbmuxd result %s)" % (port, reply.get("Number")))
    return s


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(local_port, device_port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", local_port))
    srv.listen(16)
    print("127.0.0.1:%d -> iPhone:%d" % (local_port, device_port), flush=True)
    while True:
        client, _ = srv.accept()
        try:
            remote = open_device_port(first_device_id(), device_port)
        except Exception as exc:  # keep serving; the phone may be re-plugged
            print("connect failed: %s" % exc, flush=True)
            client.close()
            continue
        threading.Thread(target=pump, args=(client, remote), daemon=True).start()
        threading.Thread(target=pump, args=(remote, client), daemon=True).start()


def main(argv):
    pairs = argv or ["2222:22"]
    threads = []
    for pair in pairs:
        local, _, remote = pair.partition(":")
        t = threading.Thread(target=serve, args=(int(local), int(remote or local)), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()


if __name__ == "__main__":
    main(sys.argv[1:])

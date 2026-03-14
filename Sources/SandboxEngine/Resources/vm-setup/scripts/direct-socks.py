#!/usr/bin/python3 -u
"""Minimal SOCKS5 proxy — transparent forwarding without authentication.

Binds to 127.0.0.1:40000 and relays connections directly to the
destination.  Used as the default upstream for squid (via proxychains)
when Cloudflare WARP is not active.  When WARP is enabled, this process
is stopped and warp-svc takes over port 40000.

Supports CONNECT command only (IPv4, IPv6, and domain name addressing).
"""

import os
import select
import signal
import socket
import struct
import sys
import threading

BIND_ADDR = "127.0.0.1"
BIND_PORT = 40000
RELAY_BUF = 65536
MAX_THREADS = 256
MAX_CONNECTION_TIME = 86400  # 24 hours — matches VM session lifetime

# Semaphore to cap concurrent connections
_conn_semaphore = threading.Semaphore(MAX_THREADS)


def relay(a, b):
    """Bidirectional relay between two sockets until one side closes."""
    deadline = _monotonic() + MAX_CONNECTION_TIME
    try:
        while True:
            remaining = deadline - _monotonic()
            if remaining <= 0:
                break
            timeout = min(remaining, 60.0)
            readable, _, _ = select.select([a, b], [], [], timeout)
            if not readable:
                # select timed out — check if we hit the deadline
                if _monotonic() >= deadline:
                    break
                continue
            for sock in readable:
                data = sock.recv(RELAY_BUF)
                if not data:
                    return
                peer = b if sock is a else a
                peer.sendall(data)
    except (OSError, BrokenPipeError):
        pass
    finally:
        a.close()
        b.close()


def _monotonic():
    return os.times()[4] if not hasattr(select, 'monotonic') else __import__('time').monotonic()

# Use time.monotonic directly
_monotonic = __import__('time').monotonic


def handle_client(client):
    """Handle one SOCKS5 client connection."""
    remote = None
    try:
        # --- Greeting ---
        greeting = client.recv(256)
        if len(greeting) < 2 or greeting[0] != 0x05:
            return
        # No authentication required
        client.sendall(b"\x05\x00")

        # --- Connect request ---
        req = client.recv(256)
        if len(req) < 4 or req[0] != 0x05 or req[1] != 0x01:
            # Only CONNECT (0x01) is supported
            client.sendall(b"\x05\x07\x00\x01" + b"\x00" * 6)
            return

        atyp = req[3]
        if atyp == 0x01:  # IPv4
            if len(req) < 10:
                return
            addr = socket.inet_ntoa(req[4:8])
            port = struct.unpack("!H", req[8:10])[0]
        elif atyp == 0x03:  # Domain name
            alen = req[4]
            if len(req) < 5 + alen + 2:
                return
            raw = req[5 : 5 + alen]
            if not all(0x20 < b < 0x7F for b in raw):
                client.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6)
                return
            addr = raw.decode("ascii")
            port = struct.unpack("!H", req[5 + alen : 7 + alen])[0]
        elif atyp == 0x04:  # IPv6
            if len(req) < 22:
                return
            addr = socket.inet_ntop(socket.AF_INET6, req[4:20])
            port = struct.unpack("!H", req[20:22])[0]
        else:
            client.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6)
            return

        # Reject port 0
        if port == 0:
            client.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)
            return

        # --- Connect to target ---
        try:
            remote = socket.create_connection((addr, port), timeout=10)
        except OSError:
            # Connection refused / host unreachable
            client.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            return

        # Success reply
        client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)

        # --- Relay (takes ownership of both sockets) ---
        relay(client, remote)
        remote = None  # relay closed it
        client = None  # relay closed it

    except (OSError, BrokenPipeError):
        pass
    finally:
        if remote is not None:
            try:
                remote.close()
            except OSError:
                pass
        if client is not None:
            try:
                client.close()
            except OSError:
                pass
        _conn_semaphore.release()


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((BIND_ADDR, BIND_PORT))
    srv.listen(128)
    print(f"direct-socks: listening on {BIND_ADDR}:{BIND_PORT}", file=sys.stderr)

    while True:
        try:
            client, _ = srv.accept()
            client.settimeout(30)
            if not _conn_semaphore.acquire(blocking=False):
                # Too many connections — reject
                client.close()
                continue
            t = threading.Thread(target=handle_client, args=(client,), daemon=True)
            t.start()
        except OSError:
            break


if __name__ == "__main__":
    main()

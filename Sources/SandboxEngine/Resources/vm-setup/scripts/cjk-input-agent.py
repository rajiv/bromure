#!/usr/bin/python3 -u
"""Bromure CJK input agent — bridges macOS IME to Chromium via CDP.

Runs inside the guest VM. The host sends JSON messages over vsock port 5007:

  {"type": "compose", "text": "みち"}   → show inline composition (underlined)
  {"type": "commit",  "text": "道"}     → insert final committed text
  {"type": "clear"}                     → cancel composition

The agent translates these into Chrome DevTools Protocol calls:
  - Input.imeSetComposition  (compose)
  - Input.insertText         (commit)

This gives CJK users a native macOS IME experience with inline composition
display inside the browser.

Started at boot via inittab (runs as chrome user).
"""

import hashlib
import http.client
import json
import os
import socket
import struct
import sys
import time

VSOCK_PORT = 5007
CDP_HOST = "127.0.0.1"
CDP_PORT = 9222


# ---------------------------------------------------------------------------
# Minimal WebSocket client (no external dependencies)
# ---------------------------------------------------------------------------

def ws_connect(url):
    """Open a WebSocket connection. Returns the socket."""
    # Parse ws://host:port/path
    assert url.startswith("ws://")
    rest = url[5:]
    host_port, path = rest.split("/", 1)
    path = "/" + path
    if ":" in host_port:
        host, port = host_port.split(":")
        port = int(port)
    else:
        host, port = host_port, 80

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))

    # WebSocket handshake
    key = "dGhlIHNhbXBsZSBub25jZQ=="  # static key is fine for local CDP
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    sock.sendall(request.encode())

    # Read response headers
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("WebSocket handshake failed")
        response += chunk

    if b"101" not in response.split(b"\r\n")[0]:
        raise ConnectionError(f"WebSocket upgrade rejected: {response[:200]}")

    return sock


def ws_send(sock, data):
    """Send a WebSocket text frame (masked, as required by RFC 6455 for clients)."""
    payload = data.encode("utf-8") if isinstance(data, str) else data
    frame = bytearray()
    frame.append(0x81)  # FIN + text opcode

    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)  # masked
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(0x80 | 127)
        frame.extend(struct.pack(">Q", length))

    # Masking key (all zeros — local connection, security not relevant)
    mask = b"\x00\x00\x00\x00"
    frame.extend(mask)
    frame.extend(payload)  # XOR with zero mask = identity
    sock.sendall(frame)


def ws_recv(sock):
    """Read one WebSocket frame. Returns the payload as string."""
    def read_exact(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("WebSocket closed")
            buf += chunk
        return buf

    header = read_exact(2)
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F

    if length == 126:
        length = struct.unpack(">H", read_exact(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(8))[0]

    if masked:
        mask = read_exact(4)
        data = bytearray(read_exact(length))
        for i in range(length):
            data[i] ^= mask[i % 4]
    else:
        data = read_exact(length)

    if opcode == 0x08:  # close
        raise ConnectionError("WebSocket closed by server")
    if opcode == 0x09:  # ping
        # Send pong
        pong = bytearray([0x8A, 0x80, 0, 0, 0, 0])
        sock.sendall(pong)
        return ws_recv(sock)  # read next real frame

    return data.decode("utf-8") if isinstance(data, (bytes, bytearray)) else data


# ---------------------------------------------------------------------------
# CDP helper
# ---------------------------------------------------------------------------

class CDPClient:
    """Minimal Chrome DevTools Protocol client."""

    def __init__(self):
        self.sock = None
        self.msg_id = 0

    def connect(self):
        """Connect to Chromium's first page target via CDP WebSocket."""
        # Get the list of targets
        conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=5)
        conn.request("GET", "/json")
        resp = conn.getresponse()
        targets = json.loads(resp.read())
        conn.close()

        # Find a page target
        ws_url = None
        for t in targets:
            if t.get("type") == "page":
                ws_url = t.get("webSocketDebuggerUrl")
                break

        if not ws_url:
            raise RuntimeError("No page target found")

        self.sock = ws_connect(ws_url)

    def send(self, method, params=None):
        """Send a CDP command (fire-and-forget)."""
        if not self.sock:
            return
        self.msg_id += 1
        msg = {"id": self.msg_id, "method": method}
        if params:
            msg["params"] = params
        ws_send(self.sock, json.dumps(msg))
        # Drain the response (we don't need it but must read to avoid backpressure)
        try:
            self.sock.setblocking(False)
            try:
                ws_recv(self.sock)
            except BlockingIOError:
                pass
            finally:
                self.sock.setblocking(True)
        except Exception:
            pass

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def handle_message(cdp, msg):
    """Process a JSON message from the host."""
    msg_type = msg.get("type")
    text = msg.get("text", "")

    if msg_type == "compose":
        # Show inline composition (underlined text in the browser)
        cdp.send("Input.imeSetComposition", {
            "text": text,
            "selectionStart": len(text),
            "selectionEnd": len(text),
        })
    elif msg_type == "commit":
        # Insert final committed text
        cdp.send("Input.insertText", {"text": text})
    elif msg_type == "clear":
        # Cancel composition
        cdp.send("Input.imeSetComposition", {
            "text": "",
            "selectionStart": 0,
            "selectionEnd": 0,
        })
    elif msg_type in ("keyDown", "keyUp", "rawKeyDown", "char"):
        # Forward passthrough key events (backspace, arrows, Enter, etc.)
        key = msg.get("key", "")
        params = {
            "type": msg_type,
            "key": key,
        }
        if msg.get("code"):
            params["code"] = msg["code"]
        if msg.get("vk"):
            vk = int(msg["vk"])
            params["windowsVirtualKeyCode"] = vk
            params["nativeVirtualKeyCode"] = vk
        if msg.get("text"):
            params["text"] = msg["text"]
        # Map modifier flags
        modifiers = 0
        if msg.get("shift"): modifiers |= 8
        if msg.get("ctrl"):  modifiers |= 4
        if msg.get("alt"):   modifiers |= 1
        if msg.get("meta"):  modifiers |= 2
        if modifiers:
            params["modifiers"] = modifiers
        cdp.send("Input.dispatchKeyEvent", params)
    else:
        print(f"cjk-input-agent: unknown message type: {msg_type}", file=sys.stderr)


def main():
    # Wait for Chromium's CDP port
    print("cjk-input-agent: waiting for Chromium CDP...", file=sys.stderr)
    for _ in range(120):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect((CDP_HOST, CDP_PORT))
            s.close()
            break
        except (ConnectionRefusedError, OSError):
            s.close()
            time.sleep(1)
    else:
        print("cjk-input-agent: CDP not ready after 120s, exiting", file=sys.stderr)
        return

    cdp = CDPClient()

    while True:
        try:
            # (Re)connect to CDP if needed
            if not cdp.sock:
                try:
                    cdp.connect()
                    print("cjk-input-agent: connected to CDP", file=sys.stderr)
                except Exception as e:
                    print(f"cjk-input-agent: CDP connect failed: {e}", file=sys.stderr)
                    time.sleep(2)
                    continue

            # Listen for host messages on vsock
            srv = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
            srv.listen(1)

            while True:
                conn, _ = srv.accept()
                try:
                    data = conn.recv(4096)
                    if not data:
                        continue
                    text = data.decode("utf-8")
                    try:
                        msg = json.loads(text)
                    except json.JSONDecodeError:
                        # Legacy plain-text protocol: treat as commit
                        msg = {"type": "commit", "text": text}

                    handle_message(cdp, msg)
                except Exception as e:
                    print(f"cjk-input-agent: message error: {e}", file=sys.stderr)
                    # CDP connection may have broken — reconnect next iteration
                    cdp.close()
                finally:
                    conn.close()

        except Exception as e:
            print(f"cjk-input-agent: error: {e}", file=sys.stderr)
            cdp.close()
            time.sleep(1)


if __name__ == "__main__":
    main()

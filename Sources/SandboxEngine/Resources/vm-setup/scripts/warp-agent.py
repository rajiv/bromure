#!/usr/bin/python3 -u
"""Bromure WARP control agent — runs inside the guest VM.

Listens on vsock port 5700 for JSON commands from the host to
dynamically control Cloudflare WARP (connect/disconnect/status).

Protocol: newline-delimited JSON on vsock port 5700.

Commands from host:
  {"type":"status"}
  {"type":"enable"}
  {"type":"disable"}

Responses to host:
  {"type":"status","state":"connected"|"disconnected"|"not_installed"|"error","error":"..."}
  {"type":"enable","ok":true|false,"error":"..."}
  {"type":"disable","ok":true|false,"error":"..."}

Squid always runs through proxychains pointing to socks5://127.0.0.1:40000.
When WARP is disabled, direct-socks.py occupies port 40000 (transparent
forwarding).  When WARP is enabled, direct-socks is stopped and warp-svc
takes over port 40000.

Started at boot via inittab (runs as root).
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time

VSOCK_PORT = 5700
HOST_CID = 2

WARP_SVC = "/bin/warp-svc"
WARP_CLI = "/bin/warp-cli"
RESOLV_STUB = "/usr/lib/libresolv_stub.so"

# WARP is a glibc binary on musl Alpine — needs the resolver stub.
# Force C locale so warp-cli output is always English.
WARP_ENV = dict(os.environ, LD_PRELOAD=RESOLV_STUB,
                LANG="C", LC_ALL="C", LANGUAGE="C")

LOG_FILE = "/tmp/bromure/warp-agent.log"


def log(msg):
    """Log to stderr (visible in inittab output) and to a file for post-mortem."""
    line = f"warp-agent: {msg}"
    print(line, file=sys.stderr)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def run(cmd, env=None, quiet=False):
    """Run a shell command, return (returncode, stdout, stderr).

    Logs the command and output unless ``quiet`` is True (used for
    high-frequency polling like pgrep).
    """
    if not quiet:
        log(f"  exec: {cmd}")
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=15, env=env)
    except subprocess.TimeoutExpired:
        log(f"  TIMEOUT after 15s: {cmd}")
        return 1, "", "command timed out"
    if not quiet:
        if r.returncode != 0:
            log(f"  rc={r.returncode} stdout={r.stdout.strip()!r} stderr={r.stderr.strip()!r}")
        else:
            log(f"  rc=0 stdout={r.stdout.strip()!r}")
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def warp_installed():
    """Check whether warp-cli and warp-svc binaries exist."""
    svc = os.path.isfile(WARP_SVC)
    cli = os.path.isfile(WARP_CLI)
    stub = os.path.isfile(RESOLV_STUB)
    log(f"warp_installed: svc={svc} cli={cli} stub={stub}")
    return svc and cli


def warp_svc_running():
    """Check whether warp-svc process is running."""
    rc, out, _ = run("pgrep -f '[w]arp-svc'", quiet=True)
    return rc == 0


def dbus_running():
    """Check whether dbus-daemon is running (required by warp-svc)."""
    rc, _, _ = run("pgrep -x dbus-daemon", quiet=True)
    return rc == 0


def warp_status():
    """Query warp-cli for connection status.

    Returns one of: "connected", "connecting", "disconnected",
    "not_installed", "error".
    On error, also returns the error message.
    """
    if not warp_installed():
        return "not_installed", "warp-cli/warp-svc not found"

    if not warp_svc_running():
        return "disconnected", None

    rc, out, err = run(f"{WARP_CLI} --accept-tos status", env=WARP_ENV, quiet=True)
    if rc != 0:
        return "error", err or out or "warp-cli status failed"

    lower = out.lower()
    if "connecting" in lower or "happy eyeballs" in lower:
        return "connecting", None
    elif "connected" in lower and "disconnected" not in lower:
        return "connected", None
    elif "disconnected" in lower or "registration missing" in lower:
        return "disconnected", None
    else:
        return "error", out


DIRECT_SOCKS = "/usr/local/bin/direct-socks.py"


def stop_direct_socks():
    """Stop the direct SOCKS5 proxy to free port 40000 for warp-svc."""
    log("stopping direct-socks...")
    run("pid=$(pgrep -f '[d]irect-socks'); test -n \"$pid\" && kill $pid", quiet=True)
    # Wait for port to be released
    for _ in range(20):
        rc, _, _ = run("pgrep -f '[d]irect-socks'", quiet=True)
        if rc != 0:
            break
        time.sleep(0.1)


def start_direct_socks():
    """Start the direct SOCKS5 proxy on port 40000 (transparent forwarding)."""
    log("starting direct-socks...")
    proc = subprocess.Popen(
        [DIRECT_SOCKS],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"  direct-socks started (pid {proc.pid})")


def do_enable():
    """Stop direct-socks, start warp-svc on :40000, and connect."""
    log("do_enable: starting")

    if not warp_installed():
        return False, "warp-cli/warp-svc not found"

    # Ensure dbus is running (warp-svc needs it)
    if not dbus_running():
        log("dbus not running, cleaning up stale pid file and starting it")
        run("rm -f /run/dbus/dbus.pid", quiet=True)
        run("/usr/bin/dbus-daemon --system")
        time.sleep(0.5)
        if not dbus_running():
            log("WARNING: dbus-daemon failed to start")

    # Free port 40000 — stop direct-socks so warp-svc can bind it
    stop_direct_socks()

    # Start warp-svc if not already running
    if not warp_svc_running():
        # Clean up stale sockets/pid files from previous runs
        run("rm -f /run/cloudflare-warp/warp-svc.sock", quiet=True)
        log("starting warp-svc...")
        # Capture stderr to a log file for debugging
        svc_log_path = "/tmp/bromure/warp-svc.log"
        svc_log = open(svc_log_path, "a")
        proc = subprocess.Popen(
            [WARP_SVC],
            env=WARP_ENV,
            stdout=svc_log,
            stderr=svc_log)
        log(f"warp-svc spawned (pid {proc.pid}), waiting for it to be ready...")

        # Wait for it to appear in the process table
        started = False
        for i in range(30):
            time.sleep(0.3)
            if warp_svc_running():
                log(f"warp-svc ready after {(i+1)*0.3:.1f}s")
                started = True
                break
            # Check if it exited already
            ret = proc.poll()
            if ret is not None:
                svc_log.close()
                log(f"warp-svc exited immediately with code {ret}")
                try:
                    with open(svc_log_path) as f:
                        tail = f.read()[-500:]
                    log(f"warp-svc.log tail: {tail}")
                except OSError:
                    pass
                return False, f"warp-svc exited with code {ret}"

        # Close our copy of the log fd — warp-svc inherited it
        svc_log.close()

        if not started:
            log("warp-svc did not appear after 9s")
            return False, "warp-svc failed to start (timeout)"

        # Extra settle time for dbus registration
        log("waiting 1s for dbus registration...")
        time.sleep(1)

    # Check status / register if needed
    log("checking warp-cli status...")
    rc, out, err = run(f"{WARP_CLI} --accept-tos status", env=WARP_ENV)
    combined = (out + " " + err).lower()

    if "registration" in combined and "missing" in combined:
        log("registration missing, registering...")
        run(f"{WARP_CLI} --accept-tos registration new", env=WARP_ENV)
        log("setting proxy mode...")
        run(f"{WARP_CLI} --accept-tos mode proxy", env=WARP_ENV)
        time.sleep(1)

    # Connect
    log("connecting...")
    rc, out, err = run(f"{WARP_CLI} --accept-tos connect", env=WARP_ENV)
    if rc != 0:
        return False, err or out or "warp-cli connect failed"

    # Poll until connected (may go through "connecting" / happy eyeballs)
    log("waiting for connection...")
    for i in range(30):
        time.sleep(1)
        state, msg = warp_status()
        log(f"  poll {i+1}: state={state}")
        if state == "connected":
            break
        elif state == "connecting":
            continue
        else:
            return False, msg or "WARP did not connect"
    else:
        return False, "WARP connection timed out (30s)"

    log("do_enable: success")
    return True, None


def do_disable():
    """Disconnect WARP, kill warp-svc, and start direct-socks on :40000."""
    log("do_disable: starting")

    if not warp_installed():
        log("WARP not installed, ensuring direct-socks is running")
        start_direct_socks()
        return True, None

    # Disconnect
    if warp_svc_running():
        log("disconnecting warp-cli...")
        run(f"{WARP_CLI} --accept-tos disconnect", env=WARP_ENV)

    # Kill warp-svc to free port 40000 and memory
    log("killing warp-svc...")
    run("pid=$(pgrep -f '[w]arp-svc'); test -n \"$pid\" && kill $pid")
    time.sleep(0.3)
    run("rm -f /run/cloudflare-warp/warp-svc.sock", quiet=True)

    # Start direct-socks on :40000 so squid keeps working
    start_direct_socks()

    log("do_disable: success")
    return True, None


def handle_message(msg, sock):
    """Process a JSON command and return a JSON response dict.

    ``sock`` is passed so long-running commands (enable) can send
    intermediate status updates to the host.
    """
    msg_type = msg.get("type")
    log(f"handling command: {msg_type}")

    if msg_type == "status":
        state, error = warp_status()
        resp = {"type": "status", "state": state}
        if error:
            resp["error"] = error
        log(f"status result: {resp}")
        return resp

    elif msg_type == "enable":
        # Notify host that we're connecting before blocking
        send_json(sock, {"type": "status", "state": "connecting"})
        ok, error = do_enable()
        resp = {"type": "enable", "ok": ok}
        if error:
            resp["error"] = error
        log(f"enable result: {resp}")
        return resp

    elif msg_type == "disable":
        ok, error = do_disable()
        resp = {"type": "disable", "ok": ok}
        if error:
            resp["error"] = error
        log(f"disable result: {resp}")
        return resp

    return {"type": "error", "error": f"unknown command: {msg_type}"}


def send_json(sock, obj):
    """Send a newline-delimited JSON message."""
    data = json.dumps(obj, separators=(",", ":")).encode() + b"\n"
    sock.sendall(data)


MAX_BUF = 1_048_576  # 1 MB — cap receive buffer to prevent memory exhaustion


def run_session():
    """Connect to the host, handle commands, return on disconnect."""
    # Connect to host (retry until host listener is ready)
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            break
        except (ConnectionRefusedError, ConnectionResetError, OSError):
            s.close()
            time.sleep(0.5)

    log("connected to host")

    # Auto-connect if config-agent wrote the marker
    auto_marker = "/tmp/bromure/warp-auto-connect"
    if os.path.exists(auto_marker):
        log("auto-connect marker found, enabling WARP...")
        try:
            os.unlink(auto_marker)
        except OSError:
            pass
        send_json(s, {"type": "status", "state": "connecting"})
        ok, error = do_enable()
        if ok:
            send_json(s, {"type": "status", "state": "connected"})
            log("auto-connect succeeded")
        else:
            send_json(s, {"type": "status", "state": "error", "error": error})
            log(f"auto-connect failed: {error}")

    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
            if not chunk:
                log("host disconnected")
                break
            buf += chunk

            # Cap buffer to prevent memory exhaustion
            if len(buf) > MAX_BUF:
                log("receive buffer overflow, disconnecting")
                break

            # Process complete newline-delimited messages
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    log(f"invalid JSON: {line!r}")
                    continue

                resp = handle_message(msg, s)
                send_json(s, resp)

        except (ConnectionError, OSError) as e:
            log(f"connection error: {e}")
            break

    s.close()


def main():
    os.makedirs("/tmp/bromure", exist_ok=True)
    log(f"starting (pid={os.getpid()}, uid={os.getuid()}, euid={os.geteuid()})")

    while True:
        run_session()
        log("reconnecting in 1s...")
        time.sleep(1)


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    main()

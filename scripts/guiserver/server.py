#!/usr/bin/env python3
"""
server.py - Backend for the Pager Control Panel.

This server does NOT implement any Pineapple/WiFi/recon logic itself - it
is a thin HTTP control surface that shells out to the same /root/scripts/
*.sh files already verified to work (which themselves only ever call
official Hak5 WIFI_*/PINEAPPLE_*/PAYLOAD_* commands). Nothing here bypasses
or reimplements those commands.

Security posture, matching how Hak5 already treats the Virtual Pager:
  - Binds ONLY to br-lan (172.16.52.1) - the Management WiFi / USB-C
    network - never to the internet-facing uplink (eth1/wlan0). This
    mirrors the Pager's own firewall docs: admin surfaces are restricted
    to USB-C and Management WiFi by design.
  - Requires a token (set once via `webui --set-token`, or auto-generated
    on first `gui` launch; stored in the official PAYLOAD_*_CONFIG store)
    passed as the `X-Pager-Token` header or `?token=` query param. Plain
    HTTP, no TLS - same caveat the Hak5 docs give for the Virtual Pager
    itself.

Run: python3 server.py [port]   (default port 8081)
"""
import http.server
import json
import os
import secrets
import subprocess
import sys
import urllib.parse

SCRIPTS_DIR = "/root/scripts"
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
CFG_NS = "webui"
BIND_HOST = "172.16.52.1"  # br-lan only - Management WiFi / USB-C, never the uplink
DEFAULT_PORT = 8081

ALLOWED_SCRIPTS = {
    "wifi.sh", "connect.sh", "battery.sh", "EvilTwin.sh", "LanScan.sh",
    "config.sh", "PayloadRunner.sh", "mgmt.sh", "openap.sh", "mimic.sh",
    "filters.sh", "ssidpool.sh", "deauth.sh", "examine.sh", "bands.sh",
    "reconsession.sh", "pcap.sh", "wigle.sh", "gps.sh", "loot.sh",
    "clientip.sh", "vpn.sh", "autossh.sh", "dnsspoof.sh", "ringtone.sh",
    "alert.sh", "screen.sh", "led.sh", "dns.sh",
    # Added later than the rest of this list - sniff.sh, bluetooth.sh, and
    # pc_link.sh existed as CLI scripts but were never added here, so the
    # Control Panel couldn't run any of them at all (run_script() denies
    # anything not in this set). deadnet.sh is deliberately NOT added -
    # it's a long ARP-poison run meant to be launched carefully (payload/
    # SSH with its own discovery-first flow), not a generic GUI button.
    "sniff.sh", "bluetooth.sh", "pc_link.sh", "report.sh",
    # tracer.sh (live packet trace) - allowlisted for parity with the
    # others above even though the GUI's own HTML/JS wiring for it is
    # intentionally not built out this round (deprioritized per standing
    # instruction) - at minimum this stops it being silently unreachable
    # if invoked via a raw /api/run call.
    "tracer.sh",
    # TINY BUG FOUND AND FIXED: reset.sh (the toolkit's own operator
    # recovery/utility script - restart the app, clear a WiFi channel
    # lock, reset a stuck Bluetooth radio, tear down a leftover bridge)
    # had no comment explaining its absence the way deadnet.sh/
    # crash_logger.sh/usb_monitor.sh above do - it looked like a plain
    # oversight rather than a deliberate exclusion, so a raw /api/run call
    # for it was silently denied with no way to reach it from the Control
    # Panel at all.
    "reset.sh",
}


def cfg_get(key):
    try:
        out = subprocess.run(
            ["PAYLOAD_GET_CONFIG", CFG_NS, key],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def run_script(name, args, timeout=60, background=False):
    if name not in ALLOWED_SCRIPTS:
        return {"rc": 1, "stdout": "", "stderr": f"'{name}' is not an allowed script"}
    path = os.path.join(SCRIPTS_DIR, name)
    if not os.path.isfile(path):
        return {"rc": 1, "stdout": "", "stderr": f"{path} not found"}
    cmd = ["bash", path] + list(args)
    if background:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"rc": 0, "stdout": "started in background", "stderr": ""}
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"rc": p.returncode, "stdout": p.stdout, "stderr": p.stderr}
    except subprocess.TimeoutExpired:
        return {"rc": 124, "stdout": "", "stderr": f"timed out after {timeout}s"}


# BIG CHANGE: /api/run's subprocess.run(...) BLOCKS the whole HTTP request
# until the command finishes (or times out) before returning ANY output at
# all - for a long-running background attack/capture launched from the
# Control Panel, the UI has no way to show progress until the entire run is
# over. This is the exact same "black box, no feedback until it's done"
# problem this session's other UX fixes were all about (sniff.sh's live-
# tail, PayloadRunner.sh's --status) - the Control Panel's own API had it
# too. Every backgrounded script here already writes to a well-known log
# file, so this exposes a safe, READ-ONLY, explicitly allowlisted tail of
# those specific files (never arbitrary filesystem access) letting the
# frontend poll for live output instead of getting nothing until the whole
# run ends. Same "poll by line count, return only what's new" pattern
# already proven safe in sniff.sh/deauth.sh's own log watchers this session
# - never blocks, never follows forever.
LOG_FILES = {
    "deauth.sh": "/tmp/pager-deauth.log",
    "sniff.sh": "/tmp/pager-sniff.log",
    "bluetooth.sh": "/tmp/pager-bluetooth.log",
    "crash_logger.sh": "/mmc/crash_dmesg.log",
}


def tail_log(name, since_line):
    path = LOG_FILES.get(name)
    if not path or not os.path.isfile(path):
        return {"lines": [], "total": 0, "error": "no known log file for this script"}
    try:
        with open(path, "r", errors="replace") as f:
            all_lines = f.readlines()
    except OSError as e:
        return {"lines": [], "total": 0, "error": str(e)}
    total = len(all_lines)
    since_line = max(0, since_line)
    new_lines = [line.rstrip("\n") for line in all_lines[since_line:]]
    return {"lines": new_lines, "total": total}


def require_token(handler):
    expected = cfg_get("token")
    if not expected:
        # No token configured yet - refuse everything except the setup hint.
        return False
    got = handler.headers.get("X-Pager-Token", "")
    if not got:
        qs = urllib.parse.urlparse(handler.path).query
        got = urllib.parse.parse_qs(qs).get("token", [""])[0]
    return secrets.compare_digest(got, expected)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "PagerControlPanel/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[webui] " + (fmt % args) + "\n")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            self._send_file(os.path.join(STATIC_DIR, "index.html"), "text/html; charset=utf-8")
            return
        if path == "/app.js":
            self._send_file(os.path.join(STATIC_DIR, "app.js"), "application/javascript; charset=utf-8")
            return
        if path == "/style.css":
            self._send_file(os.path.join(STATIC_DIR, "style.css"), "text/css; charset=utf-8")
            return

        if path == "/api/needs-setup":
            self._send_json({"needsSetup": cfg_get("token") == ""})
            return

        if not path.startswith("/api/"):
            self.send_error(404)
            return

        if not require_token(self):
            self._send_json({"error": "unauthorized - set a token first: webui --set-token"}, 401)
            return

        if path == "/api/status":
            result = {
                "battery": run_script("battery.sh", [], timeout=10)["stdout"].strip(),
                "wifi": run_script("wifi.sh", ["--status"], timeout=10)["stdout"],
                "eviltwin": run_script("EvilTwin.sh", ["--status"], timeout=10)["stdout"],
                "loot": run_script("loot.sh", ["--list"], timeout=10)["stdout"],
            }
            self._send_json(result)
            return

        if path == "/api/payloads":
            out = run_script("PayloadRunner.sh", ["--list"], timeout=15)
            self._send_json(out)
            return

        if path == "/api/tail":
            qs = urllib.parse.parse_qs(parsed.query)
            script = qs.get("script", [""])[0]
            try:
                since = int(qs.get("since", ["0"])[0])
            except ValueError:
                since = 0
            self._send_json(tail_log(script, since))
            return

        self.send_error(404)

    def do_POST(self):
        if not require_token(self):
            self._send_json({"error": "unauthorized"}, 401)
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json({"error": "bad json"}, 400)
            return
        if not isinstance(data, dict):
            self._send_json({"error": "request body must be a JSON object"}, 400)
            return

        path = urllib.parse.urlparse(self.path).path

        if path == "/api/run":
            script = data.get("script", "")
            args = data.get("args", [])
            background = bool(data.get("background", False))
            try:
                timeout = int(data.get("timeout", 60))
            except (TypeError, ValueError):
                self._send_json({"error": "timeout must be a number"}, 400)
                return
            if not isinstance(script, str):
                self._send_json({"error": "script must be a string"}, 400)
                return
            if not isinstance(args, list):
                self._send_json({"error": "args must be a list"}, 400)
                return
            result = run_script(script, [str(a) for a in args], timeout=timeout, background=background)
            self._send_json(result)
            return

        self.send_error(404)


def main():
    # TINY BUG FOUND AND FIXED: a non-numeric port (e.g. webui.sh --port
    # taking whatever string it's given, with no numeric check of its own)
    # used to raise an uncaught ValueError here - a raw traceback in
    # /tmp/pager-webui.log instead of a clean one-line reason. webui.sh
    # already reports "Failed to start - check the log" either way, so
    # this was never a SILENT failure, just an unpolished one.
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print(f"[gui] ERROR: '{sys.argv[1]}' is not a valid port number.")
            sys.exit(1)
    else:
        port = DEFAULT_PORT
    os.makedirs(STATIC_DIR, exist_ok=True)
    server = http.server.ThreadingHTTPServer((BIND_HOST, port), Handler)
    token = cfg_get("token")
    print(f"[gui] Pager Control Panel is up: http://{BIND_HOST}:{port}/?token={token or '<not set - run: webui.sh --set-token>'}")
    print("[gui] Management WiFi / USB-C only - not reachable from the internet uplink.")
    print("[gui] Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[gui] Shutting down...")
        server.shutdown()
        print("[gui] Stopped.")


if __name__ == "__main__":
    # Wrap the whole entry point, not just serve_forever() - on a slow
    # embedded device the very first launch spends a moment compiling
    # bytecode for the stdlib imports, and a Ctrl+C landing during that
    # window should still exit cleanly instead of dumping a traceback.
    try:
        main()
    except KeyboardInterrupt:
        print("\n[gui] Stopped.")
        sys.exit(0)

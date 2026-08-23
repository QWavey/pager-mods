#!/usr/bin/env python3
"""dismiss_alert.py - programmatically dismiss the Pager's on-screen ALERT
(or send any other key) by talking directly to the same local WebSocket
the physical A/B buttons and the Virtual Pager's own on-screen buttons use.

There is no official DuckyScript command to dismiss an ALERT - confirmed
this session (no BUTTON_PRESS binary exists on the device despite being
listed in Hak5's own generic docs, and no duration/timeout parameter
exists on ALERT itself). This exists because we needed one and there
wasn't an API for it.

Root-caused live: the real Pager UI (`/pineapple/pineapple`) exposes a
WebSocket at /api/pager/input/keys.ws that accepts the exact key names
the Virtual Pager web app's own on-screen buttons send (confirmed by
reading that app's own JS: keyws.send('Enter') for the physical A button,
keyws.send('Escape') for B). That endpoint is reachable two ways:
  - TCP :1471 (ws://<device-ip>:1471/api/pager/input/keys.ws) - requires
    the Virtual Pager's own login/session, not usable from a bare
    background script.
  - The local Unix socket /tmp/api.sock (world-connectable, root:root,
    mode 755) - the SAME socket hak5cmd itself uses for every DuckyScript
    command (ALERT, LOG, etc. are all symlinks to one binary,
    /usr/bin/hak5cmd, that talks HTTP over this socket). No auth required
    over this socket. This is the one used here.

No third-party WebSocket library exists in this device's stripped-down
python3 install, so the handshake and frame are done by hand with only
stdlib (socket/base64/struct) - RFC 6455's client handshake and a single
masked text frame, nothing else. Verified live: firing a real ALERT then
sending 'Enter' through this script reliably dismisses it.

Usage:
  dismiss_alert.py            send "Enter" (dismiss/confirm - the A button)
  dismiss_alert.py Enter      same, explicit
  dismiss_alert.py Escape     send "Escape" (cancel/back - the B button)

Exits 0 on a successful send (the frame reached the socket - this does
NOT guarantee anything was actually showing to dismiss, sending a key
with nothing on screen is a harmless no-op), non-zero on any connection/
handshake failure.
"""
import socket
import base64
import struct
import sys

SOCK_PATH = "/tmp/api.sock"
WS_PATH = "/api/pager/input/keys.ws"
CONNECT_TIMEOUT_SECS = 5


def send_key(key: str) -> bool:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(CONNECT_TIMEOUT_SECS)
    try:
        s.connect(SOCK_PATH)
    except OSError as e:
        print(f"dismiss_alert.py: can't connect to {SOCK_PATH}: {e}", file=sys.stderr)
        return False

    # RFC 6455 client handshake - the Sec-WebSocket-Key content itself
    # doesn't matter (it's not a security boundary, just an anti-cache/
    # anti-proxy-confusion nonce the spec requires), only that it's valid
    # base64 of 16 raw bytes.
    ws_key = base64.b64encode(b"dismiss-alert-py").decode()
    request = (
        f"GET {WS_PATH} HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {ws_key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    try:
        s.sendall(request.encode())
        response = s.recv(4096)
    except OSError as e:
        print(f"dismiss_alert.py: handshake I/O error: {e}", file=sys.stderr)
        s.close()
        return False

    status_line = response.split(b"\r\n", 1)[0]
    if b"101" not in status_line:
        print(f"dismiss_alert.py: handshake failed: {status_line!r}", file=sys.stderr)
        s.close()
        return False

    # A single unfragmented text frame (FIN=1, opcode=0x1). Client-to-
    # server frames must be masked per spec; the mask value itself is
    # arbitrary (it's a protocol-conformance requirement, not a security
    # feature over a local, unauthenticated Unix socket).
    payload = key.encode()
    mask = b"\x01\x02\x03\x04"
    frame = bytearray([0x81])
    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)
    else:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    frame.extend(mask)
    frame.extend(b ^ mask[i % 4] for i, b in enumerate(payload))

    try:
        s.sendall(bytes(frame))
    except OSError as e:
        print(f"dismiss_alert.py: send error: {e}", file=sys.stderr)
        s.close()
        return False

    s.close()
    return True


if __name__ == "__main__":
    key_to_send = sys.argv[1] if len(sys.argv) > 1 else "Enter"
    ok = send_key(key_to_send)
    sys.exit(0 if ok else 1)

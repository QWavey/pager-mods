#!/bin/bash
# wifite2.sh - driver for wifite2 on the Pager (approved idea WF1).
#
# wifite2 (github.com/derv82/wifite2) is a pure-Python automated wireless
# auditor that orchestrates the exact tools the Pager already has: aircrack-ng
# / airodump-ng / aireplay-ng (WPA handshakes), reaver + wash (WPS/Pixie),
# hcxdumptool + hcxpcapngtool (PMKID). Nothing to compile - this wrapper just
# runs it with the device's python3.11 and the right PATH/LD_LIBRARY_PATH, and
# steers it onto a monitor-capable radio (the external A8000 by preference, so
# it never fights PineAP on the internal radios).
#
# Usage:
#   wifite2.sh --install            clone wifite2 to /mmc + install deps (once)
#   wifite2.sh [wifite args...]     run it (e.g. --wpa, --pmkid, --wps, -i wlan2)
#   wifite2.sh                      interactive: scans, you pick targets
#
# With no -i, this auto-selects the external adapter if one is present; wifite2
# otherwise asks. Press Ctrl+C (or the on-screen B) to stop.
#
# Only against networks you own or are authorized to test.

set -u
TOOL_NAME="wifite2.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

WF_DIR="/mmc/wifite2"
PY="/mmc/usr/bin/python3.11"
export PATH="/mmc/usr/bin:/mmc/usr/sbin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"

# --install : provision wifite2 and the tools it drives onto /mmc.
if [ "${1:-}" = "--install" ]; then
    say "Installing wifite2 dependencies (opkg -> /mmc)..."
    opkg update >/dev/null 2>&1
    opkg install -d mmc aircrack-ng hcxdumptool reaver wireless-tools 2>&1 | grep -iE "Installing|configuring|up to date" || true
    say "Cloning wifite2 into $WF_DIR..."
    rm -rf "$WF_DIR"
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 https://github.com/derv82/wifite2.git "$WF_DIR" 2>&1 | tail -2
    else
        wget -qO /tmp/wifite2.tgz https://github.com/derv82/wifite2/archive/refs/heads/master.tar.gz \
            && mkdir -p "$WF_DIR" && tar xzf /tmp/wifite2.tgz -C "$WF_DIR" --strip-components=1
    fi
    [ -f "$WF_DIR/Wifite.py" ] && say "wifite2 installed at $WF_DIR." || die "wifite2 install failed."
    exit 0
fi

[ -f "$WF_DIR/Wifite.py" ] || die "wifite2 not installed - run: wifite2.sh --install"
[ -x "$PY" ] || die "python3.11 not found at $PY (run the toolkit setup.py first)."

# external_wifi_iface - first non-internal wlan (wlan2+, i.e. the A8000).
external_wifi_iface() {
    local i
    for i in /sys/class/net/wlan[2-9]; do [ -e "$i" ] && { basename "$i"; return 0; }; done
    return 1
}

# If the caller didn't pass -i, steer wifite onto the external adapter when we
# have one (keeps it off the internal PineAP radios). If none, let wifite ask.
have_i=0
for a in "$@"; do [ "$a" = "-i" ] && have_i=1; done
EXTRA=""
if [ "$have_i" = "0" ]; then
    ext=$(external_wifi_iface)
    if [ -n "$ext" ]; then
        EXTRA="-i $ext"
        say "Using external adapter $ext (pass -i <iface> to override)."
    else
        say "No external adapter found - wifite2 will ask which interface to use."
        say "(Plug in the A8000 for a dedicated capture radio that won't disturb PineAP.)"
    fi
fi

cd "$WF_DIR" || die "Cannot enter $WF_DIR."
say "Launching wifite2 - Ctrl+C / on-screen B to stop."
exec "$PY" "$WF_DIR/Wifite.py" $EXTRA "$@"

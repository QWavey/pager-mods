#!/bin/bash
# airscout.sh - passive 802.11 recon (probe-request client fingerprinting +
# AP/PMF enumeration) for the WiFi Pineapple Pager. Thin wrapper around
# lib/airscout.py (scapy). Listens only, never transmits - safe to run any
# time on the internal monitor interface without disrupting anything.
#
# Covers approved ideas W13 (client OS/device fingerprint from the air) and
# feeds W9 (PMF posture) / W12 (which APs are soft) target selection.
#
# Usage:
#   airscout.sh [--mode both|probes|aps] [--iface wlan1mon] [--seconds 20] [--channel N]
#
# --channel sets the monitor iface to a fixed channel first (default: leave it
# wherever it is). Output also saved to /root/loot/airscout/.
#
# IMPORTANT: passive recon; only in environments you're authorized to survey.

set -u
TOOL_NAME="airscout.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

IFACE="wlan1mon"; SECONDS_ARG="20"; MODE="both"; CHANNEL=""
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="${2:-}"; shift 2 ;;
        --seconds) SECONDS_ARG="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
case "$SECONDS_ARG" in ''|*[!0-9]*) die "--seconds must be an integer." ;; esac

[ -e "/sys/class/net/$IFACE" ] || die "Interface $IFACE not present (need a monitor interface; wlan1mon is the internal default)."

if [ -n "$CHANNEL" ]; then
    case "$CHANNEL" in *[!0-9]*) die "--channel must be numeric." ;; esac
    iw dev "$IFACE" set channel "$CHANNEL" 2>/dev/null || say "Could not set channel $CHANNEL (continuing on the current one)."
fi

PY=$(resolve_python3) || die "python3 not installed. opkg install -d mmc python3"
LOOT_DIR="/root/loot/airscout"; mkdir -p "$LOOT_DIR" 2>/dev/null
OUT="$LOOT_DIR/airscout-$(date +%Y%m%d-%H%M%S).txt"

say "Listening on $IFACE for ${SECONDS_ARG}s (mode: $MODE)..."
$PY "$SCRIPT_DIR/lib/airscout.py" --iface "$IFACE" --seconds "$SECONDS_ARG" --mode "$MODE" --out "$OUT"
say "Saved: $OUT"

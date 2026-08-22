#!/bin/bash
# pcap.sh - Start/stop the Pineapple's optimized WiFi packet capture.
# Wraps WIFI_PCAP_START / WIFI_PCAP_STOP.
#
# Usage:
#   pcap.sh --on          start capture
#   pcap.sh --off          stop capture
#   pcap.sh --list           list captured pcap files
#   pcap.sh                    interactive mode

set -u
TOOL_NAME="pcap.sh"
LOOT_DIR="/root/loot/pcap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh): --on/--off printed a
# success message unconditionally regardless of WIFI_PCAP_START/_STOP's
# real exit code.
case "${1:-}" in
    --on) f=$(WIFI_PCAP_START) && say "Capture started: ${f:-see $LOOT_DIR}" || die "Failed to start capture." ;;
    --off) WIFI_PCAP_STOP && say "Capture stopped." || die "Failed to stop capture." ;;
    --list) ls -la "$LOOT_DIR" 2>/dev/null || say "No captures yet." ;;
    -h|--help) usage ;;
    "")
        echo "== pcap.sh =="
        echo "1) Start capture  2) Stop capture  3) List captures"
        c=$(ask "Choose" "3")
        case "$c" in
            1) f=$(WIFI_PCAP_START) && say "Capture started: ${f:-see $LOOT_DIR}" || err "Failed to start capture." ;;
            2) WIFI_PCAP_STOP && say "Capture stopped." || err "Failed to stop capture." ;;
            *) ls -la "$LOOT_DIR" 2>/dev/null || say "No captures yet." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

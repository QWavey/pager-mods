#!/bin/bash
# mimic.sh - Toggle PineAP mimic mode (karma - answer ANY probed SSID on
# the Open AP). Wraps PINEAPPLE_MIMIC_ENABLE / PINEAPPLE_MIMIC_DISABLE.
#
# Usage:
#   mimic.sh --on
#   mimic.sh --off
#   mimic.sh                interactive mode

set -u
TOOL_NAME="mimic.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review - same "silent on failure"
# class already fixed throughout this codebase - dns.sh/dnsspoof.sh/
# gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh/ssidpool.sh/screen.sh/
# vpn.sh/wigle.sh all document this exact fix - this file was missed
# entirely). Every branch here used `&&` for the success message but had
# no `||` at all - if PINEAPPLE_MIMIC_ENABLE/_DISABLE failed, the script
# did nothing whatsoever: no success message, no error, no indication of
# any kind that the command didn't work.
case "${1:-}" in
    --on) PINEAPPLE_MIMIC_ENABLE && say "Mimic mode on." || die "Failed to enable mimic mode." ;;
    --off) PINEAPPLE_MIMIC_DISABLE && say "Mimic mode off." || die "Failed to disable mimic mode." ;;
    -h|--help) usage ;;
    "")
        echo "== mimic.sh =="
        if confirm "Enable PineAP mimic mode (answer ANY probed SSID)?"; then
            PINEAPPLE_MIMIC_ENABLE && say "Mimic mode on." || err "Failed to enable mimic mode."
        else
            PINEAPPLE_MIMIC_DISABLE && say "Mimic mode off." || err "Failed to disable mimic mode."
        fi
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

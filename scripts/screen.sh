#!/bin/bash
# screen.sh - Turn the Pager's physical display on/off. Wraps
# ENABLE_DISPLAY / DISABLE_DISPLAY (documented as simple no-argument
# toggles in the Hak5 DuckyScript command table).
#
# Usage:
#   screen.sh --on
#   screen.sh --off
#   screen.sh                interactive mode

set -u
TOOL_NAME="screen.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh/
# ssidpool.sh): --on/--off printed a success message unconditionally
# regardless of ENABLE_DISPLAY/DISABLE_DISPLAY's real exit code.
case "${1:-}" in
    --on) ENABLE_DISPLAY && say "Display on." || die "Failed to turn the display on." ;;
    --off) DISABLE_DISPLAY && say "Display off." || die "Failed to turn the display off." ;;
    -h|--help) usage ;;
    "")
        # CONSISTENCY FIX (found via code review - same gap already fixed
        # for --on/--off above, missed here): interactive mode had no
        # feedback at all, unlike the CLI path this exact file already
        # fixed for the same underlying commands.
        r=$(ask "Turn display on or off? (on/off)" "on")
        case "$r" in
            off) DISABLE_DISPLAY && say "Display off." || err "Failed to turn the display off." ;;
            *) ENABLE_DISPLAY && say "Display on." || err "Failed to turn the display on." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

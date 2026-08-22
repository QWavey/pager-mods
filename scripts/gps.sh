#!/bin/bash
# gps.sh - List/configure the USB GPS receiver, show live status. Wraps
# GPS_LIST / GPS_CONFIGURE plus the standard `cgps` tool the docs point to
# for live status (not Pineapple-specific, but the documented way to check).
#
# Usage:
#   gps.sh --list                       list available GPS serial devices
#   gps.sh --configure PORT BAUD          configure serial port + baud rate
#   gps.sh --watch                          live status via cgps (Ctrl+C to exit)
#   gps.sh                                    interactive mode

set -u
TOOL_NAME="gps.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

case "${1:-}" in
    --list) GPS_LIST ;;
    # BUG FOUND AND FIXED (found via code review, same class as dns.sh/
    # dnsspoof.sh): this printed "GPS configured." unconditionally
    # regardless of GPS_CONFIGURE's actual exit code.
    --configure) shift; [ $# -lt 2 ] && die "--configure needs PORT and BAUD"; GPS_CONFIGURE "$1" "$2" && say "GPS configured. Restart GPSd if the change doesn't take effect." || die "Failed to configure GPS on $1 @ $2." ;;
    --watch)
        if command -v cgps >/dev/null 2>&1; then cgps; else die "cgps is not installed on this device."; fi
        ;;
    -h|--help) usage ;;
    "")
        echo "== gps.sh =="
        echo "1) List GPS devices  2) Configure port/baud  3) Watch live status"
        c=$(ask "Choose" "1")
        case "$c" in
            1) GPS_LIST ;;
            # CONSISTENCY FIX (found via code review - same gap already
            # fixed for --configure above, missed here).
            2) p=$(ask "Serial port path" ""); b=$(ask "Baud rate (4800/9600/115200)" "9600"); GPS_CONFIGURE "$p" "$b" && say "GPS configured. Restart GPSd if the change doesn't take effect." || err "Failed to configure GPS on $p @ $b." ;;
            3) if command -v cgps >/dev/null 2>&1; then cgps; else say "cgps not installed."; fi ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

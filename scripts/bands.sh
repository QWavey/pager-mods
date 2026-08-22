#!/bin/bash
# bands.sh - Set which WiFi bands recon monitors. Wraps
# PINEAPPLE_SET_BANDS [interface] {2} {5} {6}.
#
# Usage:
#   bands.sh --iface wlan1mon --2 --5          monitor 2.4GHz + 5GHz only
#   bands.sh --iface wlan1mon --2 --5 --6       monitor all bands
#   bands.sh                                      interactive mode (default iface: wlan1mon)

set -u
TOOL_NAME="bands.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

IFACE="wlan1mon"; B2=0; B5=0; B6=0; ANY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) need_arg "--iface" "$#"; IFACE="$2"; shift 2 ;;
        --2) B2=1; ANY=1; shift ;;
        --5) B5=1; ANY=1; shift ;;
        --6) B6=1; ANY=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

if [ "$ANY" = "0" ]; then
    echo "== bands.sh =="
    IFACE=$(ask "Monitor interface" "$IFACE")
    confirm "Monitor 2.4GHz?" && B2=1
    confirm "Monitor 5GHz?" && B5=1
    confirm "Monitor 6GHz?" && B6=1
fi

# BUG FOUND AND FIXED (found via code review): if every band is left off
# (interactive: answering no to all three; CLI: --iface with no --2/--5/--6
# at all won't reach here since ANY stays 0 and it goes interactive instead,
# but zero bands is still reachable by answering "no" three times) this
# silently called PINEAPPLE_SET_BANDS with no band arguments at all, which
# per Hak5's docs disables recon channel hopping on this interface entirely
# - "Bands set" then prints as if it succeeded normally, with no hint that
# recon just went dark on that radio.
if [ "$B2" = "0" ] && [ "$B5" = "0" ] && [ "$B6" = "0" ]; then
    confirm "No bands selected - this disables recon channel hopping on $IFACE entirely. Proceed?" || die "Aborted."
fi

ARGS="$IFACE"
[ "$B2" = "1" ] && ARGS="$ARGS 2"
[ "$B5" = "1" ] && ARGS="$ARGS 5"
[ "$B6" = "1" ] && ARGS="$ARGS 6"

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh/
# ssidpool.sh/screen.sh/vpn.sh/wigle.sh/report.sh - this file was missed):
# PINEAPPLE_SET_BANDS's real exit code was never checked at all - "Bands
# set" printed unconditionally even if the underlying command failed,
# which would be a particularly quiet failure here since a bad --iface
# means recon silently keeps hopping on whatever bands it was already set
# to, with no indication the requested change didn't take.
# shellcheck disable=SC2086
PINEAPPLE_SET_BANDS $ARGS && say "Bands set on $IFACE." || die "Failed to set bands on $IFACE - check the interface name (e.g. wlan1mon)."

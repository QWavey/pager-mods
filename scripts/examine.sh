#!/bin/bash
# examine.sh - Lock recon to a single channel/BSSID (helps handshake
# collection) or resume normal hopping. Wraps PINEAPPLE_EXAMINE_BSSID /
# PINEAPPLE_EXAMINE_CHANNEL / PINEAPPLE_EXAMINE_RESET.
#
# Usage:
#   examine.sh --bssid AA:BB:CC:DD:EE:FF [--time SECONDS]
#   examine.sh --channel 6 [--time SECONDS]
#   examine.sh --reset
#   examine.sh                interactive mode

set -u
TOOL_NAME="examine.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

BSSID=""; CHANNEL=""; TIME=""; DO_RESET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bssid) need_arg "--bssid" "$#"; BSSID="$2"; shift 2 ;;
        --channel) need_arg "--channel" "$#"; CHANNEL="$2"; shift 2 ;;
        --time) need_arg "--time" "$#"; TIME="$2"; shift 2 ;;
        --reset) DO_RESET=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

if [ "$DO_RESET" = "1" ]; then
    PINEAPPLE_EXAMINE_RESET
    say "Resumed normal channel hopping."
    exit 0
fi

# BUG FOUND AND FIXED (found via code review, same command deauth.sh
# wraps): a typo'd --channel/--time was passed straight through to
# PINEAPPLE_EXAMINE_CHANNEL with no numeric check. deauth.sh's own
# extensive live-diagnosed history of this exact command establishes it's
# fire-and-forget and does NOT reliably signal failure back (so checking
# its exit code here would be pointless - not applied, on purpose), which
# makes catching a bad value BEFORE the call the only real defense against
# it silently doing nothing.
[ -n "$CHANNEL" ] && case "$CHANNEL" in *[!0-9]*) die "'$CHANNEL' doesn't look like a channel number (expected a whole number like 6 or 36)." ;; esac
[ -n "$TIME" ] && case "$TIME" in *[!0-9]*) die "'$TIME' doesn't look like a whole number of seconds." ;; esac

if [ -n "$BSSID" ]; then
    # BUG FOUND AND FIXED (found via code review): a typo'd BSSID was
    # passed straight to PINEAPPLE_EXAMINE_BSSID with no format check -
    # unlike clientip.sh, which validates the same shape of input with
    # is_valid_mac (lib/common.sh) for exactly this reason.
    is_valid_mac "$BSSID" || die "'$BSSID' doesn't look like a valid BSSID (expected AA:BB:CC:DD:EE:FF)."
    if [ -n "$TIME" ]; then PINEAPPLE_EXAMINE_BSSID "$BSSID" "$TIME"; else PINEAPPLE_EXAMINE_BSSID "$BSSID"; fi
    say "Locked to the channel used by $BSSID."
    exit 0
fi

if [ -n "$CHANNEL" ]; then
    if [ -n "$TIME" ]; then PINEAPPLE_EXAMINE_CHANNEL "$CHANNEL" "$TIME"; else PINEAPPLE_EXAMINE_CHANNEL "$CHANNEL"; fi
    say "Locked to channel $CHANNEL."
    exit 0
fi

echo "== examine.sh =="
echo "1) Lock to a known AP's channel (by BSSID)"
echo "2) Lock to a specific channel number"
echo "3) Resume normal hopping"
c=$(ask "Choose" "3")
case "$c" in
    1) b=$(ask "AP BSSID" ""); is_valid_mac "$b" || die "'$b' doesn't look like a valid BSSID (expected AA:BB:CC:DD:EE:FF)."; t=$(ask "Lock time in seconds (blank = until reset)" ""); [ -n "$t" ] && case "$t" in *[!0-9]*) die "'$t' doesn't look like a whole number of seconds." ;; esac; if [ -n "$t" ]; then PINEAPPLE_EXAMINE_BSSID "$b" "$t"; else PINEAPPLE_EXAMINE_BSSID "$b"; fi ;;
    2) ch=$(ask "Channel number" ""); case "$ch" in ''|*[!0-9]*) die "'$ch' doesn't look like a channel number (expected a whole number like 6 or 36)." ;; esac; t=$(ask "Lock time in seconds (blank = until reset)" ""); [ -n "$t" ] && case "$t" in *[!0-9]*) die "'$t' doesn't look like a whole number of seconds." ;; esac; if [ -n "$t" ]; then PINEAPPLE_EXAMINE_CHANNEL "$ch" "$t"; else PINEAPPLE_EXAMINE_CHANNEL "$ch"; fi ;;
    *) PINEAPPLE_EXAMINE_RESET ;;
esac

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

# BIG CHANGE: the interactive menu below used to re-implement the exact
# same BSSID/channel/time validation as the CLI path above, by hand, in
# dense one-liners - the same checks, written twice in two different
# styles, which is exactly how the two paths quietly drift (one gets a
# fix, the other doesn't notice). Shared here so both paths call the same
# validation instead of maintaining two copies of it.
validate_channel() { case "$1" in ''|*[!0-9]*) die "'$1' doesn't look like a channel number (expected a whole number like 6 or 36)." ;; esac; }
validate_time() { [ -n "$1" ] && case "$1" in *[!0-9]*) die "'$1' doesn't look like a whole number of seconds." ;; esac; }
validate_bssid() { is_valid_mac "$1" || die "'$1' doesn't look like a valid BSSID (expected AA:BB:CC:DD:EE:FF)."; }

# BUG FOUND AND FIXED (found via code review): this is examine.sh's own
# direct wrapper around PINEAPPLE_EXAMINE_RESET - the exact command this
# codebase has ALREADY documented, elsewhere, as able to transiently stall
# for several seconds under real device load (reset.sh's reset_wifi(),
# confirmed live: a genuine `reset.sh --all` run hit a real timeout here
# even with network contention ruled out, re-diagnosed via /proc/loadavg
# showing a real decaying load spike - see reset.sh's own header for the
# full incident). reset.sh's fix was `timeout 15` plus one retry after a
# short pause before reporting real failure, specifically because a single
# try with no margin proved too brittle on this modest embedded hardware.
# This file - the one that actually OWNS this command, being what deauth.sh
# and reset.sh both call out BY NAME as examine.sh's own wrapper - had NONE
# of that: no timeout (a stall here would hang the whole script, and since
# this is explicitly SSH-driven, the whole session), no retry, and no
# success/failure check at all (printed "Resumed normal channel hopping."
# unconditionally). Mirrored reset.sh's own established fix exactly instead
# of inventing a new margin.
if [ "$DO_RESET" = "1" ]; then
    if timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; then
        say "Resumed normal channel hopping."
    elif { sleep 1; timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; }; then
        say "Resumed normal channel hopping (needed a retry - the first attempt hit transient contention)."
    else
        die "PINEAPPLE_EXAMINE_RESET failed or timed out twice - channel hopping may still be locked."
    fi
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
[ -n "$CHANNEL" ] && validate_channel "$CHANNEL"
validate_time "$TIME"

if [ -n "$BSSID" ]; then
    # BUG FOUND AND FIXED (found via code review): a typo'd BSSID was
    # passed straight to PINEAPPLE_EXAMINE_BSSID with no format check -
    # unlike clientip.sh, which validates the same shape of input with
    # is_valid_mac (lib/common.sh) for exactly this reason.
    validate_bssid "$BSSID"
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
    1) b=$(ask "AP BSSID" ""); validate_bssid "$b"; t=$(ask "Lock time in seconds (blank = until reset)" ""); validate_time "$t"; if [ -n "$t" ]; then PINEAPPLE_EXAMINE_BSSID "$b" "$t"; else PINEAPPLE_EXAMINE_BSSID "$b"; fi ;;
    2) ch=$(ask "Channel number" ""); validate_channel "$ch"; t=$(ask "Lock time in seconds (blank = until reset)" ""); validate_time "$t"; if [ -n "$t" ]; then PINEAPPLE_EXAMINE_CHANNEL "$ch" "$t"; else PINEAPPLE_EXAMINE_CHANNEL "$ch"; fi ;;
    # CONSISTENCY FIX (found via code review - same timeout+retry gap just
    # fixed for --reset above, missed here in the interactive menu's
    # equivalent "3) Resume normal hopping" choice).
    *)
        if timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; then
            say "Resumed normal channel hopping."
        elif { sleep 1; timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; }; then
            say "Resumed normal channel hopping (needed a retry - the first attempt hit transient contention)."
        else
            err "PINEAPPLE_EXAMINE_RESET failed or timed out twice - channel hopping may still be locked."
        fi
        ;;
esac

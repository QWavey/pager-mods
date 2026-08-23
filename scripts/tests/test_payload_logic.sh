#!/bin/bash
# test_payload_logic.sh - standalone, offline regression checks for the
# pure text/logic pieces of ../../payloads/general/lan_sniffer/payload.sh.
#
# payload.sh can't be sourced directly to get at its functions: its very
# first executable lines are `if [ ! -x /root/scripts/sniff.sh ]; then
# ERROR_DIALOG ...; exit 1; fi`, which only makes sense on the actual
# device (ERROR_DIALOG/LOG/LIST_PICKER/NUMBER_PICKER/CONFIRMATION_DIALOG
# are Hak5 platform builtins that don't exist anywhere else) and would
# abort before any function got defined. Instead, this pulls specific
# function bodies (and one regex) out of the real, current payload.sh
# source text and exercises them directly with hand-built sample input -
# same technique test_sniff_logic.sh uses for sniff.sh, for the same
# reason: ties the checks to the actual shipped code instead of a
# hand-copied re-implementation that could quietly drift out of sync.
#
# WHAT THIS COVERS:
#   - bridge_progress_bar(): the [#####-----] NN% bar renderer, including
#     the "cap at 100% even if cur > total" behavior.
#   - pick_duration()'s whitespace-trim + "Infinite*" prefix-match logic
#     (LIST_PICKER/NUMBER_PICKER are stubbed to return canned values) -
#     this is the exact "a prompt that says 'pick a time' shows up even
#     after Infinite was picked" regression sniff.sh's own history and
#     this payload's header both describe as found-and-fixed here.
#   - the CAPTURE_FILE=$(... | grep -oE '...') regex in run_live_capture
#     that decides whether a background sniff.sh launch is considered to
#     have produced a real capture file - tested against synthetic
#     sniff.sh launch-output text, both a real-looking hit and misses.
#
# WHAT THIS DOES NOT COVER: usb_a_iface()/iface_up() (both read hardcoded
# /sys/class/net/* paths with no injection point, so faithfully testing
# them would mean either touching real sysfs or changing production code
# just to make it testable - left uncovered rather than doing either);
# maybe_save_log()'s actual file writes; start_scroll/stop_scroll and the
# LOG-batching behavior; the Bridge/tap flow's progress-polling loop,
# trap/cleanup behavior, and anything that calls sniff.sh or the Hak5
# platform builtins for real. Those all need the real device.
#
# Usage: bash scripts/tests/test_payload_logic.sh
# Exit code: 0 if every check passed, 1 if any failed.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SELF_DIR/.." && pwd)"
PAYLOAD_SH="$(cd "$SCRIPTS_DIR/../payloads/general/lan_sniffer" && pwd)/payload.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

# extract_func FUNCNAME FILE - see test_sniff_logic.sh's own copy of this
# for the full reasoning; pulls one top-level "name() { ... }" function
# (closing brace alone at column 0) out of FILE without executing anything
# else in that file.
extract_func() {
    local fname="$1" file="$2"
    awk -v fn="$fname" '
        $0 == fn "() {" { found = 1 }
        found { print }
        found && /^}/ { exit }
    ' "$file"
}

[ -f "$PAYLOAD_SH" ] || { echo "Cannot find payload.sh at $PAYLOAD_SH"; exit 1; }

echo "== Extracting pure-logic functions from lan_sniffer/payload.sh =="
for fn in bridge_progress_bar pick_duration; do
    src="$(extract_func "$fn" "$PAYLOAD_SH")"
    if [ -z "$src" ]; then
        echo "Could not extract function '$fn' from payload.sh - has it been renamed/removed? Aborting."
        exit 1
    fi
    eval "$src"
done
echo

echo "== bridge_progress_bar (progress bar render + 100% cap) =="
assert_eq "0/8 renders empty bar at 0%" "[--------------------] 0%" "$(bridge_progress_bar 0 8)"
assert_eq "4/8 renders half-filled bar at 50%" "[##########----------] 50%" "$(bridge_progress_bar 4 8)"
assert_eq "8/8 renders full bar at 100%" "[####################] 100%" "$(bridge_progress_bar 8 8)"
# cur can exceed total (more steps landed than the nominal count, per the
# function's own comment) - must cap at 100%, never show e.g. 140%.
assert_eq "cur > total is capped at 100%, not shown as e.g. 140%" "[####################] 100%" "$(bridge_progress_bar 14 10)"

echo
echo "== pick_duration (whitespace-trim + Infinite-prefix match) =="

# "Timer" path: LIST_PICKER returns "Timer", NUMBER_PICKER's return value
# should be echoed straight through.
LIST_PICKER() { echo "Timer"; }
NUMBER_PICKER() { echo "45"; }
out=$(pick_duration)
assert_eq "Timer selection calls NUMBER_PICKER and returns its value" "45" "$out"

# Exact "Infinite (until B)" match -> empty string, NUMBER_PICKER never
# reached (if it were called here it would still return 45, so this also
# implicitly proves the case branch short-circuits correctly).
LIST_PICKER() { echo "Infinite (until B)"; }
NUMBER_PICKER() { echo "SHOULD-NOT-BE-CALLED"; }
out=$(pick_duration)
assert_eq "exact 'Infinite (until B)' returns empty (infinite)" "" "$out"

# The actual regression this fix addresses: a mangled/padded variant of
# the Infinite option (trailing whitespace, or the platform truncating a
# long label) must still match via the trim + prefix-match, not silently
# fall through to NUMBER_PICKER.
LIST_PICKER() { printf '  Infinite (until B)  \n'; }
out=$(pick_duration)
assert_eq "whitespace-padded 'Infinite...' still matches (the actual regression)" "" "$out"

LIST_PICKER() { echo "Infinite"; }
out=$(pick_duration)
assert_eq "truncated 'Infinite' (no suffix) still matches via prefix" "" "$out"

# "Timer" itself must never be mistaken for Infinite.
LIST_PICKER() { echo "Timer"; }
NUMBER_PICKER() { echo "30"; }
out=$(pick_duration)
assert_eq "'Timer' is never matched as Infinite" "30" "$out"
unset -f LIST_PICKER NUMBER_PICKER

echo
echo "== CAPTURE_FILE extraction regex (run_live_capture's launch-output parsing) =="
# Pull the exact regex out of the real source line rather than
# hand-copying it, so this check is tied to the current code, not a
# separately-maintained duplicate that could drift.
capture_regex_line=$(grep -n "CAPTURE_FILE=\$(echo" "$PAYLOAD_SH")
capture_regex=$(printf '%s' "$capture_regex_line" | sed -n "s/.*grep -oE '\\([^']*\\)'.*/\\1/p")
if [ -z "$capture_regex" ]; then
    fail "could extract the CAPTURE_FILE regex from payload.sh's source" "line was: $capture_regex_line"
else
    pass "extracted CAPTURE_FILE regex from payload.sh: $capture_regex"

    launch_out='[sniff.sh] Capturing on eth1 -> /root/loot/sniff/sniff-20260823-101500.pcap
[sniff.sh] Live output ON - press Ctrl+C or --stop to end.'
    out=$(printf '%s\n' "$launch_out" | grep -oE "$capture_regex" | head -1)
    assert_eq "extracts the real .pcap path from realistic launch output" "/root/loot/sniff/sniff-20260823-101500.pcap" "$out"

    launch_out_fail='[sniff.sh] ERROR: Interface eth9 does not exist'
    out=$(printf '%s\n' "$launch_out_fail" | grep -oE "$capture_regex" | head -1)
    assert_eq "no match on a failed-launch message (no path to extract)" "" "$out"
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

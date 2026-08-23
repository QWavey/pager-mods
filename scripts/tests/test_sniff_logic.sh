#!/bin/bash
# test_sniff_logic.sh - standalone, offline regression checks for the pure
# text/logic pieces of ../sniff.sh (argument validation, the awk-based
# block-boundary helper, the protocol/source-IP classification logic used
# by the capture summary, and the shared PID-reuse guard).
#
# WHAT THIS COVERS: everything below is exercised with hand-built sample
# input/args - no tcpdump invocation, no real network interface, no root/
# device access. It locks in behavior for exactly the things this session's
# "BUG FOUND AND FIXED" comments in sniff.sh describe as verified once by
# hand and then not checked again: the mode-conflict rejection, the
# --duration/--count validation (0, non-numeric, too many digits, over the
# 30-day/100M ceilings), --bridge's same-interface and --dhcp-without-
# --bridge rejections, the ICMP/IPv6 source-IP port-stripping fix, the STP-
# vs-TCP protocol misclassification fix, watcher_block_bounds' empty/
# out-of-range fallback fix, and pid_running's PID-reuse guard.
#
# WHAT THIS DOES NOT COVER: anything requiring a real tcpdump capture or a
# real wired interface - the --bridge/--unbridge kernel-facing steps
# (ip_link calls, actual bridge creation), the watchdog subshells, the
# live run_creds_watcher/run_packet_feed re-scan loops, --background launch
# and PID tracking end-to-end, summarize_pcap's actual tcpdump -A/-nn
# invocations (only the pure classification/extraction functions it calls
# are covered), and the "cleartext credential" CREDS_PATTERN/HTTP_PATTERN
# regexes themselves (not exercised here). Those all need the real device
# or at least a real tcpdump binary and are out of scope for this pass.
#
# Usage: bash scripts/tests/test_sniff_logic.sh
# Exit code: 0 if every check passed, 1 if any failed (prints a summary
# either way).

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SELF_DIR/.." && pwd)"
SNIFF_SH="$SCRIPTS_DIR/sniff.sh"
COMMON_SH="$SCRIPTS_DIR/lib/common.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

assert_eq() {
    # assert_eq LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

assert_contains() {
    # assert_contains LABEL HAYSTACK NEEDLE
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected output to contain [$3], got: $2" ;;
    esac
}

# extract_func FUNCNAME FILE - pulls a single top-level "name() { ... }"
# function definition (closing brace alone at column 0) out of FILE without
# executing anything else in it, and prints its source. Lets this test
# script exercise sniff.sh's actual current pure-logic functions directly,
# without sourcing (and thereby running) the whole top-level script.
extract_func() {
    local fname="$1" file="$2"
    awk -v fn="$fname" '
        $0 == fn "() {" { found = 1 }
        found { print }
        found && /^}/ { exit }
    ' "$file"
}

[ -f "$SNIFF_SH" ] || { echo "Cannot find sniff.sh at $SNIFF_SH"; exit 1; }
[ -f "$COMMON_SH" ] || { echo "Cannot find lib/common.sh at $COMMON_SH"; exit 1; }

echo "== Extracting pure-logic functions from $(basename "$SNIFF_SH") =="
for fn in extract_src_ips classify_protocols watcher_block_bounds; do
    src="$(extract_func "$fn" "$SNIFF_SH")"
    if [ -z "$src" ]; then
        echo "Could not extract function '$fn' from sniff.sh - has it been renamed/removed? Aborting."
        exit 1
    fi
    eval "$src"
done
# common.sh is safe to source wholesale (no top-level dispatch, just
# function/var definitions) - gives us pid_running() etc. directly.
TOOL_NAME="test_sniff_logic"
# shellcheck disable=SC1090
. "$COMMON_SH"
echo

echo "== extract_src_ips (Top source IPs address/port stripping) =="
# ICMP line: exactly 4 dot-separated octets, no port at all - must be left
# untouched (this is the "172.16.52" 3-octet truncation bug).
out=$(printf '12:00:00.1 IP 172.16.52.1 > 172.16.52.254: ICMP echo request\n' | extract_src_ips)
assert_eq "ICMP source (4 octets, no port) kept whole" "172.16.52.1" "$out"

# TCP line: IPv4 with an appended port - the port must be stripped.
out=$(printf '12:00:00.1 IP 10.0.0.5.443 > 10.0.0.9.51000: Flags [S]\n' | extract_src_ips)
assert_eq "IPv4 source with port has port stripped" "10.0.0.5" "$out"

# IPv6 with an appended port - must also be stripped (this was the second,
# separately-found bug: the IPv4-only regex never matched IPv6 forms).
out=$(printf '12:00:00.1 IP6 fe80::1.12345 > fe80::2.443: Flags [S]\n' | extract_src_ips)
assert_eq "IPv6 source with port has port stripped" "fe80::1" "$out"

# Bare IPv6 with no port at all - must be left untouched.
out=$(printf '12:00:00.1 IP6 fe80::1 > fe80::2: ICMP6, echo request\n' | extract_src_ips)
assert_eq "IPv6 source with no port kept whole" "fe80::1" "$out"

echo
echo "== classify_protocols (STP vs TCP vs other markers) =="
# The exact regression this session found: an STP BPDU's own "Flags [none]"
# field used to be caught by the TCP rule before an STP-specific rule ran.
stp_line='12:00:00.1 STP 802.1d, Config, Flags [none], bridge-id 8000.aa:bb:cc:dd:ee:ff.8003, length 43'
tcp_line='12:00:00.1 IP 10.0.0.5.443 > 10.0.0.9.51000: Flags [S], seq 1, length 0'
out=$(printf '%s\n%s\n' "$stp_line" "$tcp_line" | classify_protocols)
assert_eq "STP and TCP classified distinctly (not both TCP)" "$(printf 'STP\nTCP')" "$out"

out=$(printf '12:00:00.1 ARP, Request who-has 10.0.0.1 tell 10.0.0.5, length 28\n' | classify_protocols)
assert_eq "ARP classified" "ARP" "$out"

out=$(printf '12:00:00.1 IP 10.0.0.5 > 10.0.0.9: ICMP echo request, id 1, seq 1, length 64\n' | classify_protocols)
assert_eq "ICMP classified" "ICMP" "$out"

out=$(printf '12:00:00.1 IP 10.0.0.5.51000 > 10.0.0.9.53: 12345+ A? example.com. (28)\n' | classify_protocols)
assert_eq "DNS query classified" "DNS" "$out"

out=$(printf '12:00:00.1 IP 10.0.0.5.51000 > 10.0.0.9.123: UDP, length 48\n' | classify_protocols)
assert_eq "Plain UDP classified" "UDP" "$out"

echo
echo "== watcher_block_bounds (empty/out-of-range fallback fix) =="
# This is the exact fix described in sniff.sh's own comment: bs used to
# have no BEGIN default, so an empty/malformed blocks_lines list (or a
# lineno before the first entry) left bs="" and corrupted the caller's
# sed range. Verify all the documented edge cases.
blocks_lines="1
10
25"

out=$(watcher_block_bounds 15)
assert_eq "mid-range lineno resolves to its enclosing block" "$(printf '10\t25')" "$out"

out=$(watcher_block_bounds 999)
assert_eq "past-the-end lineno resolves to last block, open-ended end" "$(printf '25\t2000000000')" "$out"

blocks_lines=""
out=$(watcher_block_bounds 5)
assert_eq "empty blocks_lines still yields a safe start (bs=1, not empty)" "$(printf '1\t2000000000')" "$out"

blocks_lines="50
80"
out=$(watcher_block_bounds 10)
assert_eq "lineno before first entry falls back to bs=1, not empty string" "$(printf '1\t50')" "$out"

echo
echo "== pid_running (PID-reuse guard, from lib/common.sh) =="
tmp_pidfile="$(mktemp)"
# A currently-running process (this test script's own shell, $$) whose
# /proc cmdline does NOT contain an unrelated pattern must be reported as
# NOT running for that pattern - proves the NAME_PATTERN check actually
# discriminates real matches from "some other live process happens to have
# this PID right now" instead of just doing a bare kill -0.
echo "$$" > "$tmp_pidfile"
if pid_running "$tmp_pidfile" "definitely-not-a-real-cmdline-substring-xyz"; then
    fail "pid_running rejects a live PID whose cmdline doesn't match NAME_PATTERN" "returned true, expected false"
else
    pass "pid_running rejects a live PID whose cmdline doesn't match NAME_PATTERN"
fi

# A PID that (almost certainly) isn't running at all must be reported as
# not running, pattern or not.
echo "999999" > "$tmp_pidfile"
if pid_running "$tmp_pidfile"; then
    fail "pid_running reports a nonexistent PID as not running" "returned true"
else
    pass "pid_running reports a nonexistent PID as not running"
fi

# Missing pidfile entirely -> not running, no error.
rm -f "$tmp_pidfile"
if pid_running "$tmp_pidfile"; then
    fail "pid_running reports 'not running' for a missing pidfile" "returned true"
else
    pass "pid_running reports 'not running' for a missing pidfile"
fi

echo
echo "== sniff.sh argument validation (real CLI invocations, no tcpdump reached) =="
# Every case below dies during argument parsing/validation, before sniff.sh
# ever touches an interface or spawns tcpdump - safe to run as real
# subprocess invocations of the actual script.
run_sniff() { bash "$SNIFF_SH" "$@" </dev/null 2>&1; }

out=$(run_sniff --bridge eth0 eth1 --summary somefile.pcap); rc=$?
assert_contains "mode conflict (--bridge + --summary) is rejected" "$out" "conflicting actions"
[ "$rc" -ne 0 ] && pass "mode conflict exits non-zero" || fail "mode conflict exits non-zero" "rc=$rc"

out=$(run_sniff --duration 0); rc=$?
assert_contains "--duration 0 is rejected (not 'no limit')" "$out" "can't be 0"
[ "$rc" -ne 0 ] && pass "--duration 0 exits non-zero" || fail "--duration 0 exits non-zero" "rc=$rc"

out=$(run_sniff --count 0); rc=$?
assert_contains "--count 0 is rejected (not 'unlimited')" "$out" "can't be 0"
[ "$rc" -ne 0 ] && pass "--count 0 exits non-zero" || fail "--count 0 exits non-zero" "rc=$rc"

out=$(run_sniff --duration abc)
assert_contains "non-numeric --duration is rejected" "$out" "whole number"

out=$(run_sniff --duration 1234567890123456)
assert_contains "absurdly long --duration digit-string is rejected" "$out" "not a realistic number"

out=$(run_sniff --duration 2592001)
assert_contains "--duration over 30 days is rejected" "$out" "over 30 days"

out=$(run_sniff --count 100000001)
assert_contains "--count over 100 million is rejected" "$out" "over 100 million"

out=$(run_sniff --dhcp)
assert_contains "--dhcp without --bridge is rejected" "$out" "only makes sense together with --bridge"

out=$(run_sniff --bridge eth1 eth1 -y)
assert_contains "--bridge with two identical interfaces is rejected" "$out" "two DIFFERENT interface names"

# Sanity check the false-positive side too: a single mode flag with no
# conflict must NOT be rejected by the mode-conflict check, and must reach
# a fast, no-hardware-needed exit path (--list only reads /sys/class/net).
out=$(run_sniff --list); rc=$?
[ "$rc" -eq 0 ] && pass "--list alone is accepted (no false-positive mode conflict)" || fail "--list alone is accepted (no false-positive mode conflict)" "rc=$rc, out=$out"

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

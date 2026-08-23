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
# out-of-range fallback fix, pid_running's PID-reuse guard, kill_tracked_
# pid's own PID-reuse-guarded kill-and-forget behavior (missing/stale
# pidfile, live-and-matching, live-but-non-matching), reap_orphaned_
# tcpdump_rescans' ps-output filtering (kills only "tcpdump ... -r ..."
# rescans, leaves a live "-i/-w" capture alone, and - the actual reason
# that function greps with `grep -v grep` - never kills its own grep
# process even though that process's own argv literally contains the
# search pattern text), and the CREDS_PATTERN/HTTP_PATTERN regexes
# themselves, exercised directly against sample text.
#
# WHAT THIS DOES NOT COVER: anything requiring a real tcpdump capture or a
# real wired interface - the --bridge/--unbridge kernel-facing steps
# (ip_link calls, actual bridge creation), the watchdog subshells (including
# the USB_A_STATEFILE freshness hint inside start_lan_watchdog, which is
# inline loop code rather than a standalone function), the live run_creds_
# watcher/run_packet_feed re-scan loops, --background launch and PID
# tracking end-to-end, and summarize_pcap's actual tcpdump -A/-nn
# invocations (only the pure classification/extraction functions it calls
# are covered - though the CREDS_PATTERN/HTTP_PATTERN regexes those calls
# feed through, shared with run_creds_watcher, ARE now exercised directly
# against sample text, extracted straight from the source). Those all need
# the real device or at least a real tcpdump binary and are out of scope
# for this pass.
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
for fn in extract_src_ips classify_protocols watcher_block_bounds kill_tracked_pid reap_orphaned_tcpdump_rescans; do
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
echo "== kill_tracked_pid (shared PID-reuse-guarded kill-and-forget) =="
# Uses REAL background processes and REAL signals (same convention as the
# pid_running block above, which already uses real PIDs $$ and 999999) -
# no stubbing needed since kill_tracked_pid only needs pid_running() (real,
# sourced from common.sh above) and the real `kill` builtin, both of which
# behave identically here and on-device.

# Case 1: missing pidfile entirely must be a safe no-op (matches every
# original call site's own `[ -f "$pidfile" ]` guard, per this function's
# own header comment - "same 'stale/missing pidfile is a harmless no-op'
# behavior every original call site already had").
tmp_pidfile="$(mktemp -u)"
rm -f "$tmp_pidfile"
kill_tracked_pid "$tmp_pidfile" "anything"
if [ -f "$tmp_pidfile" ]; then
    fail "kill_tracked_pid on a missing pidfile is a safe no-op" "pidfile now exists"
else
    pass "kill_tracked_pid on a missing pidfile is a safe no-op"
fi

# Case 2: a live process whose /proc cmdline DOES contain PATTERN must
# actually be killed, and the pidfile removed either way.
probe_script="$(mktemp)"
printf '#!/bin/bash\nsleep 20\n' > "$probe_script"
bash "$probe_script" &
bg_pid=$!
sleep 0.3
tmp_pidfile="$(mktemp)"
echo "$bg_pid" > "$tmp_pidfile"
# The probe script's own randomly-generated mktemp basename is a pattern
# guaranteed to appear nowhere else on the system, so matching on it (via
# pid_running's /proc/$pid/cmdline substring check) can't accidentally
# match some unrelated live process.
kill_tracked_pid "$tmp_pidfile" "$(basename "$probe_script")"
sleep 0.3
if kill -0 "$bg_pid" 2>/dev/null; then
    fail "kill_tracked_pid kills a live PID whose cmdline matches PATTERN" "process $bg_pid still alive"
    kill "$bg_pid" 2>/dev/null
else
    pass "kill_tracked_pid kills a live PID whose cmdline matches PATTERN"
fi
[ -f "$tmp_pidfile" ] && fail "kill_tracked_pid removes the pidfile after a matching kill" "pidfile still present" \
    || pass "kill_tracked_pid removes the pidfile after a matching kill"
rm -f "$probe_script"

# Case 3: the actual PID-reuse guard this function exists for - a live
# process whose cmdline does NOT contain PATTERN must be LEFT RUNNING (not
# blind-killed just because its number is sitting in the pidfile), even
# though the pidfile itself is still cleaned up.
probe_script="$(mktemp)"
printf '#!/bin/bash\nsleep 20\n' > "$probe_script"
bash "$probe_script" &
bg_pid=$!
sleep 0.3
tmp_pidfile="$(mktemp)"
echo "$bg_pid" > "$tmp_pidfile"
kill_tracked_pid "$tmp_pidfile" "definitely-not-a-real-cmdline-substring-xyz"
if kill -0 "$bg_pid" 2>/dev/null; then
    pass "kill_tracked_pid does NOT kill a live PID whose cmdline doesn't match PATTERN (reuse guard)"
else
    fail "kill_tracked_pid does NOT kill a live PID whose cmdline doesn't match PATTERN (reuse guard)" "process $bg_pid was killed anyway"
fi
[ -f "$tmp_pidfile" ] && fail "kill_tracked_pid still removes the pidfile even on a non-matching PID" "pidfile still present" \
    || pass "kill_tracked_pid still removes the pidfile even on a non-matching PID"
# Cleanup: this probe process was deliberately left running by the guard
# just proven above - stop it for real now, not part of the check itself.
kill "$bg_pid" 2>/dev/null
rm -f "$probe_script"

# Case 4: a stale pidfile (PID not running at all) must not error, and
# must still be removed.
tmp_pidfile="$(mktemp)"
echo "999999" > "$tmp_pidfile"
kill_tracked_pid "$tmp_pidfile" "anything"
[ -f "$tmp_pidfile" ] && fail "kill_tracked_pid removes a stale (not-running) pidfile" "pidfile still present" \
    || pass "kill_tracked_pid removes a stale (not-running) pidfile"

echo
echo "== reap_orphaned_tcpdump_rescans (ps-output filtering, incl. self-exclusion) =="
# Stubs `ps` and `kill` as plain shell functions for the duration of this
# block only (same technique test_payload_logic.sh uses to stub LIST_
# PICKER/NUMBER_PICKER) - a defined function takes priority over both an
# external command (ps) and a shell builtin (kill) for a bare, unqualified
# call, so the real extracted reap_orphaned_tcpdump_rescans() body drives
# these fakes exactly as it would drive the real commands on-device,
# without this test needing to spawn/rename real processes (this device's
# own `ps` output format - COMMAND is the process's own argv, unlike some
# other platforms - can't be reproduced by renaming a local test process).
_reap_killed=""
kill() { _reap_killed="$_reap_killed $1"; }
ps() {
    printf '1001 x x x ? 0 12:00 tcpdump -A -r /root/loot/sniff/cap.pcap\n'
    printf '1002 x x x ? 0 12:00 tcpdump -i eth1 -w /root/loot/sniff/live.pcap\n'
    printf '1003 x x x ? 0 12:00 grep -E tcpdump .* -r \n'
    printf '1004 x x x ? 0 12:00 tcpdump -nn -r /root/loot/sniff/z.pcap\n'
    printf '1005 x x x ? 0 12:00 sshd: root@pts/0\n'
}
reap_orphaned_tcpdump_rescans
assert_eq "reap_orphaned_tcpdump_rescans kills exactly the two '-r' rescans (1001, 1004)" " 1001 1004" "$_reap_killed"
unset -f ps kill

_reap_killed=""
kill() { _reap_killed="$_reap_killed $1"; }
ps() { printf '2001 x x x ? 0 12:00 tcpdump -i eth1 -w /root/loot/sniff/live.pcap\n'; }
reap_orphaned_tcpdump_rescans
assert_eq "reap_orphaned_tcpdump_rescans leaves a live '-i/-w' capture alone (no '-r')" "" "$_reap_killed"
unset -f ps kill

echo
echo "== CREDS_PATTERN / HTTP_PATTERN (cleartext-credential/HTTP regexes, exercised directly) =="
# Pulled straight out of the real source lines (same "tied to current code,
# not a hand-copied duplicate that could drift" reasoning test_payload_
# logic.sh already uses for its own CAPTURE_FILE regex extraction) rather
# than restating the pattern text here - a change to either regex in
# sniff.sh is automatically exercised by whatever's below, no separate
# edit needed in this test file. Both summarize_pcap and run_creds_watcher
# grep these with `-iE` (case-insensitive), so every check below matches
# that real usage.
creds_pattern_line=$(grep -n "^CREDS_PATTERN=" "$SNIFF_SH")
creds_pattern=$(printf '%s' "$creds_pattern_line" | sed -n "s/^[0-9]*:CREDS_PATTERN='\\(.*\\)'\$/\\1/p")
http_pattern_line=$(grep -n "^HTTP_PATTERN=" "$SNIFF_SH")
http_pattern=$(printf '%s' "$http_pattern_line" | sed -n "s/^[0-9]*:HTTP_PATTERN='\\(.*\\)'\$/\\1/p")

if [ -z "$creds_pattern" ]; then
    fail "could extract CREDS_PATTERN from sniff.sh's source" "line was: $creds_pattern_line"
else
    pass "extracted CREDS_PATTERN from sniff.sh"

    creds_hit() {
        # LABEL INPUT - asserts INPUT matches CREDS_PATTERN (case-insensitive,
        # matching summarize_pcap/run_creds_watcher's own `grep -iE`).
        if printf '%s\n' "$2" | grep -qiE "$creds_pattern"; then
            pass "$1"
        else
            fail "$1" "expected a CREDS_PATTERN match on: $2"
        fi
    }
    creds_miss() {
        # LABEL INPUT - asserts INPUT does NOT match CREDS_PATTERN.
        if printf '%s\n' "$2" | grep -qiE "$creds_pattern"; then
            fail "$1" "expected NO CREDS_PATTERN match on: $2"
        else
            pass "$1"
        fi
    }

    creds_hit  "matches an HTTP Basic Auth header (case-insensitive)" "Authorization: Basic QWxhZGRpbjpvcGVuc2VzYW1l"
    creds_hit  "matches an Authorization: Bearer token" "authorization: bearer abc123.def456"
    creds_hit  "matches a query-string login (user=...&pass=...)" "GET /login?user=admin&pass=hunter2 HTTP/1.1"
    creds_hit  "matches a form-body login at the start of a line (passwd=)" "user=alice&passwd=letmein"
    creds_hit  "matches raw FTP/Telnet USER" "USER anonymous"
    creds_hit  "matches raw FTP/Telnet PASS" "PASS s3cr3t"
    creds_hit  "matches a JSON login body's \"password\": field" '  "password": "hunter2"'
    creds_miss "does not match a plain GET with no credential markers" "GET /index.html HTTP/1.1"
    # The exact false-positive this pattern's (^|[?&]) prefix requirement
    # guards against: a query param whose name merely CONTAINS "pass" as a
    # substring (e.g. "compass") must not be mistaken for a real pass=
    # credential field just because "pass=" appears mid-word.
    creds_miss "does not false-positive on 'compass=' (pass= is not at a field boundary)" "compass=32"
    creds_miss "does not false-positive on 'username=' (user= is not a full field match)" "username=bob"
fi

if [ -z "$http_pattern" ]; then
    fail "could extract HTTP_PATTERN from sniff.sh's source" "line was: $http_pattern_line"
else
    pass "extracted HTTP_PATTERN from sniff.sh"

    http_hit() {
        if printf '%s\n' "$2" | grep -qiE "$http_pattern"; then
            pass "$1"
        else
            fail "$1" "expected an HTTP_PATTERN match on: $2"
        fi
    }
    http_miss() {
        if printf '%s\n' "$2" | grep -qiE "$http_pattern"; then
            fail "$1" "expected NO HTTP_PATTERN match on: $2"
        else
            pass "$1"
        fi
    }

    http_hit  "matches a GET request line" "GET /index.html HTTP/1.1"
    http_hit  "matches a POST request line" "POST /api/login HTTP/1.1"
    http_hit  "matches a lowercase Host header" "host: example.com"
    http_hit  "matches a capitalized Host header (case-insensitive)" "Host: example.com"
    http_miss "does not match an unlisted HTTP verb (PATCH)" "PATCH /resource HTTP/1.1"
    http_miss "does not match a verb-prefix lookalike with no space before the path (GETX)" "GETX /path"
    http_miss "does not match a request line with leading whitespace (anchored to line start)" "  GET /path"
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

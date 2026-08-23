#!/bin/bash
# test_common_logic.sh - standalone, offline regression checks for
# ../lib/common.sh's canonicalize_lan_topology() reconciler (and its
# eth0_in_br_lan() helper) - the shared "is eth0 where it belongs right
# now, and if not, repair it" logic that both sniff.sh's own bridge
# watchdog and reset.sh's reset_network() call instead of each keeping an
# independent copy (see that function's own "BIG CHANGE" header in
# common.sh for the full history of why two copies was dangerous).
#
# WHY THIS EXISTS: no test file covered this function before now, despite
# it being exactly the kind of safety-critical, easy-to-silently-regress
# logic this toolkit's test files otherwise care about most (see
# test_sniff_logic.sh's own header). The specific thing this locks in is
# the "bridged" mode fix documented in canonicalize_lan_topology's own
# comment: checking the bridge device's PORT COUNT (via sysfs
# /sys/class/net/<bridge>/brif/), not just whether the bridge device
# itself still exists - a degraded bridge (one member vanished, one still
# attached) must fall through to eth0 repair instead of the old
# always-true "bridge exists -> don't touch anything" fast path.
#
# HOW: canonicalize_lan_topology() and eth0_in_br_lan() both read
# hardcoded absolute /sys/class/net/... paths with no injection point (the
# same reason test_payload_logic.sh's own header gives for leaving
# usb_a_iface()/iface_up() uncovered) - sysfs is kernel-owned, so there is
# no way to create a real fake bridge/port there, on this dev machine OR
# on the real device, without actual root+CAP_NET_ADMIN+a real bridge
# (exactly the live device access this whole test suite is designed to
# avoid needing). Instead of leaving this function completely untested for
# that reason, this pulls the real function source out of common.sh (same
# extract-and-eval technique as test_sniff_logic.sh/test_payload_logic.sh)
# and rewrites its hardcoded "/sys/class/net" prefix to a throwaway
# mktemp -d tree before eval'ing it - the actual current logic/control-flow
# from the real file is what's under test, just pointed at a fake sysfs
# instead of a real one. ip_link() is stubbed (never touch a real
# interface) and made to simulate a successful repair only for the exact
# "set eth0 master br-lan" call, so a test can tell "repair was correctly
# attempted" apart from "repair was correctly skipped."
#
# WHAT THIS DOES NOT COVER: sniff.sh's own separate BR_IFACE1/BR_IFACE2
# sysfs-existence watchdog check (that one is sniff.sh's own inline logic,
# not part of common.sh, and is exercised as real CLI behavior would need
# a real bridge session to reach) - only the shared reconciler function
# itself.
#
# Usage: bash scripts/tests/test_common_logic.sh
# Exit code: 0 if every check passed, 1 if any failed.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SELF_DIR/.." && pwd)"
COMMON_SH="$SCRIPTS_DIR/lib/common.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# extract_func FUNCNAME FILE - same technique as test_sniff_logic.sh/
# test_payload_logic.sh's own copy, but matched on `index(...)==1` instead
# of an exact `$0 == fn "() {"` line-equality test: common.sh has both
# multi-line functions (canonicalize_lan_topology) AND genuine one-liner
# functions (eth0_in_br_lan is "name() { ...; }" entirely on one line) -
# the exact-equality version the other two test files use can only ever
# match a header line with NOTHING else on it, so it silently extracts
# nothing at all for a one-liner (confirmed: returns empty for
# eth0_in_br_lan, which would have been a false "ok, function exists and
# matched" if this used assert-non-empty without ever really calling the
# real code). index($0, fn "() {") == 1 matches the same multi-line case
# just as well (still requires the header to literally start the line)
# while ALSO matching a one-liner whose full body/closing brace are on
# that same first line - the `if ($0 ~ /}[ \t]*$/) { exit }` check right
# after handles that case by stopping immediately instead of waiting for a
# separate closing-brace-only line that a one-liner will never have.
extract_func() {
    local fname="$1" file="$2"
    awk -v fn="$fname" '
        index($0, fn "() {") == 1 {
            found = 1
            print
            if ($0 ~ /}[ \t]*$/) { exit }
            next
        }
        found { print; if ($0 ~ /^}/) exit }
    ' "$file"
}

[ -f "$COMMON_SH" ] || { echo "Cannot find lib/common.sh at $COMMON_SH"; exit 1; }

# FAKE_SYS - throwaway sysfs stand-in for this whole test file (see header
# above for why a real /sys/class/net can't be used). One tree, reused
# across every test case via reset_fixture() below.
FAKE_SYS="$(mktemp -d)"
trap 'rm -rf "$FAKE_SYS"' EXIT
mkdir -p "$FAKE_SYS/class/net/br-lan/brif"
mkdir -p "$FAKE_SYS/class/net/br-sniff/brif"

echo "== Extracting canonicalize_lan_topology()/eth0_in_br_lan() from $(basename "$COMMON_SH") =="
for fn in eth0_in_br_lan canonicalize_lan_topology; do
    src="$(extract_func "$fn" "$COMMON_SH")"
    if [ -z "$src" ]; then
        echo "Could not extract function '$fn' from common.sh - has it been renamed/removed? Aborting."
        exit 1
    fi
    # Redirect the real function's hardcoded /sys/class/net prefix into
    # this test's own throwaway tree - the ONLY change made to the real
    # source text; every other line (the port-count arithmetic, the
    # existence checks, the retry loop, the return-code logic) runs
    # completely unmodified.
    src="$(printf '%s' "$src" | sed "s#/sys/class/net#$FAKE_SYS/class/net#g")"
    eval "$src"
done
echo

# topology_log/ip_link stubs - canonicalize_lan_topology calls both.
# topology_log here is a real no-op (this test cares about return codes
# and which repair calls were made, not the forensic log text) rather than
# the real disk-writing version, so it doesn't need TOPOLOGY_LOG pointed
# anywhere. ip_link is stubbed to (a) record every call it received so a
# test can assert whether a repair was attempted at all, and (b) simulate
# a successful "set eth0 master br-lan" by creating that exact fake sysfs
# entry, so the function's own post-repair eth0_in_br_lan() re-check can
# genuinely observe success without ever touching a real interface.
topology_log() { :; }
IP_LINK_CALLS=""
ip_link() {
    IP_LINK_CALLS="$IP_LINK_CALLS|$*"
    case "$*" in
        "set eth0 master br-lan") : > "$FAKE_SYS/class/net/br-lan/brif/eth0" ;;
    esac
    return 0
}

# reset_fixture - back to a clean slate before every test case: br-lan has
# no ports, br-sniff exists with an empty brif/ (individual tests populate
# what they need), and the ip_link call log is cleared.
reset_fixture() {
    rm -f "$FAKE_SYS/class/net/br-lan/brif/"*
    rm -rf "$FAKE_SYS/class/net/br-sniff"
    mkdir -p "$FAKE_SYS/class/net/br-sniff/brif"
    IP_LINK_CALLS=""
}

echo "== canonicalize_lan_topology - desired-state validation =="
reset_fixture
canonicalize_lan_topology bogus br-sniff
rc=$?
if [ "$rc" -eq 1 ] && [ -z "$IP_LINK_CALLS" ]; then
    pass "unknown desired state is rejected (rc=1), no repair attempted"
else
    fail "unknown desired state is rejected (rc=1), no repair attempted" "rc=$rc calls=$IP_LINK_CALLS"
fi

echo
echo "== canonicalize_lan_topology bridged - the tonight's-fix port-count gate =="
# Healthy: both configured members still attached (brif/ has 2 entries) -
# must take the fast path and NOT touch eth0/call ip_link at all (this is
# the "not this reconciler's job to touch it" contract - see the incident
# in canonicalize_lan_topology's own header about the watchdog fighting a
# legitimately active bridge).
reset_fixture
: > "$FAKE_SYS/class/net/br-sniff/brif/eth0"
: > "$FAKE_SYS/class/net/br-sniff/brif/eth1"
canonicalize_lan_topology bridged br-sniff
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$IP_LINK_CALLS" ]; then
    pass "bridge with 2 members present: fast path, eth0 left untouched"
else
    fail "bridge with 2 members present: fast path, eth0 left untouched" "rc=$rc calls=$IP_LINK_CALLS"
fi

# Degraded: bridge device itself still exists but only 1 of its 2 members
# is still attached (brif/ has 1 entry) - this is exactly the case
# tonight's fix (see common.sh's own comment) added: must NOT trust the
# old "bridge exists" fast path, must fall through to the eth0 repair path
# instead, same as if the bridge had vanished entirely.
reset_fixture
: > "$FAKE_SYS/class/net/br-sniff/brif/eth0"
canonicalize_lan_topology bridged br-sniff
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$IP_LINK_CALLS" ]; then
    pass "bridge with only 1 of 2 members present: falls through to eth0 repair (not the stale fast path)"
else
    fail "bridge with only 1 of 2 members present: falls through to eth0 repair (not the stale fast path)" "rc=$rc calls=$IP_LINK_CALLS"
fi

# Bridge device gone entirely, but eth0 already correctly back in br-lan
# (e.g. a previous cycle already repaired it) - must report healthy
# without attempting a needless repair.
reset_fixture
rm -rf "$FAKE_SYS/class/net/br-sniff"
: > "$FAKE_SYS/class/net/br-lan/brif/eth0"
canonicalize_lan_topology bridged br-sniff
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$IP_LINK_CALLS" ]; then
    pass "bridge device gone, eth0 already in br-lan: healthy, no repair attempted"
else
    fail "bridge device gone, eth0 already in br-lan: healthy, no repair attempted" "rc=$rc calls=$IP_LINK_CALLS"
fi

echo
echo "== canonicalize_lan_topology management - unconditional check/repair =="
reset_fixture
: > "$FAKE_SYS/class/net/br-lan/brif/eth0"
canonicalize_lan_topology management
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$IP_LINK_CALLS" ]; then
    pass "management, eth0 already present: healthy, no repair attempted"
else
    fail "management, eth0 already present: healthy, no repair attempted" "rc=$rc calls=$IP_LINK_CALLS"
fi

reset_fixture
canonicalize_lan_topology management
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$IP_LINK_CALLS" ]; then
    pass "management, eth0 missing: repair attempted and succeeds"
else
    fail "management, eth0 missing: repair attempted and succeeds" "rc=$rc calls=$IP_LINK_CALLS"
fi

# Repair genuinely fails (ip_link never actually re-attaches eth0) - must
# report failure honestly (rc=1), not claim success it didn't achieve.
reset_fixture
ip_link() { IP_LINK_CALLS="$IP_LINK_CALLS|$*"; return 0; }
canonicalize_lan_topology management
rc=$?
if [ "$rc" -eq 1 ] && [ -n "$IP_LINK_CALLS" ]; then
    pass "management, eth0 missing, repair doesn't take: reports failure honestly (rc=1)"
else
    fail "management, eth0 missing, repair doesn't take: reports failure honestly (rc=1)" "rc=$rc calls=$IP_LINK_CALLS"
fi
# Restore the real (successful) ip_link stub in case anything is added below.
ip_link() {
    IP_LINK_CALLS="$IP_LINK_CALLS|$*"
    case "$*" in
        "set eth0 master br-lan") : > "$FAKE_SYS/class/net/br-lan/brif/eth0" ;;
    esac
    return 0
}

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

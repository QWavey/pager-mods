#!/bin/bash
# sniff.sh - LAN packet sniffer. Wraps the standard tcpdump (not Hak5-
# specific, but pre-installed and the normal tool for this). Supports a
# bridge/tap mode for a two-NIC setup: PC -> Pager USB-C LAN -> [Pager
# bridges] -> Pager USB-A (e.g. a UGREEN adapter) -> router/repeater. In
# bridge mode traffic actually flows through the Pager transparently while
# you can sniff it on either side - a real inline tap, not just a capture
# on one interface.
#
# Every capture is automatically summarized when it finishes (top talkers,
# protocol breakdown, and a cleartext-credential scan) - you get an
# immediate, readable report instead of a raw .pcap you have to download
# and open in Wireshark to learn anything from.
#
# Usage:
#   sniff.sh --iface eth1 [--filter "tcpdump expr"] [--duration SECONDS] [--count N]
#   sniff.sh --bridge IFACE1 IFACE2 [--dhcp]  bridge two NICs into a transparent tap (br-sniff)
#   sniff.sh --unbridge                     tear the bridge back down
#   sniff.sh --list                           list candidate wired interfaces
#   sniff.sh --adapters                         check USB-C + USB-A wired adapter status
#   sniff.sh --summary FILE                     re-run the summary/creds scan on a saved capture
#   sniff.sh --status                             is a capture currently running?
#   sniff.sh --stop                                 stop a background capture
#   sniff.sh                                          interactive mode
#
# Options:
#   --iface IFACE       Interface to capture on (default: eth1, or br-sniff if bridged)
#   --filter EXPR         Raw tcpdump filter expression, e.g. "port 80 or port 443"
#   --duration SECONDS       Stop after this many seconds (default: capture until Ctrl+C)
#   --count N                  Stop after N packets
#   --quiet                       Don't print packets live - just save silently (old default
#                                    behavior; live output is now ON by default - see below).
#   --output FILE                  Save to a specific .pcap file (default: timestamped under /root/loot/sniff/)
#   --background                     Launch capture detached (still writes live packet text
#                                        into /tmp/pager-sniff.log - `tail -f` it, or --stop to end it)
#   --no-summary                       Skip the auto-summary/creds scan after capture
#   --dhcp                                With --bridge: also request a real DHCP lease on the
#                                            bridge device from the LAN being tapped, so the
#                                            Pager stays reachable by SSH there too - no reset
#                                            needed after a normal bridge/unbridge cycle.
#   -y, --yes                            Don't prompt for confirmation
#   -h, --help                             This help
#
# BUG FOUND AND FIXED: live packet output used to be OFF by default (needed
# an explicit --live flag) - a plain `sniff.sh --iface eth0 --duration 30`
# ran completely silently for the whole duration, which looked exactly like
# a hang ("it just says it launches with 30 seconds" and nothing else,
# reported live against this exact device). Live output is now ON by
# default in every mode (foreground AND --background, which now also
# writes real packet text into its log instead of nothing) - pass --quiet
# for the old silent behavior. Cleartext-credential hits in the auto-
# summary are now shown in RED (see summarize_pcap) so they're impossible
# to miss in a scroll of otherwise-plain traffic.
#
# Two-adapter tap topology: the Pager has exactly two wired LAN paths - the
# built-in USB-C port (always eth0, a Realtek RTL8153 USB-Ethernet gadget
# per Hak5's own docs - this is also the port used for SSH/management) and
# whatever USB Ethernet adapter (e.g. a UGREEN one) is plugged into the
# USB-A port. Every run of this script checks and prints which of the two
# is physically connected right now (by sysfs device path, not guesswork)
# automatically, before capturing - no separate step to remember. `--adapters`
# still exists as a quick check-only shortcut if you just want the status.

set -u
TOOL_NAME="sniff.sh"
LOOT_DIR="/root/loot/sniff"
BRIDGE_NAME="br-sniff"
PIDFILE="/tmp/pager-sniff.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

IFACE=""; FILTER=""; DURATION=""; COUNT=""; LIVE=1; OUTPUT=""; BACKGROUND=0; NO_SUMMARY=0
DO_BRIDGE=0; DO_UNBRIDGE=0; DO_LIST=0; DO_SUMMARY_ONLY=""; SUMMARY_FLAG_GIVEN=0; DO_STATUS=0; DO_STOP=0; DO_ADAPTERS=0
BR_IFACE1=""; BR_IFACE2=""; BRIDGE_DHCP=0

# ip_link - thin wrapper around every `ip link` call this script makes.
# BUG FOUND AND FIXED (CRITICAL - very likely a real contributor to a live
# incident: a --bridge attempt got stuck at the platform's own "Starting
# Lan Sniffer" splash and never progressed, and afterward eth0 was left
# out of br-lan with SSH down). Every `ip link` invocation talks to the
# kernel over netlink with NO timeout of its own - normally near-instant,
# but if the network stack is sufficiently wedged (the same class of
# problem that made reset.sh's own `ubus call network reload` hang before
# ITS timeout fix this session), any one of these calls could block
# forever. Since --bridge runs several of these in sequence (add bridge,
# attach iface1, attach iface2, bring each up) reached through payload.sh's
# blocking `$(...)` command substitution, a single hung `ip link` call
# here would explain the reported symptom exactly: nothing ever prints,
# the platform's launch splash never gets replaced, and if BR_IFACE1
# (eth0) already got attached to br-sniff before a LATER step hung, eth0
# is already pulled out of br-lan at that point too - stuck exactly as
# reported. A bounded timeout guarantees every netlink operation this
# script performs either finishes or fails cleanly within a few seconds,
# so a hang here can never become an indefinite one.
#
# BIG CHANGE (adopting common.sh's shared primitive): this used to be its
# own local definition (`timeout 5 ip link "$@"`, no override) shadowing
# the identical one lib/common.sh now provides for every script - same
# behavior (still 5s by default), just one canonical implementation
# instead of two, and now also honors PAGER_IP_LINK_TIMEOUT like every
# other caller of the shared version.

list_wired_ifaces() {
    # busybox `ip` on this device doesn't support `-br` at all (just dumps
    # usage) - /sys/class/net/ is simpler and needs no ip flag support.
    ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|usb)' | grep -v '^eth0$'
}

# detect_usb_c - the built-in USB-C port. Always shows up as eth0 (confirmed
# via its sysfs device path being a platform device, 10100000.ethernet -
# i.e. the SoC's own USB-Ethernet gadget controller, not a USB peripheral).
# Per Hak5's docs this is a Realtek RTL8153 USB-Ethernet device to the host
# PC, and is also the SSH/management link - if you're reading this over
# SSH via the stock connection, this one is almost certainly up already.
# (iface_has_carrier and detect_usb_a_iface come from lib/common.sh - used
# identically by pc_link.sh, pulled out there instead of duplicated here.)
detect_usb_c() {
    [ -e /sys/class/net/eth0 ] || { echo "eth0||down"; return; }
    if iface_has_carrier eth0; then echo "eth0||up"; else echo "eth0||down"; fi
}

# check_adapters - prints USB-C/USB-A status and returns 0 only if BOTH
# have link-up (the precondition for a meaningful --bridge tap).
check_adapters() {
    local c_if c_state a_if a_state
    IFS='|' read -r c_if _ c_state <<< "$(detect_usb_c)"
    a_if=$(detect_usb_a_iface)
    if [ -n "$a_if" ] && iface_has_carrier "$a_if"; then a_state="up"; else a_state="down"; fi

    if [ "$c_state" = "up" ]; then
        say "USB-C (built-in, $c_if): connected"
    else
        say "USB-C (built-in, $c_if): not connected"
    fi

    if [ -z "$a_if" ]; then
        say "USB-A (external adapter): none detected"
    elif [ "$a_state" = "up" ]; then
        say "USB-A (external adapter, $a_if): connected"
    else
        say "USB-A (external adapter, $a_if): detected but link down ($a_if exists but no carrier - check the cable/adapter)"
    fi

    if [ "$c_state" = "up" ] && [ "$a_state" = "up" ]; then
        say "Both adapters connected - tap/bridge mode is ready: sniff.sh --bridge $c_if $a_if"
        return 0
    else
        say "Only one (or neither) adapter is connected - bridge/tap mode needs both. Single-NIC capture still works fine."
        return 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) need_arg "--iface" "$#"; IFACE="$2"; shift 2 ;;
        --filter) need_arg "--filter" "$#"; FILTER="$2"; shift 2 ;;
        --duration) need_arg "--duration" "$#"; DURATION="$2"; shift 2 ;;
        --count) need_arg "--count" "$#"; COUNT="$2"; shift 2 ;;
        --quiet) LIVE=0; shift ;;
        --live) shift ;;  # live is the default now - kept as a harmless no-op flag
        --output) need_arg "--output" "$#"; OUTPUT="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        --no-summary) NO_SUMMARY=1; shift ;;
        # BUG FOUND AND FIXED: need_arg was called twice against the SAME
        # unchanged "$#" (need_arg doesn't shift anything itself) - it only
        # ever verified "at least one more arg after --bridge", never "at
        # least two". `sniff.sh --bridge eth1` (missing the 2nd interface)
        # passed both checks, then "$3" didn't exist - under `set -u` that
        # crashed with a raw "3: unbound variable" instead of a clean
        # error. A single check against the real requirement (3 tokens:
        # --bridge + two interface names) is correct here, matching how
        # every OTHER multi-value flag in this toolkit (filters.sh --set,
        # vpn.sh --enable-full, etc.) does a single "$# -lt N" check
        # instead of reusing the single-arg need_arg helper twice.
        --bridge) DO_BRIDGE=1; [ "$#" -lt 3 ] && die "--bridge needs two interface names, e.g. --bridge eth0 eth1"; BR_IFACE1="$2"; BR_IFACE2="$3"; shift 3 ;;
        --dhcp) BRIDGE_DHCP=1; shift ;;
        --unbridge) DO_UNBRIDGE=1; shift ;;
        --list) DO_LIST=1; shift ;;
        --adapters) DO_ADAPTERS=1; shift ;;
        --summary) need_arg "--summary" "$#"; DO_SUMMARY_ONLY="$2"; SUMMARY_FLAG_GIVEN=1; shift 2 ;;
        --status) DO_STATUS=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BUG FOUND AND FIXED (CRITICAL, found via code review - matches this
# review's own requested scenario, "--summary given alongside --bridge"):
# every one of this script's mode-selecting flags (--summary, --list,
# --adapters, --status, --stop, --unbridge, --bridge) is independently
# checked further down, each in its own `if [ "$DO_X" = "1" ]; then ...;
# exit 0; fi` block, in a fixed order. Nothing here ever verified only ONE
# was actually given - `sniff.sh --bridge eth0 eth1 --summary old.pcap`
# parses BOTH DO_BRIDGE=1 and SUMMARY_FLAG_GIVEN=1 without complaint, then
# execution falls into the FIRST matching `if` in file order (--summary's
# check comes first) and exits right there - the --bridge request the
# caller also explicitly typed is silently thrown away with zero
# indication it was ever seen, let alone ignored. Every other pairing of
# these flags has the identical silent-priority problem (`--list --stop`
# only ever lists; `--adapters --unbridge` only ever checks adapters),
# just less surprising than the bridge/summary case this task named
# directly. Rejecting more than one at parse time - loud and immediate,
# this toolkit's standard convention for a bad combination - beats
# silently honoring whichever check happens to run first.
_mode_count=0; _mode_names=""
for _mode_flag in "$SUMMARY_FLAG_GIVEN:--summary" "$DO_LIST:--list" "$DO_ADAPTERS:--adapters" "$DO_STATUS:--status" "$DO_STOP:--stop" "$DO_UNBRIDGE:--unbridge" "$DO_BRIDGE:--bridge"; do
    case "$_mode_flag" in
        1:*)
            _mode_count=$((_mode_count + 1))
            _mode_names="${_mode_names:+$_mode_names, }${_mode_flag#1:}"
            ;;
    esac
done
[ "$_mode_count" -gt 1 ] && die "These flags select different, conflicting actions and can't be combined: $_mode_names. Run sniff.sh once per action (e.g. finish or cancel the bridge first, then re-run with --summary)."

# BUG FOUND AND FIXED (found via code review): --dhcp only ever does
# anything inside the `if [ "$DO_BRIDGE" = "1" ]` block far below (it
# requests a DHCP lease ON the bridge device --bridge just created) - the
# header above even documents it as "With --bridge: ...". Given without
# --bridge (e.g. a plain `sniff.sh --iface eth1 --dhcp`, or `--dhcp` typed
# alongside --status/--list/etc.), BRIDGE_DHCP is still set to 1 by the
# parser above but nothing downstream ever checks it outside that one
# block - the flag is silently accepted and silently does nothing, with no
# hint to the caller that what they asked for never happened. Same "loud
# beats silent" convention as the mode-conflict check just above.
[ "$BRIDGE_DHCP" = "1" ] && [ "$DO_BRIDGE" != "1" ] && die "--dhcp only makes sense together with --bridge (it requests a DHCP lease on the bridge device --bridge creates). Did you mean: sniff.sh --bridge IFACE1 IFACE2 --dhcp"

# BUG FOUND AND FIXED (found via code review): --bridge's own arg-count
# check (right above, in the parser) only ever verified TWO interface
# names were given, never that they're actually two DIFFERENT interfaces.
# `sniff.sh --bridge eth1 eth1` passes that check, then passes the
# existence check further down too (the same real interface, checked
# twice) - the script goes on to create br-sniff and enslave eth1 to it,
# then try to enslave eth1 to it AGAIN (a harmless no-op the second time),
# ending up with a "bridge" that has exactly one port, not the two-NIC
# transparent tap this whole feature exists to build. Nothing about that
# resembles a working tap and nothing said so - it would just silently
# "succeed" with a single-legged bridge that passes no traffic through at
# all. Reject the degenerate case explicitly instead.
if [ "$DO_BRIDGE" = "1" ] && [ "$BR_IFACE1" = "$BR_IFACE2" ]; then
    die "--bridge needs two DIFFERENT interface names (got '$BR_IFACE1' twice) - bridging an interface to itself isn't a two-NIC tap."
fi

# BUG FOUND AND FIXED (found via code review): --duration and --count were
# the two numeric CLI arguments in this whole toolkit with NO validation at
# all - every other numeric flag elsewhere (deauth.sh's --channel/
# --interval, bluetooth.sh's --duration/--burst/--scan-time/--size,
# battery.sh's --interval, examine.sh's channel/time) rejects a non-numeric
# value up front with a clear message. Here, a typo'd --duration/--count
# was handed straight to `timeout "$DURATION" tcpdump ...` / `tcpdump -c
# "$COUNT"` - `timeout`/`tcpdump` reject a garbage value themselves, but
# with no check here that failure looks exactly like "a capture that
# caught nothing" (an empty/missing .pcap, a bare "0 packets" summary)
# instead of the immediate, specific "your --duration is wrong" this
# toolkit's own convention would normally give.
[ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'--duration' needs a whole number of seconds (got '$DURATION')." ;; esac
[ -n "$COUNT" ] && case "$COUNT" in *[!0-9]*) die "'--count' needs a whole number of packets (got '$COUNT')." ;; esac

# BUG FOUND AND FIXED (edge case, verified locally - not a re-litigation of
# the digit check above, a separate gap in it): "0" itself sailed straight
# through that check as "a valid whole number" for both flags, but isn't
# harmless the way a user would assume - it doesn't mean "capture nothing"/
# "stop immediately", it means the OPPOSITE. Verified locally:
# `time timeout 0 sleep 3` (GNU coreutils, same tool/semantics this script
# wraps via `timeout "$DURATION" tcpdump ...`) took the full 3 seconds, not
# 0 - confirming the documented behavior that a duration of 0 disables the
# timeout entirely rather than firing it instantly. `tcpdump -c 0` behaves
# the same way for --count: libpcap's own pcap_loop(3) documents "a value
# of -1 or 0 for cnt is equivalent to infinity". So `--duration 0` or
# `--count 0` would each silently launch an UNBOUNDED capture instead of
# the "stop immediately"/"capture nothing" a user typing 0 would reasonably
# expect - reachable not just from a CLI typo but from the LAN Sniffer
# payload's own NUMBER_PICKER (pick_duration() there has no lower-bound
# check either) feeding straight into --duration. Dangerous specifically
# for a --background run on this disk/RAM-constrained device, with no
# other backstop to ever end it. Reject it explicitly, same clear-error
# convention as every other bad value here.
[ "$DURATION" = "0" ] && die "'--duration' can't be 0 - tcpdump/timeout treat 0 as 'no limit', not 'stop immediately', so this would start an unbounded capture instead. Use a real duration (e.g. 1) or --count 1 if you just want a single packet."
[ "$COUNT" = "0" ] && die "'--count' can't be 0 - tcpdump treats a count of 0 as 'unlimited', not 'capture nothing', so this would start an unbounded capture instead. Use a real packet count."

# BUG FOUND AND FIXED (found via code review - the digit-only check above
# rejects anything non-numeric or negative, but never bounds how MANY
# digits): an absurdly long, all-digit value (a fat-fingered extra zero or
# two, or a paste gone wrong) still passes it as "a valid whole number."
# Two separate, real downstream risks from that, reasoned from documented
# behavior rather than confirmed against this exact device's own tcpdump
# build (no live device available to this pass, same honesty standard as
# the CAP_RC reasoning further down this file): (1) --count is handed to
# tcpdump's own `-c` option, which C's atoi()/strtol() family parses into a
# fixed-width integer - on a 64-bit userspace where `long` is wider than
# `int` (e.g. aarch64/x86_64 Linux), a value that overflows `long` clamps
# to LONG_MAX on standards-conforming libc, but atoi()'s further
# (int)-narrowing cast of THAT clamped value is implementation-defined and
# commonly truncates to the low 32 bits - for LONG_MAX specifically, that's
# 0xFFFFFFFF, i.e. -1, and this file's own header above already documents
# libpcap treating "-1 or 0 for cnt is equivalent to infinity." A --count
# meant to bound a capture could silently become the exact unbounded
# capture the 0-rejection fix above exists to prevent, just reached via a
# huge number instead of a small one. (2) Independent of that platform-
# specific risk, a --duration/--count in the billions/trillions is never a
# real, intended value for a packet capture on this device regardless of
# how any particular libc happens to parse it - it's always either a typo
# or a bad input, and letting it through to `timeout`/tcpdump to fail (or
# not fail) however they see fit forfeits the same immediate, specific
# error this toolkit's whole numeric-validation convention exists to give.
# Bounding both to a still-extremely-generous but finite ceiling - 30 days
# of seconds, 100 million packets (each comfortably clear of any 32-bit
# signed-int boundary, so the bound itself can never become part of the
# same overflow problem it's guarding against) - catches every realistic
# typo while never constraining an actual real-world capture on this
# hardware, which this file's own MAX_LIVE_WATCH_BYTES/MAX_BRIDGE_SECS
# comments already establish is meant for short diagnostic sessions, not
# multi-week unattended runs.
# BUG FOUND AND FIXED (re-auditing the bound check just below, before it
# ever shipped - verified with a standalone `bash -c` repro): a bare
# `[ "$DURATION" -gt 2592000 ]` on a value long enough to overflow bash's
# OWN 64-bit arithmetic doesn't cleanly evaluate false/true - confirmed
# standalone that `[ "99999999999999999999999999" -gt 100 ]` errors out
# with "integer expression expected" and returns exit status 2, which the
# surrounding `&&` chain treats as "condition not met" and moves on
# WITHOUT calling die - so the single most extreme case this bound exists
# to catch (a wildly-overflowing paste) is exactly the case the naive
# version of this check would have silently let through. A cheap length
# check first (more digits than any real value could ever need, and far
# short of where bash's own comparison could overflow) catches that case
# before the numeric comparison ever runs on it.
if [ -n "$DURATION" ] && [ "${#DURATION}" -gt 15 ]; then
    die "'--duration' ('$DURATION', ${#DURATION} digits) is not a realistic number of seconds - looks like a typo or a bad paste, not an intended capture length."
fi
if [ -n "$COUNT" ] && [ "${#COUNT}" -gt 15 ]; then
    die "'--count' ('$COUNT', ${#COUNT} digits) is not a realistic packet count - looks like a typo or a bad paste, not an intended count."
fi
[ -n "$DURATION" ] && [ "$DURATION" -gt 2592000 ] && die "'--duration' of ${DURATION}s (over 30 days) looks like a typo, not an intended capture length - use a smaller value, or omit --duration and --stop it manually if you really do need an open-ended capture."
[ -n "$COUNT" ] && [ "$COUNT" -gt 100000000 ] && die "'--count' of $COUNT packets (over 100 million) looks like a typo, not an intended packet count - this device doesn't have the disk/RAM for a capture that large. Use a smaller value."

# Shared by summarize_pcap (end-of-capture scan) AND run_creds_watcher
# (live, DURING-capture scan) - one definition so the two can't drift.
# Covers HTTP Basic Auth, query-string logins, raw FTP/Telnet USER/PASS,
# JSON request-body password fields, and Authorization: Bearer tokens (a
# captured one is session hijacking, just as real a finding as a password).
CREDS_PATTERN='authorization: basic|authorization: bearer|(^|[?&])(pass|passwd|pwd|user|login|email)=|^USER |^PASS |"(pass|passwd|pwd|password)"[[:space:]]*:'

# MAX_SUMMARY_SCAN_BYTES - hard ceiling on how much of a saved capture
# summarize_pcap will fully -A/-nn decode into in-memory bash variables in
# one pass (see the BUG FOUND AND FIXED comment inside summarize_pcap
# itself for the full reasoning - this exists because the 90s timeout on
# those two tcpdump calls bounds time, not the memory needed to hold their
# output). 25MB raw pcap, even at tcpdump -A's documented multi-times ASCII
# expansion, keeps NN_DUMP+A_DUMP together in the tens-of-MB range - a real
# cost on a 251MB device, but nowhere near the hundreds-of-MB-to-GB range a
# genuinely large, hours-long background capture could otherwise produce.
# Deliberately well above MAX_LIVE_WATCH_BYTES (4MB): this is a one-time
# cost (not re-run every 5s), so it can afford to cover a much larger
# capture before falling back to a bounded snapshot.
MAX_SUMMARY_SCAN_BYTES=26214400

# SUMMARY_NOTICE_THRESHOLD_BYTES - size (20MB) past which summarize_pcap
# prints the "may take a while and use real memory" heads-up before
# decoding - below MAX_SUMMARY_SCAN_BYTES (25MB) itself, which is the hard
# ceiling where it switches to a bounded snapshot instead of the full file
# (see that constant's own comment). Pulled up from an inline literal to a
# named constant alongside it, same value, no behavior change - was
# previously just a bare `20971520` inline in the size check below.
SUMMARY_NOTICE_THRESHOLD_BYTES=20971520

# SUMMARY_SCAN_TIMEOUT_SECS - bound on each of summarize_pcap's two full-
# file tcpdump decode passes (-nn and -A). 90s is generous since this is a
# one-time cost per capture (not re-run every few seconds like the live
# watchers below), but still finite so a pathological file fails cleanly
# instead of hanging. Pulled up from two inline `timeout 90` literals to a
# named constant, same value, no behavior change.
SUMMARY_SCAN_TIMEOUT_SECS=90

# extract_src_ips - reads tcpdump -nn output on stdin, prints one source
# address per line (the token right before " > "), with any appended
# ":port"/".port" stripped - one address per input line, unsorted/
# uncounted (summarize_pcap's own "Top source IPs" section pipes this
# into sort | uniq -c | sort -rn | awk 'NR<=10{...}' for the ranked report;
# kept
# as a separate, pure, sample-input-testable function rather than inlined
# there so this exact address/port-stripping logic - including the two
# BUG FOUND AND FIXED cases below - can be exercised with synthetic input
# in scripts/tests/, not just against a real capture).
#
# BUG FOUND AND FIXED (live-caught): the old pattern unconditionally
# stripped a trailing ".NUMBER" assuming it was always a port - but
# protocols with no port (ICMP: "IP 172.16.52.1 > ...", no port at
# all) still have exactly 4 dot-separated numbers, and the regex's
# greedy match happily treated the real last OCTET as if it were a
# port and stripped it - confirmed live: a real ICMP packet from
# 172.16.52.1 was reported as source "172.16.52" (3 octets, wrong).
# Only strip a trailing number now if what's left AFTER stripping
# still has a genuine 4-octet IPv4 address underneath it (i.e. there
# really was a 5th, port, component) - a bare 4-octet address (ICMP)
# is left exactly as captured.
extract_src_ips() {
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == ">") {
                    ip = $(i - 1)
                    if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) sub(/\.[0-9]+$/, "", ip)
                    # BUG FOUND AND FIXED: the IPv4 fix above only strips a
                    # trailing ".port" when what is left is a genuine
                    # 4-octet address - but tcpdump appends a port the SAME
                    # way for IPv6 (e.g. "fe80::1.12345"), and that never
                    # matches the all-digits IPv4 regex, so the port was
                    # never stripped there. Same two hosts talking on
                    # different ports then counted as different "IPs" in
                    # the ranking below, diluting the real top talker.
                    # IPv6 addresses always contain ":" and never contain
                    # a literal "." of their own (no IPv4-mapped forms seen
                    # in this device tcpdump output) - a colon plus a
                    # trailing ".NUMBER" is unambiguously an appended port.
                    else if (ip ~ /:/ && ip ~ /\.[0-9]+$/) sub(/\.[0-9]+$/, "", ip)
                    print ip
                    break
                }
            }
        }'
}

# classify_protocols - reads tcpdump -nn output on stdin, prints one
# classified protocol name (ARP/ICMP/STP/TCP/DNS/UDP/OTHER-IP) per input
# line - one classification per line, unsorted/uncounted (summarize_pcap's
# own "Protocols seen" section pipes this into sort | uniq -c | sort -rn
# for the ranked report). Pulled out as its own pure, sample-input-
# testable function for the same reason as extract_src_ips above.
#
# tcpdump's default text output rarely contains the literal words "TCP"
# or "DNS" - it shows "Flags [S]" for TCP and query markers like "A?"
# for DNS instead. Classify by those actual markers (verified against
# real tcpdump output samples), not by literal protocol-name grepping.
# BUG FOUND AND FIXED (verified with a standalone awk test against a
# real tcpdump line format, not assumed): an STP (Spanning Tree
# Protocol, 802.1d) BPDU - real, documented tcpdump output looks like
# "STP 802.1d, Config, Flags [none], bridge-id 8000.<mac>.8003, length
# 43" (confirmed against tcpdump's own test fixtures/real capture
# reports) - was silently miscounted as "TCP" here, because the SAME
# `/Flags \[/` pattern meant to catch TCP's "Flags [S]"/"Flags [P.]"
# also matches STP's unrelated "Flags [none]" field, and the TCP rule
# ran before anything STP-specific could catch it first. Reproduced
# standalone: feeding a synthetic NN_DUMP containing one real STP BPDU
# line plus one real TCP SYN line through this exact awk script
# classified BOTH as "TCP" (2 total), not 1 TCP + 1 STP. Directly
# reachable in this tool's own primary use case, not just theoretical:
# --bridge builds a real transparent Ethernet tap (br-sniff) between
# two NICs specifically so traffic actually flows through it, and any
# switch on either side of that tap sending periodic STP BPDUs (a very
# ordinary, common thing switches do) would show up captured on
# br-sniff/eth1 and get folded into the TCP count, corrupting the one
# summary this tool exists to give an accurate, immediate report from.
# Added a dedicated STP rule (matched the same "timestamp then keyword"
# structural style already used by the OTHER-IP rule below) ahead of
# the Flags-based TCP rule, so a real STP frame is classified correctly
# and no longer inflates the TCP bucket.
classify_protocols() {
    awk '
        /ARP,/ { print "ARP"; next }
        /ICMP/ { print "ICMP"; next }
        /^[0-9:.]+ STP / { print "STP"; next }
        /Flags \[/ { print "TCP"; next }
        /[0-9]+\+? (A|AAAA|PTR|MX|TXT|CNAME|NS)\?/ { print "DNS"; next }
        /: UDP,/ { print "UDP"; next }
        /^[0-9:.]+ IP6? / { print "OTHER-IP"; next }
    '
}

summarize_pcap() {
    local file="$1"
    [ ! -s "$file" ] && { err "No/empty capture file: $file"; return 1; }
    command -v tcpdump >/dev/null 2>&1 || { err "tcpdump not found - can't summarize."; return 1; }

    local total size NN_DUMP A_DUMP host_hits dns_query_lines
    # PERFORMANCE FIX (real, measured cost, not just style): this function
    # used to invoke tcpdump on the SAME capture file EIGHT separate times
    # below (five `-nn -r` calls, three `-A -r` calls - including two
    # outright duplicate re-runs just to check "was that empty" after
    # already computing the identical result once). Each invocation is an
    # independent full parse-and-reformat pass over the ENTIRE file from
    # byte 0 - tcpdump has no incremental/resume mode, so there's no way to
    # make any single pass cheaper, but there's also no reason to redo the
    # same pass multiple times. For a large capture this multiplied the
    # real CPU cost of one summary by ~8x for no benefit. Read each of the
    # two distinct output shapes this function actually needs (-nn -r for
    # packet/header summaries, -A -r for ASCII payload) exactly ONCE and
    # reuse the captured text for every section below - cuts 8 full-file
    # passes down to 2.
    # BUG FOUND AND FIXED (live-caught - a real, extended, busy capture
    # crashed the device after "a while recording packets"): these two
    # calls had no bound at all, on a file that can grow arbitrarily large
    # for an --duration-less "until stopped" background capture. This is a
    # ONE-TIME cost (unlike run_creds_watcher/run_packet_feed's repeated
    # per-cycle re-scans, already capped separately via MAX_LIVE_WATCH_
    # BYTES), so a full pass is still worth attempting even for a large
    # file rather than silently truncating real capture data - but it
    # needs a bound so a pathological case fails cleanly instead of
    # hanging/compounding memory pressure right as the capture is also
    # winding down (when the main tcpdump process and any still-exiting
    # watcher/feed subshells are all still holding their own memory).
    # 90s is generous (this runs once, not every 5s) but still finite.
    #
    # BUG FOUND AND FIXED (CRITICAL - this is the same "crashed the device"
    # incident the 90s timeout above was already added for, but the timeout
    # only bounds TIME, not memory, and re-checking the actual mechanics
    # shows it doesn't close the real hole). NN_DUMP and A_DUMP are plain
    # bash command-substitution variables - the ENTIRE decoded text has to
    # be materialized as one contiguous in-process buffer before a single
    # byte of it can be used, and BOTH stay resident simultaneously (A_DUMP
    # is computed while NN_DUMP is still in scope, and neither is unset
    # until the function returns). tcpdump -A's ASCII expansion is already
    # documented elsewhere in this file as "typically several times LARGER"
    # than the binary pcap it's decoding. summarize_pcap is deliberately
    # NOT capped by MAX_LIVE_WATCH_BYTES (see that constant's own comment -
    # "a full pass is still worth attempting even for a large file"), which
    # is the right call for a --duration-less background capture ("until
    # stopped", the exact scenario that produced the original crash
    # report) - but at this session's own measured growth rate (~10.5MB in
    # 20s on a busy capture, ~0.5MB/s), even a modest 20-30 minute
    # unattended background run reaches several hundred MB on disk, and
    # decoding THAT into two simultaneous multi-hundred-MB-to-GB-scale bash
    # strings on a 251MB-RAM device is a near-certain OOM - plausibly the
    # ACTUAL mechanism behind the original incident, not just a slow-pass
    # symptom the 90s bound happens to catch in time (90s is easily enough
    # wall-clock budget to emit far more output than this device has RAM
    # for, long before the deadline would ever fire). Added a separate,
    # genuinely protective hard byte ceiling (distinct from the 20MB
    # "please wait" notice above, which only warns - it doesn't limit
    # anything): past MAX_SUMMARY_SCAN_BYTES, decode a byte-bounded
    # snapshot of the file (same `head -c` technique used for the
    # MAX_LIVE_WATCH_BYTES race fix in run_creds_watcher/run_packet_feed
    # below) instead of the full file, with a clear, honest notice - same
    # "don't silently truncate without saying so" convention as every other
    # cap in this file. The saved .pcap itself is never touched.
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    local scan_file="$file" scan_note=""
    # Only show the "may take a while" notice when we're actually about to
    # decode the full file - once MAX_SUMMARY_SCAN_BYTES kicks in below, the
    # decode is bounded to that size regardless of how much larger the real
    # file is, so warning about a full-file cost that isn't going to happen
    # would just be confusing alongside the truncation notice.
    if [ "${size:-0}" -gt "$SUMMARY_NOTICE_THRESHOLD_BYTES" ] 2>/dev/null && [ "${size:-0}" -le "$MAX_SUMMARY_SCAN_BYTES" ] 2>/dev/null; then
        say "Capture is $((size / 1024 / 1024))MB - summarizing may take a while and use real memory on this device, please wait..."
    fi
    if [ "${size:-0}" -gt "$MAX_SUMMARY_SCAN_BYTES" ] 2>/dev/null; then
        scan_file="/tmp/pager-sniff-summary-snap.$$"
        head -c "$MAX_SUMMARY_SCAN_BYTES" "$file" > "$scan_file" 2>/dev/null
        # Defensive fallback (this `head -c` is new, unlike this file's
        # existing `head -N` line-count usages elsewhere - if this device's
        # head build somehow doesn't support -c, don't let the safety fix
        # itself silently turn into an empty/broken summary): only trust
        # the snapshot if it actually produced real bytes, otherwise fall
        # back to the full file - the original, still-timeout-bounded
        # behavior - rather than decode nothing.
        if [ -s "$scan_file" ]; then
            scan_note="This capture is $((size / 1024 / 1024))MB - only the first $((MAX_SUMMARY_SCAN_BYTES / 1024 / 1024))MB was decoded for this summary (decoding the whole thing risks exhausting this device's RAM). The saved .pcap itself is complete and untouched; review it directly (e.g. download and open in Wireshark) for the full picture."
            err "$scan_note"
        else
            rm -f "$scan_file"
            scan_file="$file"
            err "Couldn't create a bounded snapshot of this $((size / 1024 / 1024))MB capture (head -c may be unsupported on this device) - falling back to a full-file decode; this may be slow and use significant memory."
        fi
    fi
    NN_DUMP=$(timeout "$SUMMARY_SCAN_TIMEOUT_SECS" tcpdump -nn -r "$scan_file" 2>/dev/null); local nn_rc=$?
    A_DUMP=$(timeout "$SUMMARY_SCAN_TIMEOUT_SECS" tcpdump -A -r "$scan_file" 2>/dev/null); local a_rc=$?
    [ "$scan_file" != "$file" ] && rm -f "$scan_file"
    # BUG FOUND AND FIXED (same silent-truncation class as run_creds_
    # watcher's own fix, applied here too - this is the FINAL, most-relied-
    # on report for a whole capture, so a quietly incomplete one is worse
    # than a slow one): both calls are direct (non-piped) command
    # substitutions, so $? right after each one is that specific timeout's
    # own exit code, not something absorbed by a later pipeline stage. 124
    # means genuinely cut off at 90s, not just "a smaller-than-expected but
    # complete" capture.
    if [ "$nn_rc" -eq 124 ] || [ "$a_rc" -eq 124 ]; then
        err "This summary was cut off after 90s (an unusually large capture for this device) - the numbers below only cover what was scanned before the cutoff, not the whole file. The raw .pcap itself is complete and untouched; review it directly (e.g. download and open in Wireshark) for the full picture."
    fi
    # grep -c . (not `wc -l`) to count lines in an already-captured
    # variable: command substitution strips ALL trailing newlines, so
    # `echo "$var" | wc -l` would misreport an empty capture as 1 line
    # instead of 0. grep -c . counts only non-blank lines, which gives the
    # same answer as the original `tcpdump ... | wc -l` in both the empty
    # and non-empty case (same idiom already used by run_creds_watcher/
    # run_packet_feed elsewhere in this file for the same reason).
    total=$(echo "$NN_DUMP" | grep -c .)
    echo
    echo "== Capture summary: $file =="
    echo "  Total packets: $total"
    echo "  Capture file size: $((size)) bytes"

    if [ "$total" = "0" ]; then
        echo "  (nothing captured)"
        return 0
    fi

    echo
    echo "  Top source IPs:"
    # Address/port-stripping logic lives in extract_src_ips() above (kept
    # as a standalone function so it can be unit-tested with synthetic
    # input in scripts/tests/, independent of a real tcpdump run).
    # PERFORMANCE FIX (verified with a standalone repro before applying -
    # every case matched: fewer than 10 groups, exactly 10, more than 10,
    # ties at the cutoff, and empty input): `head -10` followed immediately
    # by an `awk` that already exists in this same pipeline is one process
    # more than this needs - `awk 'NR<=10{...}'` does the identical
    # first-10-records job itself, so folding it into the awk that was
    # already there removes a subprocess spawn (fork+exec has real,
    # non-trivial cost on this MIPS device) from this report's three
    # ranked-list sections with no output change.
    echo "$NN_DUMP" | extract_src_ips | sort | uniq -c | sort -rn | awk 'NR<=10{printf "    %6d  %s\n", $1, $2}'

    echo
    echo "  Protocols seen:"
    # Classification logic lives in classify_protocols() above (kept as a
    # standalone function so it can be unit-tested with synthetic input in
    # scripts/tests/, independent of a real tcpdump run).
    echo "$NN_DUMP" | classify_protocols | sort | uniq -c | sort -rn | awk '{printf "    %6d  %s\n", $1, $2}'

    echo
    echo "  HTTP Host headers seen (plaintext - real sites/services visited):"
    # IMPROVEMENT: DNS queries show intent to look something up; the HTTP
    # Host header shows an ACTUAL plaintext request going out to a real
    # site/service - a more direct piece of recon than DNS alone (also
    # catches direct-IP HTTP requests with no matching DNS query in this
    # capture window at all).
    host_hits=$(echo "$A_DUMP" | grep -oiE '^host: [^ ]+' | awk '{print $2}' | tr -d '\r')
    if [ -n "$host_hits" ]; then
        # PERFORMANCE FIX: same `head -10` + separate `awk` merge as the
        # "Top source IPs" section above - see its own comment for the
        # standalone-repro verification this was checked against.
        echo "$host_hits" | sort | uniq -c | sort -rn | awk 'NR<=10{printf "    %6d  %s\n", $1, $2}'
    else
        echo "    none seen (no plaintext HTTP, or it's all HTTPS/encrypted)"
    fi

    echo
    echo "  Top queried domains (DNS):"
    # IMPROVEMENT: the summary already classified DNS traffic by volume,
    # but never showed WHAT was being looked up - the actual queried
    # domain names are real, useful recon (what sites/services a device
    # on this network is talking to) that was sitting unused in the same
    # capture. tcpdump's DNS query line looks like ".../udp: ... 12345+
    # A? example.com. (28)" - the domain is the token right before the
    # trailing "(NN)" length marker.
    dns_query_lines=$(echo "$NN_DUMP" | grep -E '[0-9]+\+? (A|AAAA|PTR|MX|TXT|CNAME|NS)\? ')
    if [ -n "$dns_query_lines" ]; then
        # PERFORMANCE FIX: same `head -10` + separate `awk` merge as the
        # "Top source IPs" section above - see its own comment for the
        # standalone-repro verification this was checked against.
        echo "$dns_query_lines" | \
            grep -oE '(A|AAAA|PTR|MX|TXT|CNAME|NS)\? [^ ]+\.' | awk '{print $2}' | sed 's/\.$//' | \
            sort | uniq -c | sort -rn | awk 'NR<=10{printf "    %6d  %s\n", $1, $2}'
    else
        echo "    none seen"
    fi

    echo
    echo "  Possible cleartext credentials (HTTP Basic Auth / form logins / FTP-Telnet / JSON login bodies / bearer tokens):"
    local hits
    hits=$(echo "$A_DUMP" | grep -iE "$CREDS_PATTERN" | head -15)
    if [ -n "$hits" ]; then
        # IMPROVEMENT: highlight the actual matched credential text in RED
        # (standard ANSI SGR, \033[31m...\033[0m) so a real hit can't get
        # lost by eye in a scroll of otherwise-plain summary output - asked
        # for explicitly: "pw and usernames... should be marked as Red
        # text". `grep --color=always` does exactly this (colors only the
        # matched substring, not the whole line) and every terminal that
        # can SSH into this device honors ANSI codes; redirected to a file
        # (--save/--summary piped elsewhere) it degrades to plain escape
        # sequences in the text, not lost data.
        echo "$hits" | GREP_COLORS='mt=1;31' grep --color=always -iE "$CREDS_PATTERN" | sed 's/^/    /'
        echo "  (found matches above - review the full pcap for context, these are pattern hits, not guaranteed valid creds)"
    else
        echo "    none found"
    fi
    echo
}

# HTTP request-line / Host-header pattern - shared with summarize_pcap's
# own "HTTP Host headers seen" section, same reasoning as CREDS_PATTERN
# above (one definition, no drift between the live watcher and the
# end-of-capture summary).
HTTP_PATTERN='^(GET|POST|PUT|DELETE|HEAD) /|^host: '

# watcher_block_bounds LINENO - given the (pre-computed, newline-
# separated) list of tcpdump -A packet-header line numbers in
# $blocks_lines, finds the enclosing block's [start, end) line range for
# LINENO. Cheap: operates on a short list of plain integers, not on
# packet text - this is what keeps watcher_tag_hit() below fast even
# though blocks_lines itself can have thousands of entries (one per
# packet).
watcher_block_bounds() {
    # BUG FOUND AND FIXED (verified with a standalone awk+sed test, not just
    # read-through): `bs` was only ever assigned inside the `$1 <= ln`
    # branch, with no BEGIN default - if LINENO falls before every entry in
    # blocks_lines (or blocks_lines is empty/malformed - exactly the
    # "truncated tcpdump -A output" case this was asked to be checked
    # against), that branch never runs and `bs` stays the empty string.
    # Confirmed live via a standalone test: with bs="", the caller's
    # `sed -n "${bs}p" "$dumpfile"` silently becomes `sed -n "p"` (no
    # address at all) - NOT an error, it prints the ENTIRE dumpfile instead
    # of just the intended line, so watcher_tag_hit() would resolve the
    # source IP from whatever the FIRST " > " line in the whole dump
    # happens to be rather than the actual hit's own enclosing packet -
    # a real misattribution, not a crash. The companion host-range call
    # (`sed -n "${bs},$((be-1))p"`) becomes a leading-comma range with no
    # start address, which is a genuine sed syntax error ("unknown command
    # `,'") - harmlessly swallowed today since callers don't check sed's
    # exit code (host just falls back to "?"), but still wrong.
    # A naive `BEGIN { bs = 1 }` default alone was NOT enough - verified
    # that still failed for a genuinely empty blocks_lines: the here-string
    # `<<<""` feeds awk exactly one blank record, and the old unconditional
    # `{ if ($1 <= ln) bs = $1 }` treats a blank $1 as numeric 0, which is
    # always <= ln, so it overwrote the BEGIN default right back to "".
    # Guarding both branches on `NF` (skip blank/fieldless records
    # entirely) closes that too - verified against all 5 cases (mid-range,
    # past-the-end, empty blocks_lines, ln-before-first-entry, ln exactly
    # on a header) with a standalone script before applying here. In real
    # operation this path is normally unreachable (tcpdump's block-buffered
    # stdout means a killed/truncated re-scan either has a complete first
    # header line or is empty - caught by the caller's own `[ -s "$dumpf" ]`
    # check before this is ever called), but the fix is free and removes a
    # real (if narrow) misattribution vector rather than leaving it latent.
    awk -v ln="$1" '
        BEGIN { bs = 1 }
        NF && $1 <= ln { bs = $1 }
        NF && $1 > ln && !be { be = $1 }
        END { if (!be) be = 2000000000; print bs "\t" be }
    ' <<<"$blocks_lines"
}

# watcher_tag_hit DUMPFILE LINENO - resolves the source IP (from the
# hit's enclosing packet's own header line) and destination Host header
# (if this packet's block has one), for exactly ONE match line. Called
# only for the handful of lines run_creds_watcher's grep passes actually
# flagged - never scans the whole dump itself, which is what makes this
# affordable even though the full-file grep passes that feed it are
# already the expensive part (see run_creds_watcher's own comment).
# Echoes "SRC<TAB>HOST".
watcher_tag_hit() {
    local dumpfile="$1" lineno="$2" bounds bs be src host
    bounds=$(watcher_block_bounds "$lineno")
    bs=$(cut -f1 <<<"$bounds"); be=$(cut -f2 <<<"$bounds")
    # BUG FOUND AND FIXED (verified with a standalone awk test): this used
    # an unconditional `sub(/\.[0-9]+$/, "", s)` to strip a trailing port
    # from the source address - the EXACT pattern summarize_pcap's own
    # "Top source IPs" section already found-and-fixed above (see its own
    # comment) because it wrongly treats a real ICMP address's last OCTET
    # as if it were a port and strips it too. That fix was never carried
    # over to this second, separate call site - confirmed live via a
    # standalone test: `172.16.52.1 > 172.16.52.254: ICMP echo request`
    # (no port at all, 4 dot-separated numbers) was reported here as
    # "172.16.52" (3 octets, wrong), the identical failure mode. Reachable
    # in practice, not just theoretically: an ICMP error packet (dest
    # unreachable/TTL exceeded) embeds a portion of the ORIGINAL packet
    # that triggered it, including its payload - so a [CREDS FOUND]/[HTTP]
    # live tag can legitimately resolve to an ICMP packet's own header
    # line. Same conditional fix as summarize_pcap's (only strip a
    # trailing number when what's left is a genuine 4-octet IPv4 address,
    # or a colon-containing IPv6 address with its own trailing port) -
    # verified against all three cases (ICMP, TCP+port, IPv6+port) with a
    # standalone awk test before applying here.
    src=$(sed -n "${bs}p" "$dumpfile" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == ">") {
                s = $(i - 1)
                if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) sub(/\.[0-9]+$/, "", s)
                else if (s ~ /:/ && s ~ /\.[0-9]+$/) sub(/\.[0-9]+$/, "", s)
                print s; exit
            }
        }
    }')
    [ -z "$src" ] && src="?"
    host=$(sed -n "${bs},$((be - 1))p" "$dumpfile" | grep -m1 -ioE '^host: .*' | sed 's/^[Hh]ost: *//; s/\r$//')
    [ -z "$host" ] && host="?"
    printf '%s\t%s' "$src" "$host"
}

# run_creds_watcher OUTPUT_FILE - INVENTED FEATURE: summarize_pcap only
# ever scanned for credentials/HTTP activity AFTER the whole capture
# finished - fine for a quick 30s capture, but for a long --background
# --duration run (or an unbounded one stopped hours later), real
# passwords or visited URLs sitting unseen in the .pcap for the entire
# remaining capture is an avoidable gap, and it's the opposite of the
# "watch it happen live, Wireshark-style" experience this was built for.
# This periodically (every 5s) re-scans the growing capture file and
# prints any NEW credential hit (red) or HTTP request/Host line the
# moment it's seen, tagged with source IP and destination host - live,
# into whatever the capture's own live output is (the terminal in the
# foreground case, /tmp/pager-sniff.log in the --background case, which
# is also what the LAN Sniffer payload's on-device live scroller already
# tails). Tracks each pattern's own seen-count separately so neither
# re-alerts the same match every cycle.
#
# HISTORY: a first version here grepped raw HTTP/creds lines with no
# source or destination context - reported live, twice, as not the
# "IP -> URL, like bettercap/Wireshark" view actually wanted. A second
# version tried to fix that with a single awk pass doing a per-line
# DYNAMIC regex match (`$0 ~ credspat`) plus block-tracking - measured
# live against a real 18.8k-line dump on this device, that awk pass timed
# out past 60s (vs. the plain `grep -iE "$CREDS_PATTERN"` below's already-
# slow ~14-22s) - 4x+ slower for identical work, apparently because
# busybox awk's dynamic (`-v`-supplied) regex matching is far more
# expensive per line than grep's compiled-once engine. It never produced
# a single live tag for a real capture with a real plaintext HTTP request
# in it. THIS version keeps the two full-file scans on grep (the fast
# part, unavoidable expense) and only spends extra work - the
# watcher_tag_hit() lookups above - on the small number of lines those
# scans actually flag, never on the whole dump. Verified live: correctly
# tagged a real HTTP request with its real source IPv6 address and
# "example.com" as the host, and a synthetic credential hit with its
# source IP, host, and the matched text. Honest limits, unchanged from
# either prior version or newly noticed while verifying this one:
#   - The CREDS_PATTERN grep pass alone still takes ~15-25s against a
#     genuinely busy capture on this hardware, so this still isn't truly
#     sub-5s "live" for a busy capture - it just reliably produces
#     correct output eventually instead of none at all.
#   - tcpdump -A decorates a packet it recognizes as HTTP with its OWN
#     one-line protocol summary appended to that packet's header line,
#     IN ADDITION TO the raw ASCII payload dump it always shows anyway -
#     confirmed live: a real "GET /get?user=X&pass=Y" request got tagged
#     TWICE (once from the decorated header line, once from the raw
#     payload line matching the same text) - same real event, reported
#     as two [CREDS FOUND] rows instead of one. Pre-existing in every
#     version of this function (none of them were block-aware about
#     which packet a match belongs to for dedup purposes, only this one
#     even tracks blocks at all) - cosmetic (no wrong data, just a
#     redundant repeat), not chased further here.
# MAX_LIVE_WATCH_BYTES - CRITICAL BUG FOUND AND FIXED (live-caught: a
# real, extended, busy capture crashed the device entirely, plus --stop/
# pause had a long, unexplained delay before taking effect). Both
# run_creds_watcher and run_packet_feed re-scan the ENTIRE growing
# capture file from byte 0 every cycle, with no upper bound - for a
# capture that runs for a while against genuinely busy traffic (the
# reporter's case: several browser tabs, YouTube, multiple sites), the
# file can grow into the multiple-MB range, and EVERY cycle re-decodes
# the WHOLE thing again (tcpdump -A's ASCII conversion is typically
# several times LARGER than the binary pcap it's decoding). run_creds_
# watcher additionally writes that whole decoded dump out to a /tmp file
# every cycle - /tmp on OpenWRT devices like this one is conventionally
# tmpfs (RAM-backed), so that's a SECOND full copy of an ever-growing
# blob competing for the same 251MB total RAM budget as the live
# tcpdump capture process itself, run_packet_feed's own simultaneous
# re-decode, and everything else running. Capping how much of the
# capture this machinery will ever re-scan bounds BOTH the growing
# CPU cost (already documented) AND this growing memory cost, and
# indirectly fixes the slow-stop/slow-pause reports too: kill/SIGTERM
# sent to a subshell blocked inside a single `tcpdump -A -r` call on an
# unbounded, ever-larger file isn't actionable until that call returns
# (bash defers signal handling for a blocked foreground command) - a
# capture that grew large enough could make a single cycle take a very
# long time, directly explaining "stop doesn't take effect immediately,
# but does eventually." 4MB is comfortably past what a single cycle can
# process in a reasonable time on this hardware (this session's own
# measurements: a much smaller ~3.5MB/18.8k-line dump already took
# 15-25s per grep pass) while still covering the vast majority of real
# LAN Sniffer sessions, which are typically short diagnostic captures,
# not hours-long monitoring. Once a capture crosses this size, the live
# watchers cleanly stop themselves (with one explanatory log line) and
# hand off entirely to the end-of-capture `--summary`, which still scans
# the complete file exactly once, not repeatedly.
MAX_LIVE_WATCH_BYTES=4194304

# CREDS_WATCH_INTERVAL_SECS - how often (5s) run_creds_watcher wakes up to
# check whether the capture file has grown and, if so, re-scan it. Pulled
# up from an inline `sleep 5` literal to a named constant alongside
# MAX_LIVE_WATCH_BYTES (same subsystem), same value, no behavior change.
CREDS_WATCH_INTERVAL_SECS=5

# CREDS_WATCH_RESCAN_TIMEOUT_SECS - bound (15s) on each of run_creds_
# watcher's three per-cycle subprocess calls (the `tcpdump -A -r` re-decode
# and the two CREDS_PATTERN/HTTP_PATTERN grep passes) - see this function's
# own HISTORY comment below for the measured 15-25s real-world cost this is
# sized against. Pulled up from three separate inline `timeout 15` literals
# to one named constant, same value, no behavior change.
CREDS_WATCH_RESCAN_TIMEOUT_SECS=15

# PACKET_FEED_INTERVAL_SECS - how often (2s, faster than the credential
# watcher's 5s - this is the "watch it happen" feed, not the "don't miss a
# password" one) run_packet_feed wakes up to check for new packets. Pulled
# up from an inline `sleep 2` literal to a named constant, same value, no
# behavior change.
PACKET_FEED_INTERVAL_SECS=2

# PACKET_FEED_RESCAN_TIMEOUT_SECS - bound (10s) on run_packet_feed's own
# per-cycle `tcpdump -nn -r` re-decode - shorter than CREDS_WATCH_RESCAN_
# TIMEOUT_SECS's 15s to match this loop's own tighter 2s cadence. Pulled up
# from an inline `timeout 10` literal to a named constant, same value, no
# behavior change.
PACKET_FEED_RESCAN_TIMEOUT_SECS=10

run_creds_watcher() {
    local file="$1" last_creds=0 last_http=0 last_size=-1
    # is_running (PIDFILE-based) covers --background; for a foreground
    # run there's no PIDFILE, so fall back to "is the sniff.sh process
    # that launched me ($PPID, since this runs as its backgrounded child)
    # still alive" - true for the whole foreground capture, since that
    # process blocks on run_capture() until it finishes.
    while is_running || kill -0 "$PPID" 2>/dev/null; do
        sleep "$CREDS_WATCH_INTERVAL_SECS"
        [ -s "$file" ] || continue
        # PERFORMANCE FIX: this used to spawn `tcpdump -A -r` (a full
        # parse-and-reformat of the ENTIRE capture so far) unconditionally
        # every single 5s tick, even during a completely quiet window with
        # zero new packets since the last check - real CPU/subprocess cost
        # for nothing new to report, on a device that's already memory/
        # CPU-constrained. A file-size check first is nearly free (no
        # subprocess spawn, no packet parsing - just the byte count) and
        # skips the expensive tcpdump call entirely whenever the capture
        # hasn't grown since the last cycle.
        local cur_size
        cur_size=$(wc -c < "$file" 2>/dev/null)
        [ "$cur_size" = "$last_size" ] && continue
        last_size="$cur_size"

        if [ "$cur_size" -gt "$MAX_LIVE_WATCH_BYTES" ] 2>/dev/null; then
            echo "[sniff.sh] Live HTTP/creds tagging stopped - capture has grown past $((MAX_LIVE_WATCH_BYTES / 1024 / 1024))MB, re-scanning it every cycle would cost too much CPU/RAM on this device. The full capture is still being saved; run 'sniff.sh --summary' on it (or wait for the automatic one) for the complete picture."
            return 0
        fi

        # BUG FOUND AND FIXED (check-then-act race, verified against this
        # session's own measured capture rate): the size cap just above is
        # only checked at a single instant (cur_size at time of `wc -c`),
        # but `tcpdump -r FILE` opens the REAL, still-growing capture file
        # directly and reads via plain read() calls that see whatever bytes
        # are on disk at each call - it does not snapshot the file at open
        # time, so it keeps picking up newly-appended packets for as long
        # as it keeps reading, up to its own 15s timeout. At this session's
        # own measured busy-capture rate (~10.5MB/20s = ~0.52MB/s), a single
        # cycle that starts its 15s-bounded read right after a passing
        # cur_size check could still absorb up to ~7.9MB of NEW growth
        # DURING that same read - on top of the up-to-4MB already checked -
        # before the NEXT cycle's check ever catches it. Not the original
        # "unbounded, crashes the device" failure (still hard-capped by the
        # 15s timeout either way), but a real, measurable gap between the
        # cap's intent ("never process much more than 4MB per cycle") and
        # what could actually happen in the one cycle that crosses the
        # line. Snapshotting exactly `cur_size` bytes (the amount already
        # confirmed safe) into a static temp file BEFORE handing it to
        # tcpdump closes this: tcpdump then reads a file that cannot grow
        # further underneath it, no matter how long its own decode takes.
        # Deliberately a plain temp file (not a `head -c | tcpdump -r -`
        # pipeline) - a multi-process pipeline here would reintroduce the
        # exact orphaned-child risk this file has already found and fixed
        # twice elsewhere (see run_packet_feed's own header comment).
        local snapf="/tmp/pager-sniff-watcher-snap.$$" read_target
        head -c "$cur_size" "$file" > "$snapf" 2>/dev/null
        # Defensive fallback: if `head -c` didn't produce real bytes (e.g.
        # unsupported on this device's head build), fall back to reading
        # $file directly rather than silently scanning nothing every cycle
        # - re-exposes the race this fix closes, but only as a fallback,
        # never as a silent no-op.
        if [ -s "$snapf" ]; then read_target="$snapf"; else read_target="$file"; fi
        local dumpf="/tmp/pager-sniff-watcher-dump.$$"
        timeout "$CREDS_WATCH_RESCAN_TIMEOUT_SECS" tcpdump -A -r "$read_target" 2>/dev/null > "$dumpf"
        rm -f "$snapf"
        # BUG FOUND AND FIXED (caught reviewing this same session's own
        # timeout-wrapping fix, before it ever shipped): wrapping a command
        # in `timeout` bounds the worst-case DELAY, but a command that
        # actually GETS killed at the deadline produces a silently PARTIAL
        # result, not an error - `[ -s "$dumpf" ]` alone can't tell "a
        # complete, quick dump" apart from "a truncated dump that just
        # happened to have SOME bytes before being killed". Piping the
        # timeout'd command straight into `| cut | sort` (as first written)
        # makes this worse: without `pipefail`, the pipeline's own exit
        # status comes from the LAST command (`sort`), which succeeds
        # regardless of whether the FIRST command got killed - so nothing
        # downstream would ever know a scan was incomplete. For a
        # credential/HTTP watcher, silently under-reporting real hits is a
        # worse failure than being slow. Capturing `timeout`'s own exit
        # code (124 specifically means "killed by the deadline") right
        # after each call, before any further piping, and saying so
        # plainly when it happens.
        local tcpdump_rc=$?
        # BUG FOUND AND FIXED (MINOR, gap in the fix directly above - the
        # `[ -s "$dumpf" ] &&` on the notice meant a cycle that got killed
        # at the 15s deadline SO early that tcpdump/its OS-buffered stdout
        # had not flushed a single byte yet (tcpdump's stdout is fully
        # block-buffered here - no -l on this internal re-scan invocation,
        # unlike the main capture's own TD_ARGS - so a kill before its
        # buffer fills or it exits can lose everything it had already
        # decoded) fell straight through to the `elif [ ! -s "$dumpf" ]`
        # branch and got silently discarded with NO cutoff notice at all -
        # the exact "silently under-reporting is worse than being slow"
        # failure the fix above says it's trying to avoid, just for the
        # specific case of a cutoff that happened to produce zero bytes
        # instead of some. Checking tcpdump_rc==124 on its own, unconditional
        # on whether dumpf ended up with any content, prints the notice
        # every time a cutoff genuinely happened - then the emptiness check
        # right after decides only whether there's anything left to scan
        # this cycle, independently.
        if [ "$tcpdump_rc" -eq 124 ]; then
            echo "[sniff.sh] NOTE: this cycle's re-scan was cut off after ${CREDS_WATCH_RESCAN_TIMEOUT_SECS}s (busy capture) - results below may be incomplete for this cycle; a full, complete pass still happens at the end via --summary."
        fi
        if [ ! -s "$dumpf" ]; then
            rm -f "$dumpf"
            continue
        fi

        # BUG FOUND AND FIXED (live-caught while verifying this version):
        # busybox grep, for a single line that matches MULTIPLE
        # alternatives in a complex `-E` pattern (CREDS_PATTERN has many,
        # joined by `|`), can report that SAME line more than once -
        # confirmed live against a synthetic "user=admin&pass=hunter2"
        # line (matches both the user= and pass= alternatives) printing
        # twice with plain `grep -c .`-style counting. `sort -un` collapses
        # that back to one entry per real line before counting/tagging -
        # this bug already existed in this function's very first version
        # too (same counting idiom), just never caught until this rewrite
        # was verified line-by-line against real data.
        #
        # Each grep is also now `timeout`-bounded: measured live at 15-25s
        # for a real ~18.8k-line dump, so an unusually dense capture (still
        # under the MAX_LIVE_WATCH_BYTES cap above, but denser than that
        # measurement) could still run long - bounding it directly caps the
        # worst-case delay before this subshell can next notice a --stop.
        # Same silent-truncation risk as the tcpdump call above applies
        # here too - the raw grep call's own exit code is captured BEFORE
        # piping into cut/sort, not read off the end of that pipeline.
        local creds_raw http_raw creds_rc http_rc
        local creds_lines http_lines creds_count http_count
        creds_raw=$(timeout "$CREDS_WATCH_RESCAN_TIMEOUT_SECS" grep -noiE "$CREDS_PATTERN" "$dumpf"); creds_rc=$?
        [ "$creds_rc" -eq 124 ] && echo "[sniff.sh] NOTE: this cycle's credential scan was cut off after ${CREDS_WATCH_RESCAN_TIMEOUT_SECS}s (busy capture) - may be incomplete for this cycle."
        http_raw=$(timeout "$CREDS_WATCH_RESCAN_TIMEOUT_SECS" grep -noiE "$HTTP_PATTERN" "$dumpf"); http_rc=$?
        [ "$http_rc" -eq 124 ] && echo "[sniff.sh] NOTE: this cycle's HTTP scan was cut off after ${CREDS_WATCH_RESCAN_TIMEOUT_SECS}s (busy capture) - may be incomplete for this cycle."
        # PERFORMANCE FIX (measured, not guessed - see standalone repro this
        # pass: 150 iterations of `echo "$var" | grep -c .` took ~12.0s vs
        # ~8.9s for 150 iterations of `grep -c . <<<"$var"` against
        # identical input - roughly one fewer fork's worth of time per
        # call). Every one of these four lines used to pipe a plain
        # variable through `echo` before handing it to the real external
        # command (cut/sort/grep) - in bash, EVERY stage of a pipeline
        # (including a bare `echo`) runs in its own forked subshell, so
        # each `echo "$var" | cmd` was always one avoidable fork more than
        # `cmd <<<"$var"` (a bash here-string, which feeds the exact same
        # bytes - var's content plus one trailing newline, identical to
        # what `echo` would have written - directly as the command's stdin
        # with no extra process). These four lines run on every active
        # run_creds_watcher cycle that finds new capture data (every 5s
        # during real traffic), so this removes ~4 forks per active cycle
        # for the lifetime of the watcher with no output change.
        creds_lines=$(cut -d: -f1 <<<"$creds_raw" | sort -un)
        http_lines=$(cut -d: -f1 <<<"$http_raw" | sort -un)
        creds_count=$(grep -c . <<<"$creds_lines")
        http_count=$(grep -c . <<<"$http_lines")

        if [ "$creds_count" -gt "$last_creds" ] || [ "$http_count" -gt "$last_http" ]; then
            # Only computed when there's actually something new to tag -
            # this is the one remaining full-file-ish pass (a plain
            # anchored line-number listing, not a content match), shared
            # by both branches below via watcher_block_bounds().
            local blocks_lines
            blocks_lines=$(grep -noE '^[0-9]+:[0-9]+:[0-9]+\.' "$dumpf" | cut -d: -f1)

            if [ "$creds_count" -gt "$last_creds" ]; then
                echo "$creds_lines" | tail -n "+$((last_creds + 1))" | while IFS= read -r lineno; do
                    [ -z "$lineno" ] && continue
                    local ctx src host content
                    ctx=$(watcher_tag_hit "$dumpf" "$lineno")
                    src=$(cut -f1 <<<"$ctx"); host=$(cut -f2 <<<"$ctx")
                    content=$(sed -n "${lineno}p" "$dumpf")
                    printf '[CREDS FOUND] %s -> %s  ' "$src" "$host"
                    echo "$content" | GREP_COLORS='mt=1;31' grep --color=always -iE "$CREDS_PATTERN"
                done
                last_creds="$creds_count"
            fi

            if [ "$http_count" -gt "$last_http" ]; then
                echo "$http_lines" | tail -n "+$((last_http + 1))" | while IFS= read -r lineno; do
                    [ -z "$lineno" ] && continue
                    local ctx src host content
                    ctx=$(watcher_tag_hit "$dumpf" "$lineno")
                    src=$(cut -f1 <<<"$ctx"); host=$(cut -f2 <<<"$ctx")
                    content=$(sed -n "${lineno}p" "$dumpf")
                    echo "[HTTP] $src -> $host  $content"
                done
                last_http="$http_count"
            fi
        fi
        rm -f "$dumpf"
    done
}

# run_packet_feed OUTPUT_FILE - BUG FOUND AND FIXED (reported live -
# "the packets should spam and show like Wireshark... they dont do that
# rn and only say what has been captured"): the LIVE=1-by-default fix
# earlier this session made tcpdump line-buffer its stdout (-l), which
# was a real but INCOMPLETE fix - confirmed live (a real capture with
# genuine traffic: 67 packets captured, per the pcap's own count) that
# tcpdump prints NOTHING per-packet to stdout at all whenever -w (saving
# to a file) is given, regardless of -l - that's documented tcpdump
# behavior, not a buffering issue. Getting BOTH a saved file AND a live
# per-packet feed normally means a `tcpdump -w - | tee file | tcpdump -r
# -` pipeline - deliberately NOT done that way here: a 3-process pipeline
# introduces exactly the same orphaned-child risk already found and fixed
# twice this session (killing one PID doesn't reliably kill the others).
# Reusing the ALREADY-proven periodic-rescan pattern (same as
# run_creds_watcher above) instead - a separate, more frequent (2s, vs
# the credential watcher's 5s - this is the "watch it happen" feed, the
# other is "don't miss a password", different urgency) re-read of the
# growing file using the same plain per-packet format --summary/
# summarize_pcap already use, printing only genuinely NEW lines each
# cycle. Same single, well-understood mechanism, no new process-lifetime
# risk - just a second cadence of the same trick.
run_packet_feed() {
    local file="$1" last_count=0 last_size=-1
    while is_running || kill -0 "$PPID" 2>/dev/null; do
        sleep "$PACKET_FEED_INTERVAL_SECS"
        [ -s "$file" ] || continue
        # PERFORMANCE FIX (same reasoning as run_creds_watcher's own fix):
        # skip the actual tcpdump spawn/full re-parse when the file hasn't
        # grown since the last check - at a 2s cadence (this loop's own,
        # faster than the creds watcher's 5s) this matters even more, since
        # any quiet moment in the traffic was previously still costing a
        # full re-parse every 2 seconds for nothing new.
        local cur_size
        cur_size=$(wc -c < "$file" 2>/dev/null)
        [ "$cur_size" = "$last_size" ] && continue
        last_size="$cur_size"

        # BUG FOUND AND FIXED (live-caught - a real, extended, busy
        # capture crashed the device): same unbounded-re-scan risk as
        # run_creds_watcher's own MAX_LIVE_WATCH_BYTES fix, and this loop
        # runs at 2s cadence - even faster, even more re-scanning of an
        # ever-larger file. Same cap, same reasoning.
        if [ "$cur_size" -gt "$MAX_LIVE_WATCH_BYTES" ] 2>/dev/null; then
            echo "[sniff.sh] Live packet feed stopped - capture has grown past $((MAX_LIVE_WATCH_BYTES / 1024 / 1024))MB, re-scanning it every ${PACKET_FEED_INTERVAL_SECS}s would cost too much CPU/RAM on this device. The full capture is still being saved."
            return 0
        fi

        # BUG FOUND AND FIXED (same check-then-act race as run_creds_
        # watcher's own fix above, applied here too - this loop's 2s
        # cadence and 10s timeout give an even tighter but still real
        # window: up to ~5.2MB of new growth at this session's measured
        # ~0.52MB/s rate could be picked up mid-read on top of the checked
        # cur_size, since `tcpdump -r` reads the live file directly rather
        # than a point-in-time snapshot). Same fix: bound what tcpdump can
        # ever see to exactly the size already confirmed safe.
        local snapf="/tmp/pager-sniff-feed-snap.$$" read_target
        head -c "$cur_size" "$file" > "$snapf" 2>/dev/null
        # Same defensive fallback as run_creds_watcher's own snapshot fix.
        if [ -s "$snapf" ]; then read_target="$snapf"; else read_target="$file"; fi
        local lines count new lines_rc
        lines=$(timeout "$PACKET_FEED_RESCAN_TIMEOUT_SECS" tcpdump -nn -r "$read_target" 2>/dev/null); lines_rc=$?
        rm -f "$snapf"
        # BUG FOUND AND FIXED (same class as run_creds_watcher's own fix,
        # applied here too): timeout's exit code is captured immediately
        # after the direct (non-piped) command substitution above, so 124
        # specifically means "cut off at 10s, this cycle's feed may be
        # incomplete" rather than silently treating a truncated decode as
        # a complete one.
        #
        # BUG FOUND AND FIXED (MINOR, same reordering gap as run_creds_
        # watcher's sibling fix): this notice used to be checked AFTER the
        # `[ -z "$lines" ] && continue` line above it - a cutoff so early
        # that tcpdump's own (block-buffered, no -l on this internal re-scan
        # invocation) stdout had flushed nothing yet meant `lines` was empty
        # and the `continue` fired first, skipping this notice entirely for
        # exactly the cutoffs most likely to actually lose data. Checking
        # lines_rc before the emptiness check (which now runs right after,
        # unconditionally) means the notice fires every time a cutoff really
        # happened, independent of how much (if anything) was salvaged.
        # CONSISTENCY FIX: this was the one cutoff/NOTE-style message in
        # sniff.sh's own live watchers with no "[sniff.sh]" tag - every
        # sibling cutoff notice (run_creds_watcher's own tcpdump/creds/HTTP
        # cutoff notices just above, and both MAX_LIVE_WATCH_BYTES stop
        # notices) carries it. Tagged to match, so a viewer scrolling the
        # combined /tmp/pager-sniff.log (which interleaves sniff.sh's own
        # lines with the LAN Sniffer payload's and, during a bridge run,
        # usb_monitor.sh's) can tell this came from sniff.sh like every
        # other machine-generated notice line does.
        [ "$lines_rc" -eq 124 ] && echo "[sniff.sh] -- (this cycle's feed was cut off after ${PACKET_FEED_RESCAN_TIMEOUT_SECS}s, busy capture) --"
        [ -z "$lines" ] && continue
        # PERFORMANCE FIX: same `echo "$var" | cmd` -> `cmd <<<"$var"` fork
        # removal as run_creds_watcher's own fix above (see its comment for
        # the measured repro) - this loop's 2s cadence (vs the creds
        # watcher's 5s) makes it matter even more: these two lines run on
        # every active cycle with new packet data, i.e. up to twice as
        # often for the same busy-capture session.
        count=$(grep -c . <<<"$lines")
        if [ "$count" -gt "$last_count" ]; then
            new=$(tail -n "+$((last_count + 1))" <<<"$lines")
            echo "$new"
            last_count="$count"
        fi
    done
}

# BUG FOUND AND FIXED (live-diagnosed via a real device report - "not
# spamming with IPs" AND "not asking to save the log" on the SAME LAN
# Sniffer bridge run both traced back to this one call site): this only
# ever checked `-n "$DO_SUMMARY_ONLY"` (is the VALUE non-empty), which is
# indistinguishable from "--summary was never passed at all" - if the
# CALLER passed `--summary ""` (an empty string, not omitting the flag
# entirely), this whole block was silently skipped and execution fell
# through into the NORMAL capture flow further down (interactive mode,
# since IFACE/DO_LIST/etc are all unset) - completely unrelated to "just
# print a summary and exit". Confirmed this is exactly what happened: the
# lan_sniffer payload's own CAPTURE_FILE is derived by grepping sniff.sh's
# own launch output for a .pcap path - if that earlier --background launch
# never actually produced one (see run_live_capture()'s own missing
# liveness check, fixed in the payload), CAPTURE_FILE ends up "", and
# `sniff.sh --summary ""` silently became an unplanned interactive-mode
# invocation with no real TTY behind it, in a plain (non-timeout-wrapped)
# command substitution in the payload - explaining the missing save-log
# prompt too (the payload never got past this stuck/misdirected call to
# reach it). Track whether --summary was actually GIVEN separately from
# its value, so a blank value now fails loudly and immediately instead of
# silently misrouting into a different code path entirely.
if [ "$SUMMARY_FLAG_GIVEN" = "1" ]; then
    [ -z "$DO_SUMMARY_ONLY" ] && die "--summary needs a .pcap file path (got an empty value - the capture this came from may not have actually started; check its own log)."
    summarize_pcap "$DO_SUMMARY_ONLY"
    exit 0
fi

if [ "$DO_LIST" = "1" ]; then
    say "Candidate wired interfaces:"
    list_wired_ifaces
    if ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        echo "  ($BRIDGE_NAME bridge is currently up)"
    fi
    exit 0
fi

if [ "$DO_ADAPTERS" = "1" ]; then
    check_adapters
    exit 0
fi

# BIG CHANGE (adopting common.sh's shared primitive): backed by the one
# canonical pid_running() in lib/common.sh instead of another independent
# copy of the same "PIDFILE + kill -0" check.
#
# BUG FOUND AND FIXED (CRITICAL, self-introduced regression, live-caught):
# this used "sniff.sh" as pid_running()'s NAME_PATTERN, copying the
# pattern used for bluetooth.sh/crash_logger.sh/deauth.sh/tracer.sh/
# usb_monitor.sh - but unlike ALL of those, sniff.sh's own run_capture_bg()
# is a SPECIAL case (documented in its own header above): it `exec`s
# straight into tcpdump/timeout, replacing the subshell's process image,
# the exact same situation webui.sh's is_running() already correctly
# handles by matching "server.py" instead of "webui.sh". Missing that same
# reasoning here meant the real backgrounded process's /proc/PID/cmdline
# NEVER contained "sniff.sh" at all (it shows "tcpdump ..." or
# "timeout N tcpdump ..."), so is_running() always returned false for a
# capture that was actually running fine - confirmed live: a real
# --background capture wrote a genuine, real, non-empty .pcap file to
# /root/loot/sniff/ while sniff.sh itself reported "Capture exited
# immediately" and `--status` said "Not running" the whole time. This
# broke EVERY background capture's liveness reporting (and by extension,
# every payload/GUI action built on top of it) since that fix went out
# earlier today. "tcpdump" is the correct pattern - present in the real
# cmdline whether or not `timeout` wraps it.
is_running() { pid_running "$PIDFILE" "tcpdump"; }

# kill_tracked_pid PIDFILE PATTERN - shared "guard against PID reuse, then
# kill and forget" primitive for every place this script tracks a
# background subshell/process it may need to stop later: the --stop
# watcher/feed cleanup below, and all three WATCHDOG_PIDFILE kill sites
# (start_lan_watchdog's own "kill any pre-existing watchdog first" guard,
# stop_lan_watchdog, and --unbridge). This was five independent copies of
# the identical `[ -f pidfile ] && pid_running pidfile pattern && kill ...;
# rm -f pidfile` sequence before this cleanup pass - each one added
# separately, tonight, as the same PID-reuse gap kept getting rediscovered
# at a new call site (see pid_running()'s own header in lib/common.sh for
# why a bare `kill "$(cat pidfile)"` isn't safe on its own: the PID may
# have been reused by an unrelated process since the file was written).
# One definition now instead of five that could each drift independently.
# Always removes the pidfile after, whether or not a live matching process
# was actually found - same "stale/missing pidfile is a harmless no-op"
# behavior every original call site already had via its own `[ -f ... ]`
# guard (pid_running() itself also checks `-f`, so this is belt-and-braces
# with what it already does, matching the original code's own redundancy
# exactly rather than trimming it away as part of this refactor).
kill_tracked_pid() {
    local pidfile="$1" pattern="$2"
    if [ -f "$pidfile" ]; then
        pid_running "$pidfile" "$pattern" && kill "$(cat "$pidfile")" 2>/dev/null
        rm -f "$pidfile"
    fi
}

# reap_orphaned_tcpdump_rescans - kills any leftover `tcpdump ... -r ...`
# process (the periodic re-scan run_creds_watcher/run_packet_feed each
# spawn every cycle) left orphaned when its own watcher subshell got
# killed mid-flight - the default (no trap set) behavior is the parent
# dies immediately and the child keeps running as an orphan, the same
# root cause as this toolkit's very first orphan-process bug this
# session. Shared by both places this script kills those watcher
# subshells (--stop below, and the foreground path right after
# run_capture returns further down) - previously two identical copies of
# this same loop, one per call site. Deliberately NOT a blanket `killall
# tcpdump` - tracer.sh/pc_link.sh/a manual capture could have a live
# `tcpdump -i ...` running at the same time and this must not touch
# those. Matches specifically on "tcpdump ... -r" (a saved-file re-read -
# never how any LIVE capture in this toolkit invokes tcpdump, which
# always uses `-i IFACE -w FILE`), covering both the "-A -r" (creds/HTTP
# watcher) and "-nn -r" (packet feed) forms.
reap_orphaned_tcpdump_rescans() {
    for _pid in $(ps 2>/dev/null | grep -E 'tcpdump .* -r ' | grep -v grep | awk '{print $1}'); do
        kill "$_pid" 2>/dev/null
    done
}

# LOCKDIR/acquire_lock/release_lock - BUG FOUND AND FIXED (CRITICAL - the
# same TOCTOU race usb_monitor.sh's own --background/--stop/--status was
# just found to have and fixed with a lock earlier tonight; traced through
# THIS file's own code rather than assumed by analogy, and confirmed with a
# standalone repro before writing this fix). The old --background path
# checked `is_running` exactly ONCE (immediately after argument parsing),
# then didn't touch $PIDFILE again until forking tcpdump and writing it much
# further down - past the interface-existence check/retry, `mkdir -p
# "$LOOT_DIR"`, and the output-path/TD_ARGS setup, all of which run
# regardless of whether this is a race. Two concurrent `sniff.sh
# --background` invocations (e.g. a payload/script launching it twice in
# quick succession, or two separate SSH sessions - the same realistic
# trigger usb_monitor.sh's own fix names) can both pass that early
# is_running check while $PIDFILE is still empty/stale, both proceed to
# fork their own tcpdump, and both then `echo $! > "$PIDFILE"` - the SECOND
# write silently clobbers the first. The first tcpdump keeps running for
# real (a real .pcap growing on disk, real CPU/RAM held on this 251MB
# device) but is now completely untracked: invisible to --status,
# unreachable by --stop, never cleaned up short of a reboot or someone
# finding the orphan by hand with `ps`. Verified this exact shape (early
# check, unrelated setup work, THEN fork+unconditional-write, no lock) with
# a standalone repro before writing this fix - not tcpdump itself (no
# device access from this pass), but real background processes standing in
# for it, started/tracked through the identical is_running/$PIDFILE-write
# sequence: 8 concurrent racers against the OLD shape left 6 of the 7 that
# actually started still alive and running, but UNTRACKED ($PIDFILE only
# ever named the last writer) - re-running the same 8 racers against the
# lock below produced exactly 1 starter and 0 orphans, every time.
#
# Fixed by reusing usb_monitor.sh's own mkdir-based lock (mkdir is atomic
# per POSIX, and unlike `flock` needs nothing extra installed - not
# guaranteed present on this device's busybox build) - only the LOCKDIR
# path differs. Serializes --background/--stop/--status against each other
# the same way, which also closes the two smaller variants kill_tracked_
# pid's own header already named as real (see its comment below): --stop
# re-reading $PIDFILE a second time (once inside is_running's own check,
# again for the `kill` itself) let a --background racing in between act on
# a stale read; --status had the identical second-read gap for its printed
# PID. The AUTHORITATIVE is_running check/fork/write for --background now
# happens together, lock-held, right at the fork site further down (see its
# own comment there) - not here; a script that hasn't even validated its
# interface yet has no shared state worth locking over.
#
# Stale-lock recovery: the lock is only ever held for the few fast, local,
# non-blocking checks in these three blocks (plus, for --background, one
# unavoidable process fork+PID-write) - never across the long-running
# capture/watcher loops themselves - so the only way it outlives its holder
# is that holder getting SIGKILLed inside this narrow window. A waiter that
# finds the lock held checks whether the PID that created it ($LOCKDIR/pid)
# is still alive (same "does the recorded PID still actually belong to
# something" check as pid_running() above) and clears the lock itself if
# not, so a rare dead holder can't wedge every future --background/--stop/
# --status behind a lock nobody will ever release. `rmdir` fails on a
# non-empty directory, so the pid marker file is removed before the rmdir,
# same ordering usb_monitor.sh's own version already verified is required.
LOCKDIR="/tmp/pager-sniff.lock"
acquire_lock() {
    local tries=0 holder
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -ge 50 ] && die "Timed out waiting for another sniff.sh --background/--stop/--status to finish (lock: $LOCKDIR)."
        holder=$(cat "$LOCKDIR/pid" 2>/dev/null)
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$LOCKDIR/pid" 2>/dev/null
            rmdir "$LOCKDIR" 2>/dev/null
            continue
        fi
        sleep 0.1
    done
    echo $$ > "$LOCKDIR/pid" 2>/dev/null
}
release_lock() { rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null; }

if [ "$DO_STATUS" = "1" ]; then
    acquire_lock
    trap release_lock EXIT
    if is_running; then
        say "Capture running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    acquire_lock
    trap release_lock EXIT
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
        say "Stopped."
    else
        say "Nothing running."
    fi
    # BUG FOUND AND FIXED (live-caught, confirmed via a real `ps` before/
    # after --stop): run_creds_watcher's --background invocation was
    # launched with NO PID captured at all, relying entirely on its own
    # loop condition (`is_running || kill -0 "$PPID"`) to notice the
    # capture stopped and exit itself. Confirmed live that this doesn't
    # reliably happen - the watcher (and the `tcpdump -A -r` re-scan it
    # spawns each cycle) was still running, still re-reading the capture
    # file, MINUTES after --stop had already reported "Stopped." Same
    # root lesson as this toolkit's other orphan-process fixes: track the
    # real PID and kill it directly, don't trust a self-check condition
    # to reliably notice from the inside. See the matching PID capture in
    # the --background launch block below.
    #
    # Same PID-reuse-guarded kill as WATCHDOG_PIDFILE below (see
    # kill_tracked_pid()'s own header) - these two track run_creds_watcher/
    # run_packet_feed's own subshell PIDs, the same kind of non-exec'd bash
    # subshell of this script, so they need the same "sniff.sh" pattern.
    kill_tracked_pid "${PIDFILE}.watcher" "sniff.sh"
    kill_tracked_pid "${PIDFILE}.feed" "sniff.sh"
    # Defense-in-depth - see reap_orphaned_tcpdump_rescans()'s own header
    # (up near is_running()/kill_tracked_pid()) for why this is needed:
    # both watchers' periodic `tcpdump -r FILE` re-scans can be orphaned
    # by the kills just above.
    reap_orphaned_tcpdump_rescans
    exit 0
fi

# WATCHDOG_PIDFILE - INVENTED FEATURE (asked for directly): "if something
# disconnects (like lan) reset the settings to normal again (only LAN
# settings) so ssh works again" - instead of needing devreset run by hand
# every time a bridge test goes wrong, --bridge now starts a lightweight
# background watchdog for as long as the bridge is up: every 5s, check
# whether eth0 is still actually a member of br-lan (the thing that
# breaks SSH-over-USB-C when it goes wrong - see reset.sh's own header
# for the real incident this is protecting against) and immediately
# re-attach it if not. Deliberately just the fast, targeted fix (not a
# full network reload - reset.sh --network is still there for a harder
# case) so it can run every few seconds with near-zero cost. Started on
# --bridge, stopped on --unbridge.
WATCHDOG_PIDFILE="/tmp/pager-sniff-watchdog.pid"
BRIDGE_STARTED_FILE="/tmp/pager-sniff-bridge-started"

# BIG CHANGE (real feature, asked for directly - "keep the sniffing while
# keeping ssh... over the LAN"): --bridge's whole premise up to now was
# "the Pager becomes an invisible tap - it has no address of its own on
# either side, it just forwards" - which is EXACTLY what makes SSH-over-
# USB-C stop working the moment eth0 joins the bridge (eth0 was br-lan's
# only physical port; once it's gone, br-lan's own 172.16.52.1 has nothing
# to ride on). --dhcp (used alongside --bridge) changes that: it requests
# a REAL DHCP lease directly on the bridge device itself, from the SAME
# upstream network the bridge is now tapping - the same way any other
# device physically plugged into that network would get one. The Pager
# becomes a genuine, addressable member of that LAN for as long as the
# bridge is up, reachable by SSH at whatever address the router hands it
# (from the tethered PC, or anywhere else on that network) - not just the
# isolated 172.16.52.0/24 management subnet. Uses busybox's own stock
# /usr/share/udhcpc/default.script (confirmed present on this device) -
# a plain `ip addr add`/`route add` script with NO netifd dependency,
# deliberately NOT the netifd-managed dhcp.script eth1's own DHCP client
# uses (that script assumes netifd is tracking the interface, which it
# isn't for this ad-hoc bridge device). Bounded (a fixed discover-attempt
# budget, `-n` = exit rather than hang if no lease comes back) so a dead-
# end network can't turn this into an indefinite hang - the bridge/tap
# itself is still fully functional either way, this is a genuine bonus on
# top, not a dependency the core feature needs to work.
BRIDGE_DHCP_PIDFILE="/tmp/pager-sniff-bridge-dhcp.pid"

# BRIDGE_DHCP_TIMEOUT_SECS / BRIDGE_DHCP_DISCOVER_TRIES /
# BRIDGE_DHCP_RETRY_INTERVAL_SECS - start_bridge_dhcp's own overall time
# budget (`timeout`), discover-attempt count (udhcpc -t), and seconds
# between attempts (udhcpc -T) for requesting a lease on the bridge device.
# Bounded deliberately (see start_bridge_dhcp's caller-side comment on
# BRIDGE_DHCP_PIDFILE above) so a dead-end network can't turn this into an
# indefinite hang - the bridge/tap itself is already fully functional
# either way, this is a bonus on top. Pulled up from inline `timeout 20`/
# `-t 5`/`-T 3` literals to named constants, same values, no behavior
# change.
BRIDGE_DHCP_TIMEOUT_SECS=20
BRIDGE_DHCP_DISCOVER_TRIES=5
BRIDGE_DHCP_RETRY_INTERVAL_SECS=3

# DHCP_KILL_GRACE_SECS - stop_bridge_dhcp's own pause between asking udhcpc
# to release its lease gracefully (SIGUSR2) and hard-killing it (SIGTERM) -
# just long enough for the release/deconfig step to actually run first.
# Pulled up from an inline `sleep 0.2` literal to a named constant, same
# value, no behavior change.
DHCP_KILL_GRACE_SECS=0.2

start_bridge_dhcp() {
    command -v udhcpc >/dev/null 2>&1 || { err "udhcpc not found - can't request a DHCP lease on $BRIDGE_NAME. The bridge/tap itself is still fully working, just without its own address on the LAN."; return 1; }
    say "Requesting a DHCP lease on $BRIDGE_NAME from the LAN this bridge is tapping (up to ~${BRIDGE_DHCP_TIMEOUT_SECS}s)..."
    if timeout "$BRIDGE_DHCP_TIMEOUT_SECS" udhcpc -i "$BRIDGE_NAME" -p "$BRIDGE_DHCP_PIDFILE" -t "$BRIDGE_DHCP_DISCOVER_TRIES" -T "$BRIDGE_DHCP_RETRY_INTERVAL_SECS" -n >/tmp/pager-sniff-dhcp.log 2>&1; then
        local _ip
        _ip=$(ip -4 -o addr show "$BRIDGE_NAME" 2>/dev/null | awk '{print $4}' | head -1)
        if [ -n "$_ip" ]; then
            say "Got a lease: $_ip - SSH now reachable there too (from the tethered PC, or anywhere else on this LAN), no reset needed when the bridge/tap session ends normally."
        else
            err "udhcpc reported success but no IPv4 address showed up on $BRIDGE_NAME - check $BRIDGE_DHCP_PIDFILE / /tmp/pager-sniff-dhcp.log."
        fi
    else
        err "No DHCP lease obtained on $BRIDGE_NAME within the time budget (check /tmp/pager-sniff-dhcp.log) - the bridge/tap is still fully working, just without its own address on this LAN. Management stays reachable the normal way (USB-C/br-lan, until the bridge ends) or over Management WiFi if it's configured."
        rm -f "$BRIDGE_DHCP_PIDFILE"
        return 1
    fi
}

# stop_bridge_dhcp - counterpart to start_bridge_dhcp() above, called from
# every teardown path (stop_lan_watchdog() below, the MAX_BRIDGE_SECS
# forced-teardown branch, --unbridge, AND reset.sh's own br-sniff teardown
# - same "every exit path must clean up, not just the happy one"
# discipline already established for the watchdog itself). Releasing the
# lease (-R) is a courtesy to the DHCP server (frees the lease sooner
# instead of making it wait out the full lease time for an inactive
# client) - harmless no-op if nothing was ever running.
#
# BUG FOUND AND FIXED (CRITICAL, PID-reuse gap that tonight's other
# WATCHDOG_PIDFILE/PIDFILE.watcher/PIDFILE.feed fixes in this file never
# got carried over to): this used a bare `kill -USR2 "$_pid"` / `kill
# "$_pid"` on whatever number BRIDGE_DHCP_PIDFILE currently contains, with
# no confirmation that PID is still actually the udhcpc process this file
# wrote it for - the exact same class of bug pid_running() was introduced
# to close for every OTHER pidfile-kill site in this script (is_running()'s
# "tcpdump" check, and all three WATCHDOG_PIDFILE sites' "sniff.sh" check).
# BRIDGE_DHCP_PIDFILE is genuinely exposed to this: udhcpc here runs as a
# long-lived background daemon for up to MAX_BRIDGE_SECS (an hour by
# default) on a device this file's own comments repeatedly describe as
# memory/CPU-constrained - if it dies out-of-band (OOM kill, crash) before
# stop_bridge_dhcp() runs, and the PID counter later reuses that exact
# number for an unrelated process (sshd, a cron job, anything) in the
# meantime, this would signal that unrelated process instead. Verified
# standalone: pid_running() against a live PID that is NOT udhcpc (pattern
# "udhcpc" not present in its /proc/PID/cmdline) correctly returns 1/false
# and skips the kill, where the old unconditional code would have signaled
# it regardless - confirmed against both a non-udhcpc live PID (negative
# control) and a process with argv[0] set to "udhcpc" (positive control,
# via `exec -a udhcpc`), both matching pid_running()'s documented
# semantics. Routed through the same pid_running() primitive as every
# other pidfile-kill site in this file, with "udhcpc" as the NAME_PATTERN
# (udhcpc is a real, separate process here, not a subshell of this script,
# so it needs its own pattern rather than "sniff.sh").
stop_bridge_dhcp() {
    if [ -f "$BRIDGE_DHCP_PIDFILE" ]; then
        local _pid
        _pid=$(cat "$BRIDGE_DHCP_PIDFILE" 2>/dev/null)
        if pid_running "$BRIDGE_DHCP_PIDFILE" "udhcpc"; then
            kill -USR2 "$_pid" 2>/dev/null
            sleep "$DHCP_KILL_GRACE_SECS"
            kill "$_pid" 2>/dev/null
        fi
        rm -f "$BRIDGE_DHCP_PIDFILE"
    fi
}

# MAX_BRIDGE_SECS - INVENTED FEATURE, a SECOND, trap-independent safety
# net. The only thing that normally restores eth0 to br-lan after a bridge
# session ends is payload.sh's own `trap '.../--unbridge...' EXIT` (plus,
# as of this session's fixes, sniff.sh's own rollback trap during setup
# itself) - but a bash EXIT trap CANNOT fire on SIGKILL, and if the
# platform's own "payload appears hung, force-stop it" mechanism uses
# SIGKILL (very plausible - standard for a hung-process killer), the trap
# never runs. When that happens, this watchdog - already running as its
# own independent, already-detached background process (forked by sniff.sh
# below, then orphaned/reparented once sniff.sh itself exits - it is NOT a
# child of payload.sh and does not die with it, confirmed by how it's
# started: a backgrounded subshell whose PID is recorded and whose parent
# process exits immediately after) is the only thing left that could
# still notice and fix a stuck bridge - so it's taught to enforce a hard
# maximum bridge lifetime, independent of the EXIT trap mechanism
# entirely: if a bridge has been up longer than MAX_BRIDGE_SECS, tear it
# down and restore eth0 automatically, no matter what happened to whatever
# process originally created it. Default 60 minutes - long enough for any
# real sniffing session, short enough that a killed/abandoned payload
# can't hold SSH hostage indefinitely. Override with PAGER_MAX_BRIDGE_SECS
# for a deliberately longer session.
MAX_BRIDGE_SECS="${PAGER_MAX_BRIDGE_SECS:-3600}"

# WATCHDOG_POLL_INTERVAL_SECS - how often (5s) start_lan_watchdog's loop
# re-checks bridge-member presence / MAX_BRIDGE_SECS / canonicalize_lan_
# topology.
WATCHDOG_POLL_INTERVAL_SECS=5

# WATCHDOG_MEMBER_RETRY_COUNT - number of extra 1s-apart retries (2)
# start_lan_watchdog gives a bridge member's sysfs presence check before
# concluding it's really gone and tearing the bridge down - guards against
# a single transient hiccup causing a false-positive teardown of a
# perfectly healthy bridge (same reasoning as UNBRIDGE_DELETE_RETRY_COUNT
# below). Pulled up from an inline `-lt 2` loop-bound literal to a named
# constant, same value, no behavior change.
WATCHDOG_MEMBER_RETRY_COUNT=2

# UNBRIDGE_DELETE_RETRY_COUNT - number of extra 1s-apart retries (3)
# --unbridge gives `ip link delete $BRIDGE_NAME` before reporting it
# couldn't be removed - a netlink socket can transiently still be settling
# right after a disruptive bridge teardown (same reasoning as
# WATCHDOG_MEMBER_RETRY_COUNT above and canonicalize_lan_topology's own
# retry loop in lib/common.sh). Pulled up from an inline `-lt 3` loop-bound
# literal (in the --unbridge handler further down) to a named constant,
# same value, no behavior change.
UNBRIDGE_DELETE_RETRY_COUNT=3

start_lan_watchdog() {
    # BUG FOUND AND FIXED (CRITICAL, live-caught): this never checked for
    # or killed a PRE-EXISTING watchdog before overwriting WATCHDOG_PIDFILE
    # with a new one. Confirmed live: a --bridge invoked over SSH whose
    # controlling session then dies (a dropped connection, exactly what
    # happens on every plain-bridge test - the client side goes dark the
    # instant eth0 leaves br-lan) never gets a chance to run --unbridge,
    # so its watchdog subshell is orphaned - still alive, still running its
    # 5s loop - with nothing left tracking or ever killing it, because the
    # VERY NEXT --bridge (a retry, or the LAN Sniffer payload run again)
    # just calls this function again and silently clobbers WATCHDOG_PIDFILE
    # with the NEW watchdog's PID. --unbridge/reset.sh's own network step
    # only ever kill whatever PID the file CURRENTLY points to, so the
    # orphaned one from the FIRST attempt becomes permanently untracked and
    # unkillable short of `ps`-hunting for it by hand or waiting out
    # MAX_BRIDGE_SECS (up to an hour). Found running 11 minutes after its
    # own bridge had already been torn apart by other means, spending that
    # whole time re-evaluating canonicalize_lan_topology(bridged, ...)
    # every 5s against network state that had long since moved on -
    # plausible contributor to intermittent connectivity reports during
    # that window, independent of whatever bridge/test was active at the
    # time. Kill and clear any existing watchdog first, every time, so at
    # most one can ever be alive.
    #
    # PID-reuse-guarded kill (see kill_tracked_pid()'s own header, up near
    # is_running(), for the full reasoning): a bare `kill "$(cat pidfile)"`
    # would trust the pidfile's number completely, with no confirmation the
    # PID it's about to kill is actually still the watchdog subshell that
    # wrote it - a real risk if that subshell died out-of-band (crash, an
    # external `kill -9`) and this device's PID counter later reused the
    # number for an unrelated process before the next --bridge ran. This
    # also covers the "stale/garbage/missing pidfile" cases: a missing file
    # is a no-op; a PID that plainly isn't a "sniff.sh" subshell is left
    # alone (only its stale pidfile gets cleaned up), never blind-killed.
    kill_tracked_pid "$WATCHDOG_PIDFILE" "sniff.sh"
    # BUG FOUND AND FIXED (edge case, verified with a standalone test before
    # applying here): the `|| echo 0` fallback below meant a `date +%s`
    # failure at exactly this moment (the ONE time it's read to compute the
    # deadline baseline) produced _start_ts="0" - which the case statement
    # further down treats as a perfectly valid, real timestamp (epoch 0),
    # not as "unknown"/"disabled". Verified: with MAX_BRIDGE_SECS=3600 that
    # computes _deadline=3600 - a tiny number compared to any REAL `$(date
    # +%s)` value (currently ~1.7 billion) - so the very next per-cycle
    # `$_now -ge $_deadline` check (using a real, successful `date` call,
    # since only the ONE-TIME initial read need have failed) is true
    # immediately, tearing down a brand-new, perfectly healthy bridge on its
    # very first 5s tick. The case statement already has a correct, safe
    # "disabled" path for this - `''` (empty) - matching how `_now`'s own
    # per-cycle read is already handled (case '' -> 0, guarded by `_deadline
    # -gt 0`). Dropping the fallback lets a genuine failure hit that
    # existing safe path instead of colliding with a real epoch value.
    local _start_ts
    _start_ts=$(date +%s 2>/dev/null)
    echo "$_start_ts" > "$BRIDGE_STARTED_FILE" 2>/dev/null
    (
        # PERFORMANCE FIX: the MAX_BRIDGE_SECS deadline used to be
        # RECOMPUTED from scratch every single 5s tick - re-reading the
        # start-time file (`cat`) and re-subtracting from a fresh
        # `date +%s`, 2 process spawns every cycle, for the entire
        # lifetime of a bridge session, just to redo the identical
        # subtraction each time. The start time never changes once the
        # bridge is up, so the deadline can be computed ONCE here instead
        # (still writing $BRIDGE_STARTED_FILE above first, unchanged, for
        # external visibility - `cat` it over SSH to see when a bridge
        # started) and compared against a plain local variable each cycle,
        # halving this to 1 spawn/cycle (`date +%s` alone) with identical
        # behavior.
        local _deadline=0
        case "$_start_ts" in
            ''|*[!0-9]*) _deadline=0 ;;
            *) _deadline=$((_start_ts + MAX_BRIDGE_SECS)) ;;
        esac
        while :; do
            sleep "$WATCHDOG_POLL_INTERVAL_SECS"
            # MAX_BRIDGE_SECS enforcement (see header above this function)
            # - checked BEFORE the normal per-cycle recovery check below,
            # so a bridge that's simply overstayed its welcome gets torn
            # down outright rather than kept alive by the very recovery
            # logic meant to protect a legitimately still-running session.
            if [ "$_deadline" -gt 0 ]; then
                _now=$(date +%s 2>/dev/null)
                case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
                if [ "$_now" -gt 0 ] && [ "$_now" -ge "$_deadline" ]; then
                    # BUG FOUND AND FIXED (same reordering fix as
                    # --unbridge, applied here too for consistency/
                    # defense-in-depth - this watchdog already runs
                    # detached from any SSH session so it isn't directly
                    # exposed to the same failure, but there's no reason
                    # to leave the riskier order here when the safer one
                    # costs nothing): stop_bridge_dhcp() releases the DHCP
                    # lease, which can remove br-sniff's own address -
                    # moved to AFTER eth0 is back in br-lan, matching
                    # --unbridge's own fix.
                    ip_link set eth0 master br-lan 2>/dev/null
                    ip_link set eth0 up 2>/dev/null
                    stop_bridge_dhcp
                    ip_link set "$BRIDGE_NAME" down 2>/dev/null
                    ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
                    echo "[sniff.sh watchdog] Bridge exceeded ${MAX_BRIDGE_SECS}s - automatically torn down, eth0 restored to br-lan (second safety net, independent of any EXIT trap)." >>/tmp/pager-sniff.log 2>/dev/null
                    rm -f "$BRIDGE_STARTED_FILE" "$WATCHDOG_PIDFILE"
                    exit 0
                fi
            fi
            # BUG FOUND AND FIXED (CRITICAL, freshly discovered this pass -
            # matches a real, confirmed-live trigger: usb_monitor.sh
            # independently detected and printed "USB-A (eth1): detached"
            # on-screen DURING an active LAN Sniffer bridge/capture session
            # tonight). canonicalize_lan_topology's own "bridged" branch
            # (lib/common.sh) only checks whether $BRIDGE_NAME (br-sniff)
            # ITSELF still exists via `ip_link show` - it has no idea
            # whether the interfaces actually bridged into it are still
            # there. A USB-A adapter being physically UNPLUGGED does not
            # remove br-sniff - the bridge device survives with one fewer
            # port. This is NOT the same as a cable-pull on a fixed NIC
            # (carrier goes to 0, the interface itself stays in
            # /sys/class/net) - an actual USB device removal triggers the
            # kernel driver's disconnect() and unregisters the netdev
            # entirely, so BR_IFACE2 (eth1) vanishes outright. Because
            # `ip_link show "$BRIDGE_NAME"` keeps succeeding regardless, the
            # reconciler's "bridge present - presumably holding eth0, not
            # this reconciler's job to touch it" fast path fires every
            # single 5s tick from that point on forever - eth0 is NEVER
            # restored to br-lan no matter how long the bridge sits broken
            # with a missing far-end leg. If --dhcp was in use, its lease
            # was obtained VIA that now-vanished upstream link and is dead
            # too - leaving BOTH the br-lan management path (eth0 still
            # enslaved to a now half-useless br-sniff) AND the --dhcp path
            # unreachable, with nothing left to notice short of a human
            # watching, or MAX_BRIDGE_SECS (an hour by default) finally
            # elapsing. Checking that BOTH configured bridge members are
            # still present - not just the bridge device itself - before
            # trusting the "bridge is healthy" fast path closes this: a
            # genuinely vanished member now drives the exact same immediate
            # teardown-and-restore path the MAX_BRIDGE_SECS branch above
            # already uses, instead of waiting up to an hour or forever. A
            # short retry (same 1s-delay/multi-try shape already used
            # everywhere else in this file, e.g. canonicalize_lan_topology's
            # own 3-try loop and --bridge's own existence-check retry)
            # avoids a false-positive teardown from nothing worse than a
            # single transient `ip link` hiccup.
            # BUG FOUND AND FIXED (CRITICAL, re-auditing tonight's own fix
            # above - confirmed with a standalone repro before applying):
            # the member-presence check used `ip_link show IFACE` (i.e.
            # `timeout $IP_LINK_TIMEOUT ip link show IFACE`, see ip_link()
            # in common.sh) to test whether BR_IFACE1/BR_IFACE2 still exist.
            # But that talks to the kernel over netlink - the EXACT call
            # class this very file's OWN first fix (top of this file)
            # documents as having wedged indefinitely on this device before
            # its timeout guard existed. A wedged/congested (not literally
            # infinite - anything that reliably eats the full
            # IP_LINK_TIMEOUT per call) netlink socket makes `ip_link show`
            # return nonzero for an interface that never actually went
            # anywhere - indistinguishable, at this check, from a genuinely
            # unplugged adapter. Since the retry loop only re-ran the SAME
            # netlink-based check 2 more times 1s apart, a SUSTAINED wedge
            # (not a one-off blip) fails every retry too, so this would
            # tear down a perfectly healthy, still-attached bridge - the
            # "watchdog fights a legitimately active bridge" failure class
            # canonicalize_lan_topology's own header (common.sh) already
            # names as the reason a second hand-written copy of this kind
            # of check is dangerous to get wrong. Verified standalone (fake
            # `ip` binary that just hangs, real interfaces present in a
            # fake sysfs tree the whole time): the old ip_link-based check
            # took 23s and still concluded "_member_missing=1" - a false
            # positive - while a sysfs-based check reported both present
            # correctly in 0s. Every OTHER existence check already in this
            # file (detect_usb_c, list_wired_ifaces, detect_usb_a_iface)
            # deliberately avoids `ip link` for exactly this reason and
            # reads /sys/class/net/ directly instead - a plain stat with no
            # netlink involvement, so it can never falsely report "gone"
            # from netlink congestion alone, and it's actually the more
            # authoritative signal for this exact question anyway (a real
            # USB detach unregisters the netdev, which is exactly what
            # sysfs reflects immediately - see the comment block above this
            # one). Switched to that same primitive here too.
            #
            # BUG FOUND AND FIXED (same pass, MEDIUM - the old check could
            # also never identify WHICH interface vanished for the log line
            # below: `! ip_link show A || ! ip_link show B` short-circuits
            # on A, so whenever BR_IFACE1 was the one missing, BR_IFACE2's
            # own status was never even queried - both the log message and
            # this code's own internal state stayed ambiguous about whether
            # one or both members were actually gone). Checking both
            # unconditionally (no `||`/`&&` short-circuiting) every retry
            # fixes this too - $_missing_names below now names exactly
            # which interface(s) were confirmed gone.
            _br1_present=0; _br2_present=0
            [ -e "/sys/class/net/$BR_IFACE1" ] && _br1_present=1
            [ -e "/sys/class/net/$BR_IFACE2" ] && _br2_present=1
            if [ "$_br1_present" = "0" ] || [ "$_br2_present" = "0" ]; then
                _retry=0
                while [ "$_retry" -lt "$WATCHDOG_MEMBER_RETRY_COUNT" ]; do
                    sleep 1
                    _retry=$((_retry + 1))
                    _br1_present=0; _br2_present=0
                    [ -e "/sys/class/net/$BR_IFACE1" ] && _br1_present=1
                    [ -e "/sys/class/net/$BR_IFACE2" ] && _br2_present=1
                    [ "$_br1_present" = "1" ] && [ "$_br2_present" = "1" ] && break
                done
            fi
            _member_missing=0
            _missing_names=""
            if [ "$_br1_present" = "0" ]; then
                _member_missing=1
                _missing_names="$BR_IFACE1"
            fi
            if [ "$_br2_present" = "0" ]; then
                _member_missing=1
                if [ -n "$_missing_names" ]; then
                    _missing_names="$_missing_names, $BR_IFACE2"
                else
                    _missing_names="$BR_IFACE2"
                fi
            fi
            if [ "$_member_missing" = "1" ]; then
                ip_link set eth0 master br-lan 2>/dev/null
                ip_link set eth0 up 2>/dev/null
                stop_bridge_dhcp
                ip_link set "$BRIDGE_NAME" down 2>/dev/null
                ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
                topology_log "watchdog: bridge member(s) missing: $_missing_names (of $BR_IFACE1/$BR_IFACE2) - tore down $BRIDGE_NAME and restored eth0 to br-lan"
                echo "[sniff.sh watchdog] Bridge member interface(s) $_missing_names disappeared - likely a USB adapter physically detached. Bridge torn down, eth0 restored to br-lan automatically (second safety net, independent of any EXIT trap)." >>/tmp/pager-sniff.log 2>/dev/null
                rm -f "$BRIDGE_STARTED_FILE" "$WATCHDOG_PIDFILE"
                exit 0
            fi
            # BIG CHANGE: this used to be this file's OWN independent copy
            # of "is eth0 where it belongs, fix it if not" - the exact
            # logic that caused a real, live-diagnosed incident (this
            # watchdog fighting eth0 out of an ACTIVELY RUNNING bridge
            # every 5s, because the old version checked only "is eth0 in
            # br-lan" with no awareness that NOT being there is correct
            # while a bridge session is up). That incident is exactly why
            # this is now the shared, declarative canonicalize_lan_topology()
            # in lib/common.sh instead of a second hand-maintained copy of
            # the same safety-critical recovery logic reset.sh also needs -
            # a fix to one could no longer silently miss the other.
            canonicalize_lan_topology bridged "$BRIDGE_NAME"
        done
    ) &
    echo $! > "$WATCHDOG_PIDFILE"
}

stop_lan_watchdog() {
    # Same PID-reuse-guarded kill as start_lan_watchdog's own "kill existing
    # first" guard above - see kill_tracked_pid()'s header near is_running().
    kill_tracked_pid "$WATCHDOG_PIDFILE" "sniff.sh"
    rm -f "$BRIDGE_STARTED_FILE"
    # BUG FOUND AND FIXED (CRITICAL, second half of the same live-caught
    # incident as --unbridge's own reordering fix below): stop_bridge_dhcp()
    # used to run HERE, unconditionally, as literally the FIRST thing
    # --unbridge does - but stop_bridge_dhcp() sends udhcpc a release
    # signal, which (confirmed against busybox's own default.script
    # behavior) runs its "deconfig" step and REMOVES the IP address from
    # br-sniff. If the calling session is itself connected via that exact
    # address (the whole point of --dhcp), this alone could sever the
    # connection running --unbridge BEFORE it ever reaches the eth0
    # restoration step further down - the same failure mode as the
    # ordering bug just fixed there, just one step earlier and easy to
    # miss for that reason. Moved out of here entirely - the caller now
    # invokes stop_bridge_dhcp() explicitly, AFTER eth0 is already back in
    # br-lan, not before.
}

if [ "$DO_UNBRIDGE" = "1" ]; then
    if ! ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        stop_lan_watchdog
        stop_bridge_dhcp
        say "No bridge ($BRIDGE_NAME) is up."
        exit 0
    fi
    # Kill the watchdog's own interval-check loop now (safe - it's just a
    # background bash process, touches no networking directly) - but NOT
    # stop_bridge_dhcp yet (see that function's own comment on why this
    # split matters: releasing the DHCP lease can remove br-sniff's own
    # address, which would sever a session connected through it before
    # eth0 is safely back in br-lan).
    # Same PID-reuse-guarded kill as the other two WATCHDOG_PIDFILE kill
    # sites - see kill_tracked_pid()'s header near is_running().
    kill_tracked_pid "$WATCHDOG_PIDFILE" "sniff.sh"
    rm -f "$BRIDGE_STARTED_FILE"
    # BUG FOUND AND FIXED (CRITICAL, live-caught the hard way - this is
    # exactly what left a real device unreachable at BOTH addresses,
    # needing a physical reset, right after --dhcp made SSH-over-br-sniff
    # possible): eth0 used to get restored to br-lan LAST, only after
    # `ip_link set "$BRIDGE_NAME" down` had already run - but bringing
    # br-sniff down is EXACTLY the moment a session connected through
    # br-sniff's own address (the whole point of --dhcp) loses its
    # underlying transport. If the SSH child process gets killed right
    # then (a very real, confirmed-live outcome, not a hypothetical), the
    # script never reaches the eth0-restoration line at all - the device
    # is left with NEITHER address working (br-sniff torn half-down,
    # eth0 not yet back in br-lan), unrecoverable except by physical
    # access. `ip link set eth0 master br-lan` reassigns eth0's bridge
    # membership directly (the kernel handles detaching from its old
    # master implicitly - no need to bring br-sniff down first at all),
    # so doing this FIRST means the moment it completes, 172.16.52.1 is
    # already reachable again regardless of what happens to the rest of
    # this teardown (tearing down br-sniff/eth1) or to the calling
    # session itself.
    ip_link set eth0 master br-lan 2>/dev/null
    ip_link set eth0 up 2>/dev/null
    # NOW safe to release the DHCP lease (see stop_lan_watchdog()'s own
    # comment on why this had to move to AFTER eth0 is back in br-lan) -
    # even if this removes br-sniff's own address, a session connected
    # through it already lost that path the instant eth0 left br-sniff
    # two lines up, so there's nothing left to protect by delaying this
    # further.
    stop_bridge_dhcp
    ip_link set "$BRIDGE_NAME" down
    ip_link delete "$BRIDGE_NAME" type bridge
    # BUG FOUND AND FIXED (live-caught): the delete call's own success was
    # never checked - confirmed live that it can transiently fail (a
    # netlink socket still settling right after a disruptive bridge
    # teardown), leaving $BRIDGE_NAME existing as an empty, orphaned
    # bridge device while this still unconditionally claimed "Bridge torn
    # down." eth0 restoration (the part that actually matters for SSH,
    # already done above regardless) is unaffected either way, but the
    # message should tell the truth about the bridge device itself too.
    # Short retry (same reasoning as canonicalize_lan_topology's own)
    # before reporting honestly.
    tries=0
    while [ "$tries" -lt "$UNBRIDGE_DELETE_RETRY_COUNT" ] && ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -lt "$UNBRIDGE_DELETE_RETRY_COUNT" ]; then
            sleep 1
            ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
        fi
    done
    if ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        err "eth0 restored to br-lan (management access is fine), but $BRIDGE_NAME itself could not be removed - it's left behind as an empty, harmless bridge device. Try 'sniff.sh --unbridge' again, or 'ip link delete $BRIDGE_NAME type bridge' by hand."
    else
        say "Bridge torn down. eth0 restored to br-lan (management access) - eth1 is independent again."
    fi
    exit 0
fi

if [ "$DO_BRIDGE" = "1" ]; then
    # BRIDGE_PROGRESS_FILE - INVENTED FEATURE (asked for directly - "give
    # more info on the display while setting up"): a caller that captures
    # this whole command via `$(...)` (the LAN Sniffer payload does, so it
    # can check the exit code) sees NOTHING printed here until the ENTIRE
    # --bridge call returns - every `say` below is just as invisible mid-
    # flight as raw stdout always is inside a command substitution. This
    # plain, append-only file mirrors every step-progress message as it
    # happens, so a caller that wants live feedback can tail it (same idea
    # as /tmp/pager-sniff.log for an in-progress capture) WHILE this call
    # is still running instead of only after it returns - see the LAN
    # Sniffer payload's own bridge_progress_bar() for the reader side.
    BRIDGE_PROGRESS_FILE="/tmp/pager-sniff-bridge-progress.log"
    : >"$BRIDGE_PROGRESS_FILE" 2>/dev/null
    bridge_progress() {
        local _msg="[$TOOL_NAME] $1"
        echo "$_msg"
        echo "$_msg" >>"$BRIDGE_PROGRESS_FILE" 2>/dev/null
    }

    bridge_progress "This bridges $BR_IFACE1 and $BR_IFACE2 into a transparent tap ($BRIDGE_NAME). Traffic will actually flow through the Pager between whatever's on each end."
    check_adapters || err "Continuing anyway since you gave explicit interface names - but see the check above."
    confirm "Proceed?" || die "Aborted."

    bridge_progress "Checking $BR_IFACE1 and $BR_IFACE2 exist..."
    for i in "$BR_IFACE1" "$BR_IFACE2"; do
        if ! ip_link show "$i" >/dev/null 2>&1; then
            # DIAGNOSTIC (added after this exact error was reported live,
            # twice, from the physical Payloads menu, even with both
            # interfaces confirmed present moments earlier by
            # check_adapters()): captures enough forensic detail to tell a
            # genuinely-missing interface apart from the `ip`/`timeout`
            # commands themselves not being found (a PATH problem in
            # whatever environment invoked this - common.sh now hardens
            # PATH for exactly this, but this log line means a NEXT
            # occurrence, for any reason, is diagnosable immediately
            # instead of needing another round of guessing).
            topology_log "bridge existence-check failed for '$i': PATH=$PATH ip=$(command -v ip 2>&1) timeout=$(command -v timeout 2>&1) direct_check=$(ip link show "$i" 2>&1)"
            die "Interface '$i' does not exist."
        fi
    done

    if ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        bridge_progress "$BRIDGE_NAME already exists - tearing it down first."
        ip_link set "$BRIDGE_NAME" down 2>/dev/null
        ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
    fi

    # BUG FOUND AND FIXED (CRITICAL): none of the steps below undid
    # anything already done if a LATER step failed (or, pre-timeout-fix,
    # hung) - `die` just prints an error and exits. Concretely: if
    # BR_IFACE1 (eth0) successfully got attached to $BRIDGE_NAME but the
    # very next line (attaching BR_IFACE2, or bringing an interface up)
    # then failed/timed out, eth0 was abandoned mid-bridge, out of br-lan,
    # with nothing restoring it - the exact "stuck bridge, SSH dead"
    # failure mode this whole toolkit exists to prevent, just reached via
    # plain command failure instead of the already-diagnosed SIGKILL path.
    # A local EXIT trap here undoes anything already done (delete the
    # half-built bridge - which detaches whatever got attached to it, same
    # as --unbridge already relies on - then explicitly restore eth0 to
    # br-lan) on ANY exit between here and full success; cleared right
    # before the success messages below so a normal, completed bridge
    # is never torn back down by its own safety net.
    trap '
        ip_link set "$BRIDGE_NAME" down 2>/dev/null
        ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
        ip_link set eth0 master br-lan 2>/dev/null
        ip_link set eth0 up 2>/dev/null
    ' EXIT

    bridge_progress "Creating bridge device $BRIDGE_NAME..."
    ip_link add name "$BRIDGE_NAME" type bridge || die "Failed to create bridge (or the call timed out - network stack may be unresponsive; eth0 has been restored to br-lan)."
    bridge_progress "Attaching $BR_IFACE1 to $BRIDGE_NAME..."
    ip_link set "$BR_IFACE1" master "$BRIDGE_NAME" || die "Failed to attach $BR_IFACE1 (or the call timed out; eth0 has been restored to br-lan)."
    bridge_progress "Attaching $BR_IFACE2 to $BRIDGE_NAME..."
    ip_link set "$BR_IFACE2" master "$BRIDGE_NAME" || die "Failed to attach $BR_IFACE2 (or the call timed out; eth0 has been restored to br-lan)."
    # BUG FOUND AND FIXED (live-diagnosed - this is very likely why --dhcp's
    # own lease worked (confirmed live: real DHCP lease obtained, ARP
    # resolved to the Pager's exact eth0 MAC) but SSH to that new address
    # still wasn't reachable): a bridge member interface keeps whatever
    # L3 address/routes it already had BEFORE being enslaved - confirmed
    # live that BR_IFACE2 (eth1) still carried its own pre-existing address
    # and default route from ITS OWN separate netifd-managed DHCP client
    # (a completely different lease than the new one --dhcp requests on the
    # bridge device itself) even after becoming a bridge slave. A slave
    # interface can't actually do L3 routing once enslaved - but the STALE
    # route table entries referencing it don't know that, and can make the
    # kernel pick the now-useless slave interface for reply traffic instead
    # of the bridge device that's actually able to send it, silently
    # eating replies (e.g. a TCP SYN reaching sshd, but its SYN-ACK never
    # making it back out). Flushing both members' addresses right after
    # they join the bridge (standard Linux bridging practice - a bridge
    # slave should never carry its own address once enslaved) removes the
    # ambiguity regardless of whether --dhcp is even used.
    bridge_progress "Clearing old addresses from both bridge members (standard practice once enslaved)..."
    timeout "$IP_LINK_TIMEOUT" ip addr flush dev "$BR_IFACE1" 2>/dev/null
    timeout "$IP_LINK_TIMEOUT" ip addr flush dev "$BR_IFACE2" 2>/dev/null
    ip_link set "$BR_IFACE1" up
    ip_link set "$BR_IFACE2" up
    bridge_progress "Bringing $BRIDGE_NAME up..."
    ip_link set "$BRIDGE_NAME" up

    trap - EXIT

    bridge_progress "Bridge $BRIDGE_NAME is up ($BR_IFACE1 <-> $BR_IFACE2)."
    say "Sniff everything passing through with: sniff.sh --iface $BRIDGE_NAME"
    say "Tear it down later with: sniff.sh --unbridge"
    # KNOWN LIMITATION (tried and reverted - see README.md's postmortem
    # notes for the full story): a tethered client's own NIC never sees a
    # link-state change here (the cable stays plugged in throughout), so
    # its OS may keep sitting on an old lease instead of proactively
    # renewing. An eth0 down/up flap was tried to mimic a cable
    # unplug/replug and force that renewal, but eth0 on this hardware is
    # documented above (see detect_usb_c) as the SoC's own USB-Ethernet
    # gadget controller, not a plain PHY - toggling it isn't guaranteed to
    # be a simple carrier blip and live-tested as a full device lockup
    # instead. Removed rather than risk that again; if the client doesn't
    # pick up the new network on its own, do a manual DHCP renew there
    # (Windows: ipconfig /release then /renew; Linux: dhclient -r then
    # dhclient) on the interface facing this Pager.
    say "If the tethered client doesn't pick up the new network automatically, a manual DHCP renew there (ipconfig /release+/renew on Windows, dhclient -r/dhclient on Linux) may be needed."
    start_lan_watchdog
    say "LAN watchdog running in the background - auto-recovers SSH/eth0-in-br-lan if the bridge ever leaves it disconnected."
    # --dhcp (see start_bridge_dhcp's own header for the full story) - a
    # deliberate bonus, not a dependency: a failed/slow lease here never
    # aborts the bridge itself, which is already fully up and tapping
    # traffic by this point regardless of what happens next.
    [ "$BRIDGE_DHCP" = "1" ] && start_bridge_dhcp
    exit 0
fi

INTERACTIVE=0
[ -z "$IFACE" ] && INTERACTIVE=1

# Adapter status is shown automatically before every capture, interactive
# or not - you shouldn't have to remember a separate flag to know whether
# you're about to sniff a single NIC or could be tapping both.
check_adapters || true
echo

if [ "$INTERACTIVE" = "1" ]; then
    echo "== sniff.sh =="
    if ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        default_iface="$BRIDGE_NAME"
    else
        default_iface="eth1"
    fi
    say "Candidate interfaces:"
    list_wired_ifaces
    IFACE=$(ask "Interface to sniff" "$default_iface")
    FILTER=$(ask "tcpdump filter (blank = everything)" "$FILTER")
    if ! confirm "Show packets live as they're captured (recommended)?"; then LIVE=0; fi
fi

[ -z "$IFACE" ] && IFACE="eth1"

# BUG FOUND AND FIXED (live-diagnosed as the most likely root cause behind
# a real device report: a LAN Sniffer bridge run that never actually
# started its capture, traced to this exact check): a single ip_link()
# call is still subject to its own timeout - on THIS device, real
# transient contention has now been confirmed multiple times in one
# session (PINEAPPLE_EXAMINE_RESET timing out twice in reset.sh, right
# around this same incident). A transient stall here would misreport a
# genuinely-existing interface (like a freshly-created br-sniff) as "does
# not exist" and abort the whole capture launch - one retry after a short
# pause, matching the same "transient vs genuinely missing" distinction
# reset_wifi() and the br-sniff teardown retries already use elsewhere in
# this toolkit.
if ! ip_link show "$IFACE" >/dev/null 2>&1; then
    sleep 1
    if ! ip_link show "$IFACE" >/dev/null 2>&1; then
        die "Interface '$IFACE' does not exist. Use --list to see candidates, or --bridge to tap two NICs together."
    fi
fi

# BUG FOUND AND FIXED (clarity): this named WHICH program was missing
# (tcpdump) but never said what to do about it - every other required-
# program check in this toolkit that can actually be remediated on-device
# (LanScan.sh's nmap check, webui.sh/deadnet.sh's python3 check) pairs the
# "not installed" diagnosis with the exact opkg command to fix it; this
# one didn't, for no functional reason - just an oversight, not a
# deliberate omission (tcpdump normally ships pre-installed on the Pager,
# per this file's own header comment, so hitting this at all already
# means something non-standard happened - a stripped-down image or a
# firmware issue - which is exactly when a caller most needs to be told
# how to recover, not just that something is wrong). User sees "tcpdump
# is not installed on this device." and would think "now what - reflash?
# is my Pager broken?" with no next step offered, unlike every sibling
# check in this same toolkit. Matching the established convention here
# closes that gap.
command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed on this device (unusual - it normally ships pre-installed on the Pager). Install it with: opkg update && opkg install -d mmc tcpdump"

# Fast, non-authoritative pre-check only - avoids running interface
# validation/mkdir/etc. below just to fail anyway in the common case. NOT
# what closes the concurrent-launch race (see LOCKDIR's own header comment
# above, near --status): the real, lock-protected check+fork+PIDFILE-write
# happens together at the actual launch site further down, which is the
# only way to close the gap between "checked" and "wrote" instead of just
# moving it.
if [ "$BACKGROUND" = "1" ] && is_running; then
    die "A background capture is already running (PID $(cat "$PIDFILE")). Use --stop first."
fi

mkdir -p "$LOOT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo "sniff")
[ -z "$OUTPUT" ] && OUTPUT="$LOOT_DIR/sniff-${IFACE}-${STAMP}.pcap"

# BUG FOUND AND FIXED (clarity): `mkdir -p "$LOOT_DIR"` above is a silent
# no-op whenever the directory already exists - which it normally does
# after the first capture ever run on this device - so it proves nothing
# about whether that directory can actually be WRITTEN to right now. A
# disk that's since filled up, or a filesystem that's gone read-only
# (both real conditions on a small-storage device like this one, and both
# reachable with the directory present and unchanged), sailed straight
# past this line with no error. The actual failure only surfaced later,
# inside tcpdump itself: in the foreground path it showed up buried in
# tcpdump's own stderr (mixed into the live packet output via the `2>&1`
# in run_capture) or as the generic three-way-guess "tcpdump likely never
# started (bad --filter syntax, '$IFACE' disappearing, or the --output
# directory not existing/writable)" further below; in the --background
# path it was worse - the exact same failure produced "Capture exited
# immediately - check /tmp/pager-sniff.log (a bad --duration or --filter,
# or tcpdump failing to open '$IFACE', are the likely causes)", which
# doesn't even mention the output directory as a possibility, actively
# pointing the caller at the wrong three suspects for a still-perfectly-
# fine --duration/--filter/--iface. User sees that message, would think
# "my filter or interface is wrong" and starts second-guessing a correct
# command line, when the real problem (a full or read-only disk) isn't
# named anywhere. Proactively write-testing the real target directory
# here - before tcpdump ever launches, in both foreground and background
# modes alike - catches read-only-filesystem and out-of-space failures
# at the moment they actually happen and reports the OS's own specific
# reason (EACCES/EROFS/ENOSPC all produce distinct, human-readable text
# from bash's own redirection error handling - verified standalone: a
# missing/unwritable target directory reliably produces a message like
# "No such file or directory" or "Permission denied" via this exact
# `: > file` redirection idiom) instead of a generic multi-cause guess.
out_dir=$(dirname "$OUTPUT")
if ! write_test_err=$( { : > "$out_dir/.sniff-write-test.$$"; } 2>&1 ); then
    die "Can't write to the capture output folder '$out_dir' ($write_test_err) - likely the disk is full or the filesystem is read-only. Check with 'df -h $out_dir', or pass --output to save somewhere else (e.g. --output /tmp/capture.pcap)."
fi
rm -f "$out_dir/.sniff-write-test.$$"

# BUG FOUND AND FIXED: -U (unbuffered immediate writes to the save file)
# used to be tied to NOT showing live output - backwards, since -U is
# about the FILE write being crash-safe, unrelated to whether packets are
# also displayed. Always use it now: if a capture gets killed abruptly
# (crash, --stop, power loss), the .pcap file on disk still has everything
# captured up to that moment instead of whatever was still buffered.
#
# BUG FOUND (reported live - "LAN sniff only says host:..., it's also
# not spamming") AND PARTIALLY FIXED, THEN FULLY DIAGNOSED: -l is
# tcpdump's own flag for line-buffered stdout (tracer.sh already used it
# for the same reason) - a real fix for a real buffering issue, but
# proved INSUFFICIENT on its own once tested live with genuine traffic:
# a real capture showed 67 packets landed in the .pcap file while ZERO
# per-packet lines ever reached the log, -l or not. Root cause turned out
# to be simpler and more fundamental: tcpdump does not print its human-
# readable per-packet summary to stdout AT ALL when -w (saving to a
# file) is given - that's documented behavior, not a buffering bug -
# meaning -l alone could never have fixed this regardless. -l is still
# correct/harmless to keep (it's what actually lets run_packet_feed's
# own re-reads print live rather than each one buffering internally), but
# the real fix for "show packets live while also saving them" is
# run_packet_feed below (see its own comment for why a live tee-pipeline
# was deliberately avoided).
TD_ARGS=(-l -i "$IFACE" -w "$OUTPUT" -U)
[ -n "$COUNT" ] && TD_ARGS+=(-c "$COUNT")

say "Interface: $IFACE"
say "Output:    $OUTPUT"
[ -n "$FILTER" ] && say "Filter:    $FILTER"
[ -n "$DURATION" ] && say "Duration:  ${DURATION}s"
[ -n "$COUNT" ] && say "Count:     $COUNT packets"

# run_capture - used for FOREGROUND captures only (the script keeps
# running after this returns, to print the "Done"/summary below - see
# run_capture_bg for why background can't share this function unchanged).
#
# BUG FOUND AND FIXED (found via code review, verified with a standalone
# `bash -c` repro before applying): $FILTER is deliberately left UNQUOTED
# below - tcpdump joins multiple trailing plain arguments into one filter
# expression, so word-splitting an unquoted `--filter "port 80 or port
# 443"` into separate argv words is what lets a multi-word BPF expression
# work at all; quoting it would pass the whole thing as one single (and to
# tcpdump, invalid) argument instead. But bash's unquoted expansion doesn't
# just word-split - it ALSO pathname-expands (globs) each resulting word,
# and common BPF idioms use bracket syntax that IS valid glob syntax too
# (e.g. `tcp[13] & 0x02 != 0` and `ip[9] == 6`, both standard, commonly-
# taught ways to match TCP flags/protocol numbers by byte offset).
# Confirmed standalone: with a file literally named "tcp1" sitting in the
# current directory, `FILTER="tcp[13] and port 80"; set -- $FILTER; echo
# "$1"` prints "tcp1", not the literal "tcp[13]" the operator typed - the
# filter silently gets corrupted into whatever matched, with no error, no
# warning, and a capture that ran with the WRONG filter the whole time.
# This is a realistic, not contrived, trigger: sniff.sh doesn't cd anywhere
# special first, so its current directory is whatever the caller's shell
# (or the payload runner) happened to be in - a `/root` with ordinary
# single/double-character filenames left over from other tools is enough.
# `set -f` (noglob) disables ONLY the pathname-expansion half while leaving
# word-splitting fully intact, so a multi-word filter still becomes
# multiple argv words exactly as intended, but a bracket/glob-looking token
# in it is now always passed through byte-for-byte. Scoped to just this
# function (restored before returning) rather than set globally, since
# lib/common.sh's own detect_usb_a_iface() (called via check_adapters()
# earlier in this script) relies on real globbing over /sys/class/net/*.
run_capture() {
    set -f
    local _rc
    if [ "$LIVE" = "1" ]; then
        if [ -n "$DURATION" ]; then
            timeout "$DURATION" tcpdump "${TD_ARGS[@]}" $FILTER 2>&1
        else
            tcpdump "${TD_ARGS[@]}" $FILTER 2>&1
        fi
    else
        if [ -n "$DURATION" ]; then
            timeout "$DURATION" tcpdump "${TD_ARGS[@]}" $FILTER >/dev/null 2>&1
        else
            tcpdump "${TD_ARGS[@]}" $FILTER >/dev/null 2>&1
        fi
    fi
    _rc=$?
    set +f
    return "$_rc"
}

# run_capture_bg - BUG FOUND AND FIXED (live-verified): --background used
# to launch `( trap '' HUP; run_capture ) & ; echo $! > "$PIDFILE"`, i.e.
# tcpdump/timeout ran as a plain (non-exec'd) command reached through a
# function call inside that subshell. Confirmed LIVE that this does NOT
# collapse into one process the way it looks like it should: the subshell
# forks tcpdump as its own child instead of becoming it, so $! (captured
# right after backgrounding) was the SUBSHELL's PID, not tcpdump's.
# `--stop` killing that PID only killed the empty subshell wrapper - the
# real tcpdump child was orphaned (reparented to init) and kept capturing
# forever, completely invisible to `--status`, with the script still
# reporting "Stopped." (Live-caught via a leftover tcpdump process still
# running well after a --stop in an unrelated test.) `exec` here makes the
# subshell replace ITSELF with tcpdump/timeout instead of forking it, so
# the PID this script tracks IS the real worker - confirmed live that
# busybox `timeout` also correctly forwards SIGTERM to its own child, so
# killing the exec'd `timeout` PID stops tcpdump too, not just timeout.
# Deliberately a separate function from run_capture (which foreground
# capture still uses unmodified) - `exec` never returns, so it can only
# ever be used somewhere nothing needs to run afterward in the same
# process, which is true for this disposable background subshell but NOT
# true for the foreground path (which prints "Done"/the summary after).
run_capture_bg() {
    # Same unquoted-$FILTER glob-expansion risk as run_capture() above, same
    # fix - see its own comment for the standalone repro. No matching
    # `set +f` needed here: every branch below ends in `exec`, which
    # replaces this subshell's process image outright, so there's no
    # "after" for a shell option to leak into.
    set -f
    if [ "$LIVE" = "1" ]; then
        if [ -n "$DURATION" ]; then
            exec timeout "$DURATION" tcpdump "${TD_ARGS[@]}" $FILTER 2>&1
        else
            exec tcpdump "${TD_ARGS[@]}" $FILTER 2>&1
        fi
    else
        if [ -n "$DURATION" ]; then
            exec timeout "$DURATION" tcpdump "${TD_ARGS[@]}" $FILTER >/dev/null 2>&1
        else
            exec tcpdump "${TD_ARGS[@]}" $FILTER >/dev/null 2>&1
        fi
    fi
}

if [ "$BACKGROUND" = "1" ]; then
    say "Launching capture in the background - use 'sniff.sh --stop' to end it."
    # AUTHORITATIVE check-then-act, lock-protected - see LOCKDIR's own
    # header comment (near --status above) for the full reasoning/repro:
    # this is the actual check+fork+PIDFILE-write sequence that two
    # concurrent --background launches could otherwise both race through,
    # each thinking it alone confirmed nothing was running. Held only
    # across the check and the fork+write themselves (not the liveness
    # sleep below, which needs no cross-process exclusion) so a waiter
    # never blocks on more than a fast, local operation.
    acquire_lock
    trap release_lock EXIT
    if is_running; then
        die "A background capture is already running (PID $(cat "$PIDFILE")). Use --stop first."
    fi
    # No `nohup` on this busybox build - ignore SIGHUP in a subshell instead.
    ( trap '' HUP; run_capture_bg ) >/tmp/pager-sniff.log 2>&1 &
    BG_PID=$!
    echo "$BG_PID" > "$PIDFILE"
    release_lock
    trap - EXIT
    # BUG FOUND AND FIXED (found via code review, same class as
    # PayloadRunner.sh's own fix): this used to print "Started (PID ...)"
    # unconditionally right after backgrounding, with no check the
    # capture actually survived - run_capture_bg's `exec` means a bad
    # --duration or any other immediate tcpdump/timeout failure replaces
    # the subshell with an already-dead process within a fraction of a
    # second, invisible to a check that doesn't wait and look. webui.sh
    # already does exactly this liveness check for its own background
    # launch - matching that here instead of assuming success.
    #
    # BUG FOUND AND FIXED (verified with a standalone repro before writing
    # this fix: looping the equivalent of `( exec timeout 1 sleep N ) &
    # PID=$!; sleep 1; kill -0 "$PID"` 50 times measured the backgrounded
    # process already gone by the time the check ran in 3/50 runs - a real,
    # non-hypothetical rate even on hardware far faster than this device).
    # A `--background --duration 1` capture (a real, explicitly-supported
    # value - --duration 0 is rejected above specifically as "not the same
    # as stop immediately", so 1 is the shortest capture a caller can
    # actually ask for) races its own `timeout 1` deadline against this
    # same fixed 1s liveness-check sleep, since run_capture_bg's `exec`
    # means the backgrounded process's own countdown and this sleep both
    # start within a few ms of each other. When the process loses that
    # race and has already exited by the time `is_running` runs, the OLD
    # code below unconditionally treated "not running" as failure and
    # `die`d with "Capture exited immediately" - actively WRONG for this
    # case: the capture didn't fail, it ran its full requested 1 second and
    # completed normally, exactly as a longer capture would if checked
    # after ITS own duration elapsed. Distinguishing the two cases the same
    # way this file's own foreground path already does further down (a
    # non-empty $OUTPUT means tcpdump genuinely opened the interface and
    # wrote real capture data, vs. an empty/missing one meaning it never
    # got that far) - a short-but-real completed capture now reports
    # success with its real (possibly empty-of-packets, but real) .pcap,
    # instead of a misleading failure message for a capture that actually
    # worked.
    # BUG FOUND AND FIXED (narrow, but real - traced while writing the fix
    # just above, not a separate live symptom): a bare `rm -f "$PIDFILE"`
    # in the two branches below assumes $PIDFILE still holds OUR OWN
    # $BG_PID - true in the overwhelmingly common case, but this whole
    # section runs AFTER release_lock, so it's no longer serialized against
    # another --background invocation. A capture that loses the race just
    # documented above (finishes within this same 1s window) creates a
    # narrow opening: if a brand-new, unrelated --background is launched by
    # someone else in that same window, sees (correctly) that our now-
    # finished capture isn't running, and writes ITS OWN pid to $PIDFILE
    # before we reach our own `rm -f` here, a bare unconditional rm would
    # delete THAT capture's live tracking entirely - the exact "orphaned,
    # untracked tcpdump" failure mode this whole fix exists to prevent,
    # just reached via a different interleaving. Only remove $PIDFILE when
    # it still names the PID we ourselves wrote.
    sleep 1
    if is_running; then
        say "Started (PID $(cat "$PIDFILE"))."
    elif [ -s "$OUTPUT" ]; then
        [ "$(cat "$PIDFILE" 2>/dev/null)" = "$BG_PID" ] && rm -f "$PIDFILE"
        say "Capture already finished - it completed (e.g. a short --duration elapsed) before this check could catch it still running. Saved to $OUTPUT."
        exit 0
    else
        [ "$(cat "$PIDFILE" 2>/dev/null)" = "$BG_PID" ] && rm -f "$PIDFILE"
        die "Capture exited immediately - check /tmp/pager-sniff.log (a bad --duration or --filter, or tcpdump failing to open '$IFACE', are the likely causes)."
    fi
    # Live credential watcher (see run_creds_watcher) - appends into the
    # SAME log the background capture already writes to, so a real hit
    # shows up right in whatever's tailing that file (including the LAN
    # Sniffer payload's on-device live scroller), not buried until the
    # capture eventually finishes.
    #
    # BUG FOUND AND FIXED (live-caught, see the matching fix in --stop
    # above): this used to launch with no PID captured at all, relying on
    # the watcher's own loop condition to notice the capture stopped -
    # confirmed live that it doesn't reliably do so, leaving the watcher
    # (and its periodic `tcpdump -A -r` re-scan) running well after
    # --stop had already reported "Stopped." Tracking its real PID here
    # (same proven pattern as the main capture just above) is what makes
    # --stop's direct kill of it actually work.
    ( run_creds_watcher "$OUTPUT" ) >>/tmp/pager-sniff.log 2>&1 &
    echo $! > "${PIDFILE}.watcher"
    # Live packet feed (see run_packet_feed) - the actual "spam packets
    # like Wireshark" view, same log, same PID-tracking discipline.
    ( run_packet_feed "$OUTPUT" ) >>/tmp/pager-sniff.log 2>&1 &
    echo $! > "${PIDFILE}.feed"
    exit 0
fi

say "Press Ctrl+C to stop (unless --count/--duration ends it first)."
( run_creds_watcher "$OUTPUT" ) &
CREDS_WATCHER_PID=$!
( run_packet_feed "$OUTPUT" ) &
PACKET_FEED_PID=$!
run_capture
CAP_RC=$?
kill "$CREDS_WATCHER_PID" 2>/dev/null
kill "$PACKET_FEED_PID" 2>/dev/null
# Same defense-in-depth as --stop above (see reap_orphaned_tcpdump_
# rescans()'s own header up near is_running()/kill_tracked_pid()) - a
# FOREGROUND run hits the identical two `kill`s just above, so it needs
# the identical orphan cleanup.
reap_orphaned_tcpdump_rescans

# BUG FOUND AND FIXED (CRITICAL - silent failure, verified with a standalone
# repro): run_capture's own exit status was never checked, and "Done. Saved
# to $OUTPUT" printed unconditionally right after it regardless of whether
# tcpdump ever actually captured anything - a bad --filter (invalid BPF
# syntax), the interface disappearing between the earlier check and launch,
# or a custom --output pointing at a directory that doesn't exist, all make
# tcpdump exit immediately without ever creating $OUTPUT, yet the script
# still claimed success. summarize_pcap's own `[ ! -s "$file" ]` guard
# happens to catch this and print an error - but ONLY when --no-summary is
# NOT given; with --no-summary (a documented, supported flag) there is
# nothing else downstream to catch it at all, so the ONLY output for a
# completely failed capture would be "Done. Saved to $OUTPUT" followed by
# "Full capture: tcpdump -r $OUTPUT..." - a clean, confident-looking success
# report for a capture that never happened. Reproduced standalone: a stub
# run_capture() that fails immediately, with NO_SUMMARY=1, printed exactly
# that misleading "Done. Saved"/"Full capture" pair with zero indication of
# failure. Now checks the same `-s` (exists and non-empty) signal
# summarize_pcap already uses - a genuinely successful capture always has at
# least tcpdump's own global pcap header written (nonzero size) even with
# zero packets caught, so this doesn't false-positive on a real "quiet
# network, nothing captured" run, only on tcpdump never getting the file
# open at all.
if [ -s "$OUTPUT" ]; then
    # BUG FOUND AND FIXED (MAJOR - traced directly to this pass's "what if
    # the USB-A adapter detaches mid-capture" question): the `-s "$OUTPUT"`
    # check right above (the previous fix, see its own comment) only proves
    # SOME file got saved - it can't tell a capture that ran its full
    # requested --duration/--count apart from one that died PARTWAY through
    # for an external reason and still printed the exact same unqualified
    # "Done. Saved to $OUTPUT". Concretely: a direct, non-bridged `--iface
    # eth1` capture with a USB-A adapter that gets physically unplugged
    # mid-capture - eth1's netdev is unregistered outright (a real USB
    # removal, not a carrier-down cable-pull), so tcpdump's read on it fails
    # and it exits well before reaching the requested --duration/--count,
    # yet whatever it had already written via -U (unbuffered, see that
    # flag's own comment above) is still a non-empty, "successful-looking"
    # .pcap. CAP_RC (captured immediately after run_capture, the direct,
    # non-piped command whose own exit status this is) tells the two cases
    # apart without needing to touch tcpdump/timeout's invocation at all:
    # exit 0 covers both "reached --count on its own" and a plain Ctrl+C
    # (tcpdump's documented SIGINT handling is to print final stats and
    # exit cleanly, not a raw kill), and exit 124 from `timeout` means
    # --duration's own deadline fired exactly as intended - both are
    # genuinely successful endings, not failures. Anything else means
    # tcpdump/timeout exited on its own, for some other reason, before
    # either of those - reasoned from tcpdump/timeout's documented exit
    # semantics per the static-analysis-only scope of this pass (no live
    # device available to reproduce an actual adapter unplug here), not
    # asserted as live-confirmed the way this file's other fixes are.
    if [ "$CAP_RC" != "0" ] && [ "$CAP_RC" != "124" ]; then
        if ! ip_link show "$IFACE" >/dev/null 2>&1; then
            err "Capture on '$IFACE' ended EARLY (tcpdump exit code $CAP_RC) - the interface itself disappeared mid-capture, most likely a USB adapter physically detaching. What was captured before that point is still saved below, but this is NOT the full capture that was requested."
        else
            err "Capture on '$IFACE' ended early/abnormally (tcpdump exit code $CAP_RC), not from reaching --duration/--count or a normal Ctrl+C. What was captured before that point is still saved below, but this may not be the full capture that was requested."
        fi
    fi
    say "Done. Saved to $OUTPUT"
else
    err "Capture produced no output at $OUTPUT - tcpdump likely never started (bad --filter syntax, '$IFACE' disappearing, or the --output directory not existing/writable). Nothing was captured."
fi
if [ "$NO_SUMMARY" != "1" ]; then
    summarize_pcap "$OUTPUT"
fi
[ -s "$OUTPUT" ] && say "Full capture: tcpdump -r $OUTPUT   or download it and open in Wireshark."

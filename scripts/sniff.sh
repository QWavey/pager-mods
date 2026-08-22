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
#   sniff.sh --bridge IFACE1 IFACE2       bridge two NICs into a transparent tap (br-sniff)
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
DO_BRIDGE=0; DO_UNBRIDGE=0; DO_LIST=0; DO_SUMMARY_ONLY=""; DO_STATUS=0; DO_STOP=0; DO_ADAPTERS=0
BR_IFACE1=""; BR_IFACE2=""

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
        --unbridge) DO_UNBRIDGE=1; shift ;;
        --list) DO_LIST=1; shift ;;
        --adapters) DO_ADAPTERS=1; shift ;;
        --summary) need_arg "--summary" "$#"; DO_SUMMARY_ONLY="$2"; shift 2 ;;
        --status) DO_STATUS=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

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

# Shared by summarize_pcap (end-of-capture scan) AND run_creds_watcher
# (live, DURING-capture scan) - one definition so the two can't drift.
# Covers HTTP Basic Auth, query-string logins, raw FTP/Telnet USER/PASS,
# JSON request-body password fields, and Authorization: Bearer tokens (a
# captured one is session hijacking, just as real a finding as a password).
CREDS_PATTERN='authorization: basic|authorization: bearer|(^|[?&])(pass|passwd|pwd|user|login|email)=|^USER |^PASS |"(pass|passwd|pwd|password)"[[:space:]]*:'

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
    NN_DUMP=$(tcpdump -nn -r "$file" 2>/dev/null)
    A_DUMP=$(tcpdump -A -r "$file" 2>/dev/null)
    # grep -c . (not `wc -l`) to count lines in an already-captured
    # variable: command substitution strips ALL trailing newlines, so
    # `echo "$var" | wc -l` would misreport an empty capture as 1 line
    # instead of 0. grep -c . counts only non-blank lines, which gives the
    # same answer as the original `tcpdump ... | wc -l` in both the empty
    # and non-empty case (same idiom already used by run_creds_watcher/
    # run_packet_feed elsewhere in this file for the same reason).
    total=$(echo "$NN_DUMP" | grep -c .)
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
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
    echo "$NN_DUMP" | awk '
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
        }' | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %6d  %s\n", $1, $2}'

    echo
    echo "  Protocols seen:"
    # tcpdump's default text output rarely contains the literal words "TCP"
    # or "DNS" - it shows "Flags [S]" for TCP and query markers like "A?"
    # for DNS instead. Classify by those actual markers (verified against
    # real tcpdump output samples), not by literal protocol-name grepping.
    echo "$NN_DUMP" | awk '
        /ARP,/ { print "ARP"; next }
        /ICMP/ { print "ICMP"; next }
        /Flags \[/ { print "TCP"; next }
        /[0-9]+\+? (A|AAAA|PTR|MX|TXT|CNAME|NS)\?/ { print "DNS"; next }
        /: UDP,/ { print "UDP"; next }
        /^[0-9:.]+ IP6? / { print "OTHER-IP"; next }
    ' | sort | uniq -c | sort -rn | awk '{printf "    %6d  %s\n", $1, $2}'

    echo
    echo "  HTTP Host headers seen (plaintext - real sites/services visited):"
    # IMPROVEMENT: DNS queries show intent to look something up; the HTTP
    # Host header shows an ACTUAL plaintext request going out to a real
    # site/service - a more direct piece of recon than DNS alone (also
    # catches direct-IP HTTP requests with no matching DNS query in this
    # capture window at all).
    host_hits=$(echo "$A_DUMP" | grep -oiE '^host: [^ ]+' | awk '{print $2}' | tr -d '\r')
    if [ -n "$host_hits" ]; then
        echo "$host_hits" | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %6d  %s\n", $1, $2}'
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
        echo "$dns_query_lines" | \
            grep -oE '(A|AAAA|PTR|MX|TXT|CNAME|NS)\? [^ ]+\.' | awk '{print $2}' | sed 's/\.$//' | \
            sort | uniq -c | sort -rn | head -10 | awk '{printf "    %6d  %s\n", $1, $2}'
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

# run_creds_watcher OUTPUT_FILE - INVENTED FEATURE: summarize_pcap only
# ever scanned for credentials/HTTP activity AFTER the whole capture
# finished - fine for a quick 30s capture, but for a long --background
# --duration run (or an unbounded one stopped hours later), real
# passwords or visited URLs sitting unseen in the .pcap for the entire
# remaining capture is an avoidable gap, and it's the opposite of the
# "watch it happen live, Wireshark-style" experience this was built for.
# This periodically (every 5s) re-scans the growing capture file and
# prints any NEW credential hit (red) or HTTP request/Host line the
# moment it's seen - live, into whatever the capture's own live output is
# (the terminal in the foreground case, /tmp/pager-sniff.log in the
# --background case, which is also what the LAN Sniffer payload's
# on-device live scroller already tails). Tracks each pattern's own seen-
# count separately so neither re-alerts the same match every cycle.
#
# MEASURED AND CHANGED: this used to be two separate functions (one for
# creds, one originally planned as a separate url-watcher) - each doing
# its OWN full `tcpdump -A -r file` re-read of the whole capture every
# cycle. Re-reading a growing file from the start twice per cycle instead
# of once doubles real CPU work for no benefit on a device that's already
# memory/CPU-constrained (251MB RAM total, confirmed live) - merged into
# one pass that checks both patterns from a SINGLE read per cycle.
run_creds_watcher() {
    local file="$1" last_creds=0 last_http=0 last_size=-1
    # is_running (PIDFILE-based) covers --background; for a foreground
    # run there's no PIDFILE, so fall back to "is the sniff.sh process
    # that launched me ($PPID, since this runs as its backgrounded child)
    # still alive" - true for the whole foreground capture, since that
    # process blocks on run_capture() until it finishes.
    while is_running || kill -0 "$PPID" 2>/dev/null; do
        sleep 5
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
        local dump creds_hits http_hits count new
        dump=$(tcpdump -A -r "$file" 2>/dev/null)
        [ -z "$dump" ] && continue

        creds_hits=$(echo "$dump" | grep -iE "$CREDS_PATTERN")
        if [ -n "$creds_hits" ]; then
            count=$(echo "$creds_hits" | grep -c .)
            if [ "$count" -gt "$last_creds" ]; then
                new=$(echo "$creds_hits" | tail -n "+$((last_creds + 1))")
                echo "$new" | GREP_COLORS='mt=1;31' grep --color=always -iE "$CREDS_PATTERN" | sed 's/^/[CREDS FOUND] /'
                last_creds="$count"
            fi
        fi

        http_hits=$(echo "$dump" | grep -iE "$HTTP_PATTERN")
        if [ -n "$http_hits" ]; then
            count=$(echo "$http_hits" | grep -c .)
            if [ "$count" -gt "$last_http" ]; then
                new=$(echo "$http_hits" | tail -n "+$((last_http + 1))")
                echo "$new" | sed 's/^/[HTTP] /'
                last_http="$count"
            fi
        fi
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
        sleep 2
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
        local lines count new
        lines=$(tcpdump -nn -r "$file" 2>/dev/null)
        [ -z "$lines" ] && continue
        count=$(echo "$lines" | grep -c .)
        if [ "$count" -gt "$last_count" ]; then
            new=$(echo "$lines" | tail -n "+$((last_count + 1))")
            echo "$new"
            last_count="$count"
        fi
    done
}

if [ -n "$DO_SUMMARY_ONLY" ]; then
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
# pid_running's optional NAME_PATTERN (see lib/common.sh) guards against a
# stale PIDFILE whose PID got reused by an unrelated process - the
# backgrounded capture is a subshell of THIS script, so its real
# /proc/PID/cmdline still shows "sniff.sh".
is_running() { pid_running "$PIDFILE" "sniff.sh"; }

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Capture running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
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
    if [ -f "${PIDFILE}.watcher" ]; then
        kill "$(cat "${PIDFILE}.watcher")" 2>/dev/null
        rm -f "${PIDFILE}.watcher"
    fi
    # Same PID-tracking fix, same reason, for run_packet_feed (the
    # separate 2s "live spammy view" cadence added alongside the
    # credential/HTTP watcher above).
    if [ -f "${PIDFILE}.feed" ]; then
        kill "$(cat "${PIDFILE}.feed")" 2>/dev/null
        rm -f "${PIDFILE}.feed"
    fi
    # Defense-in-depth: both watchers' periodic `tcpdump -r FILE`
    # re-scans are reached through a command-substitution subshell - if
    # the watcher's own PID gets killed WHILE a re-scan is mid-flight, the
    # default (no trap set) behavior is the parent dies immediately and
    # the child keeps running as an orphan, the same root cause as this
    # toolkit's very first orphan-process bug this session. Unlike that
    # fix, a blanket `killall tcpdump` isn't safe here - tracer.sh/
    # pc_link.sh/a manual capture could have a live `tcpdump -i ...`
    # running at the same time and this must not touch those. Match
    # specifically on "tcpdump ... -r" (a saved-file re-read - never how
    # any LIVE capture in this toolkit invokes tcpdump, which always uses
    # `-i IFACE -w FILE`) so only a genuinely orphaned re-scan gets caught,
    # covering both the "-A -r" (creds/HTTP) and "-nn -r" (packet feed) forms.
    for _pid in $(ps 2>/dev/null | grep -E 'tcpdump .* -r ' | grep -v grep | awk '{print $1}'); do
        kill "$_pid" 2>/dev/null
    done
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

start_lan_watchdog() {
    local _start_ts
    _start_ts=$(date +%s 2>/dev/null || echo 0)
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
            sleep 5
            # MAX_BRIDGE_SECS enforcement (see header above this function)
            # - checked BEFORE the normal per-cycle recovery check below,
            # so a bridge that's simply overstayed its welcome gets torn
            # down outright rather than kept alive by the very recovery
            # logic meant to protect a legitimately still-running session.
            if [ "$_deadline" -gt 0 ]; then
                _now=$(date +%s 2>/dev/null)
                case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
                if [ "$_now" -gt 0 ] && [ "$_now" -ge "$_deadline" ]; then
                    ip_link set "$BRIDGE_NAME" down 2>/dev/null
                    ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
                    ip_link set eth0 master br-lan 2>/dev/null
                    ip_link set eth0 up 2>/dev/null
                    echo "[sniff.sh watchdog] Bridge exceeded ${MAX_BRIDGE_SECS}s - automatically torn down, eth0 restored to br-lan (second safety net, independent of any EXIT trap)." >>/tmp/pager-sniff.log 2>/dev/null
                    rm -f "$BRIDGE_STARTED_FILE" "$WATCHDOG_PIDFILE"
                    exit 0
                fi
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
    if [ -f "$WATCHDOG_PIDFILE" ]; then
        kill "$(cat "$WATCHDOG_PIDFILE")" 2>/dev/null
        rm -f "$WATCHDOG_PIDFILE"
    fi
    rm -f "$BRIDGE_STARTED_FILE"
}

if [ "$DO_UNBRIDGE" = "1" ]; then
    stop_lan_watchdog
    if ! ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        say "No bridge ($BRIDGE_NAME) is up."
        exit 0
    fi
    ip_link set "$BRIDGE_NAME" down
    ip_link delete "$BRIDGE_NAME" type bridge
    # BUG FOUND AND FIXED (live-diagnosed, CRITICAL): deleting a bridge
    # detaches its former member interfaces but does NOT put them back
    # into any other bridge - eth0 was left completely masterless here,
    # not restored to br-lan. eth0 is br-lan's ONLY physical port on this
    # hardware, and br-lan is what SSH-over-USB-C access actually depends
    # on - every --unbridge was silently leaving the device unreachable
    # over that link until something else (the watchdog, or manual
    # recovery) happened to notice and fix it. The old "back to being
    # independent" message was also just wrong: eth0's normal home is
    # br-lan, not masterless. Restore it explicitly here instead of
    # hoping the watchdog (already stopped, one line up) catches it.
    #
    # BUG FOUND AND FIXED (live-caught): the delete call's own success was
    # never checked - confirmed live that it can transiently fail (a
    # netlink socket still settling right after a disruptive bridge
    # teardown), leaving $BRIDGE_NAME existing as an empty, orphaned
    # bridge device while this still unconditionally claimed "Bridge torn
    # down." eth0 restoration (the part that actually matters for SSH) is
    # unaffected either way, but the message should tell the truth about
    # the bridge device itself too. Short retry (same reasoning as
    # canonicalize_lan_topology's own) before reporting honestly.
    tries=0
    while [ "$tries" -lt 3 ] && ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -lt 3 ]; then
            sleep 1
            ip_link delete "$BRIDGE_NAME" type bridge 2>/dev/null
        fi
    done
    ip_link set eth0 master br-lan 2>/dev/null
    ip_link set eth0 up 2>/dev/null
    if ip_link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        err "eth0 restored to br-lan (management access is fine), but $BRIDGE_NAME itself could not be removed - it's left behind as an empty, harmless bridge device. Try 'sniff.sh --unbridge' again, or 'ip link delete $BRIDGE_NAME type bridge' by hand."
    else
        say "Bridge torn down. eth0 restored to br-lan (management access) - eth1 is independent again."
    fi
    exit 0
fi

if [ "$DO_BRIDGE" = "1" ]; then
    say "This bridges $BR_IFACE1 and $BR_IFACE2 into a transparent tap ($BRIDGE_NAME)."
    say "Traffic will actually flow through the Pager between whatever's on each end."
    check_adapters || err "Continuing anyway since you gave explicit interface names - but see the check above."
    confirm "Proceed?" || die "Aborted."

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
        say "$BRIDGE_NAME already exists - tearing it down first."
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

    ip_link add name "$BRIDGE_NAME" type bridge || die "Failed to create bridge (or the call timed out - network stack may be unresponsive; eth0 has been restored to br-lan)."
    ip_link set "$BR_IFACE1" master "$BRIDGE_NAME" || die "Failed to attach $BR_IFACE1 (or the call timed out; eth0 has been restored to br-lan)."
    ip_link set "$BR_IFACE2" master "$BRIDGE_NAME" || die "Failed to attach $BR_IFACE2 (or the call timed out; eth0 has been restored to br-lan)."
    ip_link set "$BR_IFACE1" up
    ip_link set "$BR_IFACE2" up
    ip_link set "$BRIDGE_NAME" up

    trap - EXIT

    say "Bridge $BRIDGE_NAME is up ($BR_IFACE1 <-> $BR_IFACE2)."
    say "Sniff everything passing through with: sniff.sh --iface $BRIDGE_NAME"
    say "Tear it down later with: sniff.sh --unbridge"
    start_lan_watchdog
    say "LAN watchdog running in the background - auto-recovers SSH/eth0-in-br-lan if the bridge ever leaves it disconnected."
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

if ! ip_link show "$IFACE" >/dev/null 2>&1; then
    die "Interface '$IFACE' does not exist. Use --list to see candidates, or --bridge to tap two NICs together."
fi

command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed on this device."

if [ "$BACKGROUND" = "1" ] && is_running; then
    die "A background capture is already running (PID $(cat "$PIDFILE")). Use --stop first."
fi

mkdir -p "$LOOT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo "sniff")
[ -z "$OUTPUT" ] && OUTPUT="$LOOT_DIR/sniff-${IFACE}-${STAMP}.pcap"

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
run_capture() {
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
    # No `nohup` on this busybox build - ignore SIGHUP in a subshell instead.
    ( trap '' HUP; run_capture_bg ) >/tmp/pager-sniff.log 2>&1 &
    echo $! > "$PIDFILE"
    # BUG FOUND AND FIXED (found via code review, same class as
    # PayloadRunner.sh's own fix): this used to print "Started (PID ...)"
    # unconditionally right after backgrounding, with no check the
    # capture actually survived - run_capture_bg's `exec` means a bad
    # --duration or any other immediate tcpdump/timeout failure replaces
    # the subshell with an already-dead process within a fraction of a
    # second, invisible to a check that doesn't wait and look. webui.sh
    # already does exactly this liveness check for its own background
    # launch - matching that here instead of assuming success.
    sleep 1
    if is_running; then
        say "Started (PID $(cat "$PIDFILE"))."
    else
        rm -f "$PIDFILE"
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
kill "$CREDS_WATCHER_PID" 2>/dev/null
kill "$PACKET_FEED_PID" 2>/dev/null
# BUG FOUND AND FIXED (found via code review): the --stop handler above
# already documents and defends against exactly this - killing a watcher
# subshell PID while it's mid-flight inside its own `tcpdump -A/-nn -r`
# command-substitution can orphan that re-scan (parent dies immediately,
# no trap, child reparented and keeps running) - but that defense-in-depth
# sweep only ran in the --background/--stop path. A FOREGROUND run hits
# the identical two `kill`s right above with no equivalent follow-up, so
# the same orphan risk existed here too, just via a code path the
# original fix didn't cover. Same targeted match as --stop (only
# "tcpdump ... -r ", never how a live capture's own `-i IFACE -w FILE`
# invocation looks) so a genuine tracer.sh/pc_link.sh capture running
# concurrently is never touched.
for _pid in $(ps 2>/dev/null | grep -E 'tcpdump .* -r ' | grep -v grep | awk '{print $1}'); do
    kill "$_pid" 2>/dev/null
done

say "Done. Saved to $OUTPUT"
if [ "$NO_SUMMARY" != "1" ]; then
    summarize_pcap "$OUTPUT"
fi
say "Full capture: tcpdump -r $OUTPUT   or download it and open in Wireshark."

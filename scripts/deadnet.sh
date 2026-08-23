#!/bin/bash
# deadnet.sh - Disconnect devices on the wired LAN via ARP-cache poisoning +
# IPv6 dead-router spoofing (powered by deadnet, trimmed down from
# https://github.com/flashnuke/deadnet - just the ~30KB core tool, not its
# unrelated 71MB bundled Android app). For when you're ALREADY ON the
# network - different tool/trust model than deauth.sh, which is for WiFi
# clients you're NOT connected to.
#
# This is the ONE place that actually runs deadnet - the deadnet_lan_kill
# payload and the GUI both call this same script with the same arguments,
# so behavior is identical no matter how you launch it.
#
# Runs continuously until you press Ctrl+C - it does not stop on its own.
# If started in the background (GUI/PayloadRunner --background), use
# `deadnet.sh --stop` instead.
#
# IMPORTANT: only run this against a network you are authorized to test.
#
# Usage:
#   deadnet.sh [--iface eth1] [--gateway IP] [--gateway-mac MAC] [--sleep SECONDS]
#   deadnet.sh --discover [--iface eth1]      just scan and list live hosts, don't attack
#   deadnet.sh --background                     run detached - use --stop to end it
#   deadnet.sh --stop
#   deadnet.sh --status
#   deadnet.sh                interactive mode
#
# Options:
#   --iface IFACE       Wired interface to attack from (default: eth1)
#   --gateway IP          Gateway IPv4 (default: auto-detected, x.x.x.1)
#   --gateway-mac MAC       Gateway MAC (default: auto-detected via ARP)
#   --sleep SECONDS           Re-poison interval (default: 5)
#   --cidr N                    Subnet size to attack (default: 24)
#   --disable-ipv6                 Skip the IPv6 dead-router-advertisement attack
#   --no-discover                    Skip the pre-attack host discovery scan
#   --discover                         Only discover live hosts, don't attack
#   --background                         Run detached - see --stop/--status.
#                                            Output still goes to /tmp/pager-deadnet.log.
#   --stop                                Stop a run that was started in the background
#   --status                                Is a LAN kill currently running?
#   -y, --yes                                Skip the authorization confirmation
#   -h, --help                                 This help
#
# BUG FOUND AND FIXED (this file was previously excluded from bug-hunt/
# improve passes as "good enough" - re-scoped in per user request): this
# file's own header comment above used to say "If started in the
# background (GUI/PayloadRunner --background), use `deadnet.sh --stop`
# instead" - but no --background flag existed anywhere in the argument
# parser. The deadnet_lan_kill payload worked around this by backgrounding
# externally with a plain `&`, with no PIDFILE, no liveness check, and no
# single-instance protection - the exact "black box, no feedback,
# possible-double-launch" class of gap this toolkit's every OTHER
# background-capable script (deauth.sh/sniff.sh/bluetooth.sh/tracer.sh/
# EvilTwin.sh) already fixed for itself. Brought in line with that same
# established PIDFILE + pid_running() + liveness-check pattern.
#
# Host discovery: before attacking, this scans the subnet with nmap (a
# quick ping sweep) and shows you exactly which real, live hosts are on
# the LAN and about to be affected - not just "the whole subnet" as an
# abstraction. The underlying deadnet attack still covers the full
# subnet (that's how ARP poisoning works - you can't be selective about
# who receives poisoned ARP replies without a different attack entirely),
# but you now get told upfront who's actually there before you commit,
# and the discovered host list is saved to loot alongside the run.

set -u
TOOL_NAME="deadnet.sh"
LOOT_DIR="/root/loot/deadnet"
PIDFILE="/tmp/pager-deadnet.pid"
LOGFILE="/tmp/pager-deadnet.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

IFACE="eth1"; GATEWAY=""; GATEWAY_MAC=""; SLEEP_TIME="5"; CIDR="24"; DISABLE_IPV6=0
DO_STOP=0; DO_STATUS=0; DO_DISCOVER_ONLY=0; NO_DISCOVER=0; BACKGROUND=0

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) need_arg "--iface" "$#"; IFACE="$2"; shift 2 ;;
        --gateway) need_arg "--gateway" "$#"; GATEWAY="$2"; shift 2 ;;
        --gateway-mac) need_arg "--gateway-mac" "$#"; GATEWAY_MAC="$2"; shift 2 ;;
        --sleep) need_arg "--sleep" "$#"; SLEEP_TIME="$2"; shift 2 ;;
        --cidr) need_arg "--cidr" "$#"; CIDR="$2"; shift 2 ;;
        --disable-ipv6) DISABLE_IPV6=1; shift ;;
        --no-discover) NO_DISCOVER=1; shift ;;
        --discover) DO_DISCOVER_ONLY=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BIG CHANGE (adopting common.sh's shared primitive, same class already
# fixed this session for deauth.sh/sniff.sh/bluetooth.sh/usb_monitor.sh/
# crash_logger.sh/webui.sh/PayloadRunner.sh): the old is_running() here
# scanned `ps` for "deadnet.py" by NAME - the exact fragile
# self-identification approach deauth.sh's own extensive live-diagnosed
# history documents moving away from (multiple false matches, no way to
# tell "my own tracked instance" from "some other deadnet.py process"). A
# real PIDFILE, backed by the shared pid_running() (with its own
# /proc/PID/cmdline NAME_PATTERN check against PID reuse), is the same
# proven pattern every other backgroundable script in this toolkit uses.
# "deadnet.py" is still the right NAME_PATTERN either way (foreground:
# this script `exec`s straight into python3 running deadnet.py, replacing
# its own process image the same way webui.sh execs into server.py;
# background: same exec, just launched detached first).
is_running() { pid_running "$PIDFILE" "deadnet.py"; }

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
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
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
    exit 0
fi

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# EvilTwin.sh/LanScan.sh/tracer.sh this session): use the shared
# timeout-protected ip_link() wrapper instead of a raw, unbounded
# `ip link show`.
#
# BUG FOUND AND FIXED (found via code review, same class as
# is_wifi_connected()/connected_bssid() in lib/common.sh - see that file's
# own header comment for the live-reproduced incident: a plain `ip`/`iw`
# netlink call wedging indefinitely on a confused netlink socket after a
# topology change, taking SSH-over-USB-C management down with it): the
# second half of this check, `ip -4 addr show "$IFACE"`, was a raw,
# unbounded netlink call - the exact call-shape common.sh's own
# IP_LINK_TIMEOUT guard exists to bound, just not routed through it here.
# Wrapped with the same shared timeout so a wedged socket makes this check
# fail fast instead of hanging the whole script (including --discover and
# the pre-attack confirmation prompt, both of which call this first).
lan_available() { ip_link show "$IFACE" >/dev/null 2>&1 && timeout "$IP_LINK_TIMEOUT" ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet "; }

get_subnet() {
    # Reuses the same portable, python3-free CIDR math as LanScan.sh.
    #
    # BUG FOUND AND FIXED (same class as lan_available() above): another
    # raw, unbounded `ip ... addr show` call - get_subnet() feeds
    # discover_hosts() (the pre-attack host scan) and is on the hot path
    # for every non---discover run too, so a wedge here would hang before
    # the attack even starts, with no timeout anywhere in the call chain to
    # recover. Bounded with the same shared IP_LINK_TIMEOUT.
    local cidr ip_addr prefix
    cidr=$(timeout "$IP_LINK_TIMEOUT" ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    [ -z "$cidr" ] && return 1
    ip_addr="${cidr%/*}"
    prefix="${cidr#*/}"
    case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
    awk -v ip="$ip_addr" -v prefix="$prefix" 'BEGIN{
        n = split(ip, o, ".");
        if (n != 4) exit 1;
        ipnum = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4];
        hostbits = 32 - prefix;
        blocksize = 1;
        for (i = 0; i < hostbits; i++) blocksize = blocksize * 2;
        netnum = int(ipnum / blocksize) * blocksize;
        printf "%d.%d.%d.%d/%d\n", int(netnum/16777216)%256, int(netnum/65536)%256, int(netnum/256)%256, netnum%256, prefix;
    }'
}

discover_hosts() {
    # Quick ping-sweep host discovery. Prints "IP MAC Vendor" lines and
    # returns the live host count via echo count on the last line prefixed
    # with "COUNT:" for the caller to parse, OR just prints for humans when
    # called directly with --discover.
    local subnet
    subnet=$(get_subnet)
    if [ -z "$subnet" ]; then
        err "Could not determine the subnet on $IFACE (no IPv4 address yet)."
        return 1
    fi

    if ! command -v nmap >/dev/null 2>&1; then
        err "nmap not found - skipping host discovery, will attack the whole subnet blind."
        return 1
    fi

    say "Discovering live hosts on $subnet (quick ping sweep)..."
    mkdir -p "$LOOT_DIR"
    local stamp rawfile outfile
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo scan)
    rawfile="$LOOT_DIR/discovery-${stamp}-raw.txt"
    outfile="$LOOT_DIR/discovery-${stamp}.txt"

    # Normal (non-grepable) nmap output reliably includes "MAC Address:"
    # lines when it can ARP-resolve one - grepable (-oG) output does not,
    # so parse the normal format instead (same pattern already proven to
    # work against this device's nmap in LanScan.sh). Single pass, flush
    # the previous host's record whenever a new one starts (and at EOF) -
    # easy to verify correct: exactly one line out per host seen, whether
    # or not its MAC resolved.
    nmap -sn -e "$IFACE" "$subnet" > "$rawfile" 2>/dev/null

    awk '
        /^Nmap scan report for/ {
            if (ip != "") print ip "\t" mac
            ip = $NF
            gsub(/[()]/, "", ip)
            mac = "(no MAC resolved)"
            next
        }
        /^MAC Address:/ {
            mac = $3
            for (i = 4; i <= NF; i++) mac = mac " " $i
            next
        }
        END { if (ip != "") print ip "\t" mac }
    ' "$rawfile" > "$outfile"

    local count
    count=$(wc -l < "$outfile" | tr -d ' ')

    if [ "$count" -gt 0 ]; then
        say "Found $count live host(s):"
        cat "$outfile"
    else
        say "No live hosts found (or the scan format changed - see $outfile)."
    fi
    say "Saved to $outfile"
    return 0
}

if [ "$DO_DISCOVER_ONLY" = "1" ]; then
    if ! lan_available; then
        die "$IFACE doesn't look up with an IP - nothing to discover."
    fi
    discover_hosts
    exit 0
fi

deadnet_dir="$SCRIPT_DIR/lib/deadnet"
[ ! -f "$deadnet_dir/deadnet.py" ] && die "deadnet not found at $deadnet_dir - run the toolkit setup.py first."

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# clientip.sh/examine.sh/openap.sh/EvilTwin.sh this session): a typo'd
# --gateway-mac was passed straight through to deadnet.py with no format
# check - it would surface as a cryptic Python-level error/traceback
# instead of this toolkit's usual clear, immediate reason.
[ -n "$GATEWAY_MAC" ] && { is_valid_mac "$GATEWAY_MAC" || die "'$GATEWAY_MAC' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."; }

# BUG FOUND AND FIXED (found via code review, same class already fixed for
# --duration/--interval/--burst/etc. throughout this toolkit this session):
# --sleep and --cidr were handed straight to deadnet.py's -s/-m with no
# numeric check at all - a typo'd value would surface as a Python-level
# error instead of this toolkit's usual clear, immediate reason.
#
# BUG FOUND AND FIXED (found via code review, caught right after adding
# the check above): deadnet.py's own argparser (scripts/lib/deadnet/utils/
# argparser.py) declares -s/--sleep-interval as `type=int` - a decimal
# like "5.5" would pass a bluetooth.sh-style "plain number" check but then
# get REJECTED by argparse itself ("invalid int value"), the exact
# confusing Python-level error this validation exists to prevent in the
# first place. Whole numbers only, matching what -s actually accepts.
case "$SLEEP_TIME" in ''|*[!0-9]*) die "'--sleep' needs a whole number of seconds (got '$SLEEP_TIME')." ;; esac
case "$CIDR" in ''|*[!0-9]*) die "'--cidr' needs a whole number (got '$CIDR')." ;; esac
[ "$CIDR" -ge 0 ] && [ "$CIDR" -le 32 ] || die "'--cidr' must be between 0 and 32 (got '$CIDR')."

# BUG FOUND AND FIXED (same class as the is_running() rewrite above): no
# single-instance protection existed at all - unlike every other attack/
# capture script in this toolkit (deauth.sh/sniff.sh/bluetooth.sh all
# refuse a second concurrent launch), nothing stopped two deadnet.py
# instances fighting over the same ARP tables/interface simultaneously.
is_running && die "Already running (PID $(cat "$PIDFILE")). Use --stop first."

INTERACTIVE=0
[ "$ASSUME_YES" != "1" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== deadnet.sh =="
fi

if ! lan_available; then
    err "$IFACE doesn't look up with an IP yet - this will likely fail. Continuing anyway."
elif [ "$NO_DISCOVER" != "1" ]; then
    discover_hosts || true
    echo
fi

if [ "$ASSUME_YES" != "1" ]; then
    say "This ARP-poisons the WHOLE LAN on $IFACE and runs until you press Ctrl+C (or --stop, if backgrounded)."
    confirm "Only run this against a network you're authorized to test. Proceed?" || die "Aborted."
fi

py_args=(-i "$IFACE" -m "$CIDR" -s "$SLEEP_TIME")
[ -n "$GATEWAY" ] && py_args+=(-g "$GATEWAY")
[ -n "$GATEWAY_MAC" ] && py_args+=(-M "$GATEWAY_MAC")
[ "$DISABLE_IPV6" = "1" ] && py_args+=(-6)

PY=$(resolve_python3) || die "python3 is not installed. Run: opkg update && opkg install -d mmc python3"

# BIG CHANGE: real --background support (see the header comment on this
# file's own past claim that it already had this). Writes its PID via
# $BASHPID from INSIDE the subshell, right before exec - the same PID
# either way (exec replaces the process image in place, it doesn't fork),
# so is_running()'s shared pid_running() check works identically whether
# this ends up backgrounded or not.
if [ "$BACKGROUND" = "1" ]; then
    # shellcheck disable=SC2086
    ( trap '' HUP; cd "$deadnet_dir" && echo "$BASHPID" > "$PIDFILE" && exec $PY deadnet.py "${py_args[@]}" ) >"$LOGFILE" 2>&1 &
    # BUG FOUND AND FIXED (same class already fixed this session in
    # deauth.sh/sniff.sh/bluetooth.sh/tracer.sh/PayloadRunner.sh/webui.sh):
    # verify the launch actually survived before claiming success - a
    # missing scapy/python3 install, or a bad --gateway/--iface, can make
    # deadnet.py exit almost instantly.
    sleep 1
    if is_running; then
        say "Started in background (PID $(cat "$PIDFILE")). Use --stop to end it. Output: $LOGFILE"
    else
        rm -f "$PIDFILE"
        die "Failed to start - check $LOGFILE (missing python3/scapy, or a bad --gateway/--iface, are the likely causes)."
    fi
else
    say "Starting (Ctrl+C to stop)..."
    # shellcheck disable=SC2086
    (cd "$deadnet_dir" && echo "$BASHPID" > "$PIDFILE" && exec $PY deadnet.py "${py_args[@]}")
fi

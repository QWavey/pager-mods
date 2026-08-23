#!/bin/bash
# walledgarden.sh - DNS walled-garden redirect (approved idea U2).
#
# THE IDEA: a host is tethered to the Pager over USB-C (eth0, on br-lan, where
# the Pager is already its DHCP server AND its DNS server). Run a resolver that
# answers EVERY name lookup with ONE allowed address and blocks everything
# else - a captive walled garden. The tethered host can only reach the single
# page you allow; every other site resolves to it too (or to a dead end).
#
# Mechanism: a dedicated dnsmasq instance bound to the br-lan address with a
# wildcard `address=/#/<IP>` (every domain -> the allowed IP). Optionally, an
# nftables rule set drops the host's direct-to-IP traffic so it can't bypass
# DNS by dialing raw addresses - only the allowed IP (and the Pager itself)
# stays reachable.
#
# Usage:
#   walledgarden.sh --on  [--ip 172.16.52.1] [--iface br-lan] [--lock]
#   walledgarden.sh --off
#   walledgarden.sh --status
#
# --ip     the single address every lookup resolves to (default: the Pager,
#          172.16.52.1 - serve your own page there with a webserver).
# --iface  interface the tethered host is on (default br-lan / eth0's bridge).
# --lock   also add nft rules blocking direct-IP egress (harder garden).
#
# Only on hosts/networks you are authorized to control.

set -u
TOOL_NAME="walledgarden.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

RUN="/tmp/pager-walledgarden"
DCONF="$RUN/dnsmasq.conf"
DPID="$RUN/dnsmasq.pid"
NFT_TABLE="pager_wg"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

MODE=""; ALLOW_IP="172.16.52.1"; IFACE="br-lan"; LOCK=0
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --on) MODE="on"; shift ;;
        --off) MODE="off"; shift ;;
        --status) MODE="status"; shift ;;
        --ip) ALLOW_IP="${2:-}"; shift 2 ;;
        --iface) IFACE="${2:-br-lan}"; shift 2 ;;
        --lock) LOCK=1; shift ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage
echo "$ALLOW_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "--ip must be a dotted IPv4 address."

do_on() {
    command -v dnsmasq >/dev/null 2>&1 || die "dnsmasq not found."
    mkdir -p "$RUN"
    # Wildcard: every domain resolves to the one allowed IP. Bind to the
    # host-facing interface only, on an alt port is NOT used - we take :53 on
    # that iface. The Pager's own resolver keeps serving the Pager itself.
    cat > "$DCONF" <<EOF
# pager walled-garden - all names -> $ALLOW_IP
no-resolv
no-hosts
interface=$IFACE
bind-interfaces
address=/#/$ALLOW_IP
EOF
    # stop any previous instance of ours
    [ -f "$DPID" ] && kill "$(cat "$DPID" 2>/dev/null)" 2>/dev/null
    dnsmasq -C "$DCONF" -x "$DPID" 2>"$RUN/dnsmasq.err" || die "dnsmasq failed to start (port 53 on $IFACE may be busy) - see $RUN/dnsmasq.err."
    say "Walled garden UP on $IFACE - every DNS lookup -> $ALLOW_IP."
    if [ "$LOCK" = "1" ] && command -v nft >/dev/null 2>&1; then
        nft add table inet "$NFT_TABLE" 2>/dev/null
        nft add chain inet "$NFT_TABLE" fwd '{ type filter hook forward priority 0; }' 2>/dev/null
        # allow the tethered host to reach only the allowed IP and the Pager;
        # drop the rest of its forwarded traffic (direct-IP bypass).
        nft add rule inet "$NFT_TABLE" fwd iifname "$IFACE" ip daddr "$ALLOW_IP" accept 2>/dev/null
        nft add rule inet "$NFT_TABLE" fwd iifname "$IFACE" ip daddr 172.16.52.0/24 accept 2>/dev/null
        nft add rule inet "$NFT_TABLE" fwd iifname "$IFACE" drop 2>/dev/null
        say "Lock ON - direct-IP egress from $IFACE is blocked (only $ALLOW_IP reachable)."
    fi
    say "Serve your page at http://$ALLOW_IP/ (e.g. via the toolkit web GUI)."
}

do_off() {
    [ -f "$DPID" ] && { kill "$(cat "$DPID" 2>/dev/null)" 2>/dev/null; rm -f "$DPID"; }
    command -v nft >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" 2>/dev/null
    say "Walled garden OFF - normal DNS/egress restored."
}

do_status() {
    if [ -f "$DPID" ] && kill -0 "$(cat "$DPID" 2>/dev/null)" 2>/dev/null; then
        say "Walled garden ACTIVE (dnsmasq PID $(cat "$DPID")). Config: $DCONF"
    else
        say "Not active."
    fi
    command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && say "Lock rules present (nft table $NFT_TABLE)."
}

case "$MODE" in
    on) do_on ;;
    off) do_off ;;
    status) do_status ;;
esac

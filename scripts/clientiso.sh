#!/bin/bash
# clientiso.sh - client-isolation tester (approved idea W8). From wherever the
# Pager sits on a network (the wired eth1 adapter, or connected to WiFi as a
# client), it answers one question: can connected clients reach EACH OTHER, or
# only the gateway? Guest/corp WLANs are supposed to isolate clients from one
# another (AP/client isolation); very often they don't, which is an easy
# lateral-movement win.
#
# Method: discover live hosts on the local subnet, identify the gateway, then
# actively probe reachability to the NON-gateway hosts (ping + a couple of
# common TCP ports). Any non-gateway host that answers = isolation is OFF.
#
# Usage:
#   clientiso.sh [--iface eth1] [--subnet CIDR]
#
# IMPORTANT: only on networks you own or are explicitly authorized to test.

set -u
TOOL_NAME="clientiso.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
export PATH="$PATH:/mmc/usr/bin:/mmc/usr/sbin"

IFACE="eth1"; SUBNET=""
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="${2:-}"; shift 2 ;;
        --subnet) SUBNET="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
command -v nmap >/dev/null 2>&1 || die "nmap not found."
[ -e "/sys/class/net/$IFACE" ] || die "Interface $IFACE not present."

LOOT_DIR="/root/loot/clientiso"; mkdir -p "$LOOT_DIR" 2>/dev/null
OUT="$LOOT_DIR/clientiso-$(date +%Y%m%d-%H%M%S).txt"

net="$SUBNET"; [ -z "$net" ] && net=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -n "$net" ] || die "No IPv4 subnet on $IFACE (link down / no lease?). Pass --subnet CIDR."
gw=$(ip route show dev "$IFACE" 2>/dev/null | awk '/default/{print $3; exit}')
[ -z "$gw" ] && gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
myip=$(echo "$net" | cut -d/ -f1)

say "Discovering hosts on $net ($IFACE); gateway=$gw, me=$myip ..."
hosts=$(nmap -sn -e "$IFACE" "$net" -oG - 2>/dev/null | awk '/Status: Up/{print $2}' | sort -u)
{
    echo "client-isolation test on $IFACE ($net)"
    echo "gateway: $gw   self: $myip"
    echo "-----------------------------------------------"
} | tee "$OUT"

reachable=0; total=0
for h in $hosts; do
    [ "$h" = "$gw" ] && continue
    [ "$h" = "$myip" ] && continue
    total=$((total+1))
    # ping + a couple of common TCP ports; any response = we can reach a peer
    if ping -c1 -W1 -I "$IFACE" "$h" >/dev/null 2>&1; then
        echo "[+] $h reachable (ICMP) - isolation OFF" | tee -a "$OUT"; reachable=$((reachable+1)); continue
    fi
    if nmap -Pn -p 135,139,445,80,22 --host-timeout 8s -e "$IFACE" "$h" 2>/dev/null | grep -q "open"; then
        echo "[+] $h reachable (TCP) - isolation OFF" | tee -a "$OUT"; reachable=$((reachable+1))
    else
        echo "[-] $h no response (isolated or firewalled)" | tee -a "$OUT"
    fi
done

echo "-----------------------------------------------" | tee -a "$OUT"
if [ "$total" -eq 0 ]; then
    say "No non-gateway peers discovered - can't judge isolation (only the gateway is visible)."
elif [ "$reachable" -gt 0 ]; then
    say "RESULT: client isolation is OFF - reached $reachable/$total peer(s). Lateral movement possible."
else
    say "RESULT: client isolation appears ON - no peer answered ($total tried)."
fi
say "Saved: $OUT"

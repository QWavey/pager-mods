#!/bin/bash
# topomap.sh - network topology mapper (approved idea U4).
#
# THE IDEA: from a drop point on a LAN (the USB-A adapter, eth1, plugged into
# a wall port / switch), map what's above us: LAN -> switch -> router, or
# LAN -> wifi-router / repeater -> gateway. Tell a plain switch apart from a
# repeater apart from the gateway, and draw the tree.
#
# How it decides (evidence, not a single guess):
#   - LLDP / CDP frames (passive tcpdump): switches and APs announce their
#     name, model and port here - the strongest single signal, naming the
#     device one hop up directly.
#   - default gateway + its MAC vendor (OUI) + TTL of its replies: identifies
#     the router and hints at its OS/vendor.
#   - traceroute upward: a plain switch adds NO L3 hop; a router/gateway adds
#     one; a double-NAT repeater/second router adds two.
#   - ARP/neighbour sweep: everything else on our L2 segment.
#
# Usage:
#   topomap.sh [--iface eth1] [--seconds 20]
#
# Passive + light active probing only. Authorized networks.

set -u
TOOL_NAME="topomap.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

LOOT_DIR="/root/loot/topomap"
IFACE="eth1"; SECONDS_ARG="20"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="${2:-eth1}"; shift 2 ;;
        --seconds) SECONDS_ARG="${2:-20}"; shift 2 ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
case "$SECONDS_ARG" in ''|*[!0-9]*) die "--seconds must be numeric." ;; esac
[ -e "/sys/class/net/$IFACE" ] || die "Interface $IFACE not present (plug in the LAN adapter)."
mkdir -p "$LOOT_DIR" 2>/dev/null
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOOT_DIR/topo-$STAMP.txt"

# our own addressing on the drop iface
MYIP=$(timeout "${IP_LINK_TIMEOUT:-5}" ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
GW=$(timeout "${IP_LINK_TIMEOUT:-5}" ip route show dev "$IFACE" 2>/dev/null | awk '/^default/{print $3; exit}')
[ -z "$GW" ] && GW=$(timeout "${IP_LINK_TIMEOUT:-5}" ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')

say "Mapping from $IFACE (${MYIP:-no IP}) - listening ${SECONDS_ARG}s for LLDP/CDP + probing upward..."
{
    echo "topomap - $STAMP"
    echo "drop iface : $IFACE   our addr: ${MYIP:-none}   gateway: ${GW:-unknown}"
    echo "======================================================================"
} > "$OUT"

# 1) passive LLDP/CDP - the device one hop up usually names itself here
LLDP="$LOOT_DIR/lldp-$STAMP.txt"
if command -v tcpdump >/dev/null 2>&1; then
    # LLDP ethertype 0x88cc; CDP is SNAP/LLC to 01:00:0c:cc:cc:cc
    timeout "$SECONDS_ARG" tcpdump -i "$IFACE" -nn -s 0 -v \
        '(ether proto 0x88cc) or (ether host 01:00:0c:cc:cc:cc)' \
        > "$LLDP" 2>/dev/null
    if [ -s "$LLDP" ]; then
        echo "-- Neighbour (LLDP/CDP) - the device on our port --" >> "$OUT"
        grep -iE "System Name|Port Desc|Port ID|Device-?ID|Platform|Capab|VLAN|Management Address" "$LLDP" | sed 's/^ */  /' | sort -u >> "$OUT"
    else
        echo "-- No LLDP/CDP heard (dumb/unmanaged switch, or it's filtered) --" >> "$OUT"
    fi
fi
echo >> "$OUT"

# 2) the gateway: MAC + vendor OUI + TTL
if [ -n "$GW" ]; then
    timeout 5 ping -c 2 -W 2 "$GW" >/dev/null 2>&1
    GW_MAC=$(timeout "${IP_LINK_TIMEOUT:-5}" ip neigh show "$GW" dev "$IFACE" 2>/dev/null | awk '{print $5; exit}')
    [ -z "$GW_MAC" ] && GW_MAC=$(timeout "${IP_LINK_TIMEOUT:-5}" ip neigh show "$GW" 2>/dev/null | awk '{print $5; exit}')
    GW_TTL=$(timeout 5 ping -c 1 -W 2 "$GW" 2>/dev/null | grep -oiE "ttl=[0-9]+" | head -1)
    OUI=""
    [ -n "$GW_MAC" ] && OUI=$(echo "$GW_MAC" | tr 'A-F' 'a-f' | cut -d: -f1-3)
    {
        echo "-- Gateway / router --"
        echo "  IP   : $GW"
        echo "  MAC  : ${GW_MAC:-unknown}${OUI:+  (OUI $OUI)}"
        echo "  $GW_TTL  (TTL ~64 Linux/router, ~128 Windows, ~255 network gear)"
    } >> "$OUT"
fi
echo >> "$OUT"

# 3) hop count upward - distinguishes switch (0 L3 hops to GW) vs router chain
HOPS="?"
if command -v traceroute >/dev/null 2>&1; then
    echo "-- Path upward (traceroute to 8.8.8.8, max 8 hops) --" >> "$OUT"
    timeout 30 traceroute -n -m 8 -w 2 8.8.8.8 2>/dev/null | tee -a "$OUT" >/dev/null
    HOPS=$(timeout 30 traceroute -n -m 8 -w 2 8.8.8.8 2>/dev/null | grep -cE '^[[:space:]]*[0-9]+')
fi
echo >> "$OUT"

# 4) neighbours on our L2 segment
{
    echo "-- Others on our L2 segment (ARP/neighbour table) --"
    timeout "${IP_LINK_TIMEOUT:-5}" ip neigh show dev "$IFACE" 2>/dev/null | awk '$1 ~ /\./ {printf "  %-16s %s\n", $1, $5}' | sort -u
} >> "$OUT"
echo >> "$OUT"

# 5) verdict + tree
{
    echo "-- Verdict --"
    if grep -qiE "System Name|Device-?ID" "$LLDP" 2>/dev/null; then
        _up=$(grep -iE "System Name|Device-?ID" "$LLDP" 2>/dev/null | head -1 | sed -E 's/.*(System Name|Device-?ID)[: ]*//I')
        echo "  One hop up is a MANAGED switch/AP that named itself: ${_up:-<see LLDP>}"
    else
        echo "  One hop up is an unmanaged switch or a filtering port (no LLDP/CDP)."
    fi
    case "$HOPS" in
        ''|0|1) echo "  ~1 L3 hop to the internet: the gateway IS the edge router (LAN -> switch -> router)." ;;
        2)      echo "  2 L3 hops: likely a repeater/second router in front of the real gateway (double-NAT)." ;;
        *)      echo "  $HOPS L3 hops out: a deeper routed path (LAN -> ... -> gateway)." ;;
    esac
    echo
    echo "  drop($IFACE ${MYIP:-?})"
    echo "     |"
    echo "     +-- switch/AP  $(grep -iE 'System Name|Device-?ID' "$LLDP" 2>/dev/null | head -1 | sed -E 's/.*(System Name|Device-?ID)[: ]*//I' | tr -d '\n')"
    echo "           |"
    echo "           +-- gateway ${GW:-?}  ${GW_MAC:+[$GW_MAC]}"
    echo "                 |"
    echo "                 +-- internet (${HOPS} L3 hops)"
} >> "$OUT"

cat "$OUT"
say "Topology written: $OUT"

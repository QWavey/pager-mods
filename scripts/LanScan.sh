#!/bin/bash
#
# LanScan.sh - LAN scanner for the WiFi Pineapple Pager's Ethernet/USB-C
#              interface (eth1), using the pre-installed nmap.
#
# The Pager has no dedicated "LAN scan" Pineapple command - this wraps the
# standard, already-installed `nmap` (see External Packages docs) against
# whatever subnet eth1 is on, once you've plugged a USB-C-to-Ethernet
# adapter into the Pager and the other end into a router/switch.
#
# Usage:
#   LanScan.sh                                interactive mode
#   LanScan.sh --mode quick [options]
#
# Options:
#   --iface IFACE          Interface to scan from (default: eth1)
#   --subnet CIDR          Target subnet, e.g. 192.168.1.0/24 (default: auto-detect from iface)
#   --mode MODE             ping | quick | full | service | vuln | custom  (default: quick)
#   --ports SPEC             Port spec for --mode custom, e.g. 22,80,443 or 1-1000
#   --extra-args "ARGS"       Extra raw nmap arguments (advanced)
#   --output FILE             Save results to a specific file (default: timestamped under /root/loot/lanscan/)
#   -y, --yes                 Don't prompt for confirmation
#   -h, --help                 This help
#
# Modes:
#   ping     - nmap -sn            host discovery only, fastest
#   quick    - nmap -T4 -F         top 100 ports on live hosts
#   full     - nmap -T4 -p-        all 65535 ports
#   service  - nmap -sV -T4        service/version detection
#   vuln     - nmap --script vuln  NSE vulnerability scripts (if available)
#   custom   - nmap with --ports / --extra-args as given

set -u
TOOL_NAME="LanScan.sh"
LOOT_DIR="/root/loot/lanscan"
CFG_NS="lanscan"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

IFACE="eth1"
SUBNET=""
MODE=""
PORTS=""
EXTRA_ARGS=""
OUTPUT=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) [ $# -lt 2 ] && die "--iface needs a value"; IFACE="$2"; shift 2 ;;
        --subnet) [ $# -lt 2 ] && die "--subnet needs a value"; SUBNET="$2"; shift 2 ;;
        --mode) [ $# -lt 2 ] && die "--mode needs a value"; MODE="$2"; shift 2 ;;
        --ports) [ $# -lt 2 ] && die "--ports needs a value"; PORTS="$2"; shift 2 ;;
        --extra-args) [ $# -lt 2 ] && die "--extra-args needs a value"; EXTRA_ARGS="$2"; shift 2 ;;
        --output) [ $# -lt 2 ] && die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

INTERACTIVE=0
[ -z "$MODE" ] && INTERACTIVE=1

if ! command -v nmap >/dev/null 2>&1; then
    die "nmap is not installed. Install it with: opkg update && opkg install -d mmc nmap"
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    die "Interface '$IFACE' does not exist. Plug in the USB-C ethernet adapter (with the other end connected to your router/switch) and try again."
fi

detect_subnet() {
    # Derive the network address from interface/prefix using plain awk (no
    # python3 - it is NOT preinstalled on the Pager and must be opkg-installed
    # separately, so this must not depend on it).
    local cidr ip_addr prefix
    cidr=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$cidr" ]; then
        return 1
    fi
    ip_addr="${cidr%/*}"
    prefix="${cidr#*/}"
    case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
    [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ] && return 1
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

if [ "$INTERACTIVE" = "1" ]; then
    echo "== LanScan.sh interactive setup =="
    IFACE=$(ask "Interface to scan from" "$IFACE")
    AUTO_SUBNET=$(detect_subnet)
    SUBNET=$(ask "Target subnet (CIDR)" "${AUTO_SUBNET:-$(cfg_get last_subnet)}")
    MODE=$(ask "Scan mode (ping/quick/full/service/vuln)" "$(cfg_get last_mode)")
    [ -z "$MODE" ] && MODE="quick"
    if [ "$MODE" = "custom" ]; then
        PORTS=$(ask "Port spec (e.g. 22,80,443 or 1-1000)" "$PORTS")
    fi
fi

if [ -z "$SUBNET" ]; then
    SUBNET=$(detect_subnet) || die "Could not auto-detect subnet on $IFACE (no IPv4 address yet). Pass --subnet explicitly, e.g. --subnet 192.168.1.0/24"
fi

[ -z "$MODE" ] && MODE="quick"

cfg_set last_subnet "$SUBNET"
cfg_set last_mode "$MODE"

mkdir -p "$LOOT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo "scan")
if [ -z "$OUTPUT" ]; then
    OUTPUT="$LOOT_DIR/lanscan-${MODE}-${STAMP}.txt"
fi

NMAP_ARGS=""
case "$MODE" in
    ping)    NMAP_ARGS="-sn" ;;
    quick)   NMAP_ARGS="-T4 -F" ;;
    full)    NMAP_ARGS="-T4 -p-" ;;
    service) NMAP_ARGS="-sV -T4" ;;
    vuln)    NMAP_ARGS="-T4 --script vuln" ;;
    custom)
        [ -z "$PORTS" ] && [ -z "$EXTRA_ARGS" ] && die "--mode custom needs --ports and/or --extra-args"
        [ -n "$PORTS" ] && NMAP_ARGS="-p $PORTS"
        ;;
    *) die "Unknown --mode '$MODE' (expected ping/quick/full/service/vuln/custom)" ;;
esac

[ -n "$EXTRA_ARGS" ] && NMAP_ARGS="$NMAP_ARGS $EXTRA_ARGS"

say "Interface:  $IFACE"
say "Subnet:     $SUBNET"
say "Mode:       $MODE  (nmap $NMAP_ARGS)"
say "Output:     $OUTPUT"

if [ "$MODE" = "full" ] || [ "$MODE" = "vuln" ]; then
    say "Note: this mode can take a long time on a large subnet."
fi

confirm "Start scan?" || die "Aborted."

say "Scanning..."
# shellcheck disable=SC2086
nmap -e "$IFACE" $NMAP_ARGS "$SUBNET" -oN "$OUTPUT"
RC=$?

if [ $RC -eq 0 ]; then
    say "Done. Results saved to $OUTPUT"
    echo
    tail -n 40 "$OUTPUT"
else
    err "nmap exited with code $RC"
fi
exit $RC

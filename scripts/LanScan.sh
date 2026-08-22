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
#   LanScan.sh --list
#
# Options:
#   --iface IFACE          Interface to scan from (default: eth1)
#   --subnet CIDR          Target subnet, e.g. 192.168.1.0/24 (default: auto-detect from iface)
#   --mode MODE             ping | quick | full | service | vuln | custom  (default: quick)
#   --ports SPEC             Port spec for --mode custom, e.g. 22,80,443 or 1-1000
#   --extra-args "ARGS"       Extra raw nmap arguments (advanced)
#   --output FILE             Save results to a specific file (default: timestamped under /root/loot/lanscan/)
#   --list                     List past scans in /root/loot/lanscan/ (newest first) and exit - no scan run
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
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) [ $# -lt 2 ] && die "--iface needs a value"; IFACE="$2"; shift 2 ;;
        --subnet) [ $# -lt 2 ] && die "--subnet needs a value"; SUBNET="$2"; shift 2 ;;
        --mode) [ $# -lt 2 ] && die "--mode needs a value"; MODE="$2"; shift 2 ;;
        --ports) [ $# -lt 2 ] && die "--ports needs a value"; PORTS="$2"; shift 2 ;;
        --extra-args) [ $# -lt 2 ] && die "--extra-args needs a value"; EXTRA_ARGS="$2"; shift 2 ;;
        --output) [ $# -lt 2 ] && die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# IMPROVEMENT (new feature): --list - browse past scan results without
# spending time re-scanning or needing nmap/an interface present at all.
# Before this, the only way to see what LanScan.sh had already captured was
# report.sh's aggregate report (every other loot category too, and only
# ever the single most-recent scan in detail) or manually `ls`-ing
# /root/loot/lanscan/ and grepping each file by hand. Exits before the
# nmap/interface checks below - those are scan-only requirements this
# read-only path has no need of.
if [ "$LIST_ONLY" = "1" ]; then
    if [ ! -d "$LOOT_DIR" ]; then
        say "No scans yet - $LOOT_DIR doesn't exist."
        exit 0
    fi
    FILES=$(ls -t "$LOOT_DIR" 2>/dev/null | grep -v '\.incomplete$')
    if [ -z "$FILES" ]; then
        say "No completed scans in $LOOT_DIR yet."
        exit 0
    fi
    TOTAL=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')
    say "Past scans in $LOOT_DIR (newest first, showing up to 20 of $TOTAL):"
    SHOWN=0
    printf '%s\n' "$FILES" | while IFS= read -r f; do
        SHOWN=$((SHOWN + 1))
        [ "$SHOWN" -gt 20 ] && break
        path="$LOOT_DIR/$f"
        hosts=$(grep -c "^Nmap scan report for" "$path" 2>/dev/null)
        hosts="${hosts:-0}"
        mtime=$(date -r "$path" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "?")
        printf '  %-45s %s  hosts: %s\n' "$f" "$mtime" "$hosts"
    done
    exit 0
fi

INTERACTIVE=0
[ -z "$MODE" ] && INTERACTIVE=1

if ! command -v nmap >/dev/null 2>&1; then
    die "nmap is not installed. Install it with: opkg update && opkg install -d mmc nmap"
fi

# BUG FOUND AND FIXED (found via code review - same class as reset.sh's
# earlier fix): use the shared timeout-protected ip_link() wrapper instead
# of a raw, unbounded `ip link show` that has no protection at all against
# a stuck/hanging `ip` command.
if ! ip_link show "$IFACE" >/dev/null 2>&1; then
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

# BIG CHANGE: full/vuln are the two modes this script already warns can run
# long - but nmap's normal report output only prints as EACH HOST finishes,
# so a slow scan against even one uncommon/filtered host looks completely
# silent for however long that host takes. --stats-every makes nmap print
# its own periodic "X.XX% done; ETC ..." progress line regardless of
# per-host completion, so a long full/vuln scan actually shows it's alive
# and roughly how much longer it needs, instead of leaving you guessing
# whether it's working or has hung. Added here (before the args are
# printed/used) so the summary below and the real invocation always agree.
if [ "$MODE" = "full" ] || [ "$MODE" = "vuln" ]; then
    NMAP_ARGS="$NMAP_ARGS --stats-every 15s"
fi

say "Interface:  $IFACE"
say "Subnet:     $SUBNET"
say "Mode:       $MODE  (nmap $NMAP_ARGS)"
say "Output:     $OUTPUT"

if [ "$MODE" = "full" ] || [ "$MODE" = "vuln" ]; then
    say "Note: this mode can take a long time on a large subnet - progress prints every 15s."
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
    # BUG FOUND AND FIXED (found via code review, confirmed by direct
    # testing against the real nmap binary): nmap opens/creates its -oN
    # output file immediately when it starts, BEFORE any actual scanning -
    # confirmed live: `nmap -oN out.txt --script vuln -p1-65535 -Pn
    # 127.0.0.1`, killed with `kill -9` 1-3s in (simulating an OOM-kill on
    # this device's 251MB RAM during a heavy full/vuln scan, or the
    # payload runner force-killing a hung script), left a genuine 0-byte
    # out.txt on disk. report.sh's LAN-scan section picks the newest
    # matching file in $LOOT_DIR as "Most recent" and counts "Nmap scan
    # report for" lines in it for "Hosts found" - a 0-byte file from a
    # scan that never ran to completion reports "Hosts found: 0",
    # completely indistinguishable there from a real, successful scan of
    # a genuinely empty subnet. Rename the failed/partial file out of the
    # way (report.sh's lookup now explicitly excludes "*.incomplete")
    # instead of leaving it to masquerade as a completed result - it's
    # kept on disk, not deleted, in case the partial content is still
    # useful for debugging.
    if [ -f "$OUTPUT" ]; then
        mv "$OUTPUT" "$OUTPUT.incomplete" 2>/dev/null && \
            err "Partial/failed output kept at $OUTPUT.incomplete (not a completed scan - won't show up as one in report.sh)."
    fi
fi
exit $RC

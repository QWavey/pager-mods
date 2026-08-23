#!/bin/bash
# wifikit.sh - WPA handshake + PMKID capture and cracking pipeline for the
# WiFi Pineapple Pager. Wraps hcxdumptool (capture), hcxpcapngtool (convert
# to the hashcat/JtR 22000 hashline), and aircrack-ng (on-box dictionary
# crack). Covers the approved ideas W1 (handshake capture+crack), W2 (PMKID
# clientless), W11 (combined harvest) and DR7 (capture on one radio while
# cracking runs against the growing file).
#
# WHY IT PREFERS THE EXTERNAL ADAPTER:
# hcxdumptool 6.3.x sets monitor mode ITSELF and explicitly refuses virtual
# wlanXmon interfaces ("Do not use virtual interfaces", "Do not set monitor
# mode by third party tools"). It therefore needs a raw PHY interface it can
# own exclusively. The Pager's internal radios (wlan0/wlan1) are driven by
# PineAP and were the exact source of the historical deauth hard-hangs, so
# this defaults to an EXTERNAL USB adapter (e.g. the Netgear A8000 -> wlan2)
# and only touches an internal radio when you pass --force (it will disrupt
# PineAP for the duration). This is the dual-radio split in practice: the
# A8000 harvests while the internal radios keep doing their own job.
#
# Cracking on this MIPS CPU is dictionary-only via aircrack-ng and slow - for
# anything beyond a small wordlist, --convert writes a .22000 hashline you
# pull off-box and run through hashcat on a real GPU.
#
# Usage:
#   wifikit.sh --capture [--iface IF] [--channel N] [--seconds S] [--background]
#   wifikit.sh --convert [FILE.pcapng]          latest capture if FILE omitted
#   wifikit.sh --crack [--wordlist W] [FILE]     aircrack-ng dictionary crack
#   wifikit.sh --auto [--seconds S] [--wordlist W] [--channel N]
#   wifikit.sh --list | --status | --stop
#
# Options:
#   --iface IF      capture interface (default: auto - external adapter first)
#   --channel N     lock to one channel (default: hop all channels, -F)
#   --seconds S     capture duration then stop (default 60; 0 = until --stop)
#   --wordlist W    dictionary for on-box cracking (default: none -> export only)
#   --force         allow using an internal radio (disrupts PineAP)
#   -y, --yes       assume yes to prompts
#
# IMPORTANT: only against networks you own or are explicitly authorized to test.

set -u
TOOL_NAME="wifikit.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

LOOT_DIR="/root/loot/wifikit"
PIDFILE="/tmp/pager-wifikit.pid"
LOGFILE="/tmp/pager-wifikit.log"
# hcxdumptool / hcxpcapngtool live in /mmc after `opkg install -d mmc`; make
# sure they and their libs are reachable regardless of how we were invoked.
export PATH="$PATH:/mmc/usr/bin:/mmc/usr/sbin"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/mmc/usr/lib"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# -- args --------------------------------------------------------------------
MODE=""; IFACE=""; CHANNEL=""; SECONDS_ARG="60"; WORDLIST=""; FORCE=0; BACKGROUND=0
POSFILE=""
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --capture) MODE="capture"; shift ;;
        --convert) MODE="convert"; shift ;;
        --crack)   MODE="crack"; shift ;;
        --auto)    MODE="auto"; shift ;;
        --list)    MODE="list"; shift ;;
        --status)  MODE="status"; shift ;;
        --stop)    MODE="stop"; shift ;;
        --iface)   IFACE="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --seconds) SECONDS_ARG="${2:-}"; shift 2 ;;
        --wordlist) WORDLIST="${2:-}"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        -h|--help) usage ;;
        --) shift ;;
        -*) die "Unknown option: $1 (see --help)" ;;
        *)  POSFILE="$1"; shift ;;
    esac
done
[ -n "$MODE" ] || usage
case "$SECONDS_ARG" in ''|*[!0-9]*) die "--seconds must be a non-negative integer." ;; esac
[ -n "$CHANNEL" ] && case "$CHANNEL" in *[!0-9]*) die "--channel must be numeric." ;; esac

mkdir -p "$LOOT_DIR" 2>/dev/null

# -- interface selection -----------------------------------------------------
# external_wifi_iface - first non-internal wlan (wlan2+), i.e. a USB adapter.
external_wifi_iface() {
    local i
    for i in /sys/class/net/wlan[2-9]; do
        [ -e "$i" ] && { basename "$i"; return 0; }
    done
    return 1
}
# pick_iface - honour --iface, else prefer an external adapter, else (only
# with --force) fall back to the internal wlan1. hcxdumptool wants the raw
# phy iface, never the wlanXmon VIF.
pick_iface() {
    if [ -n "$IFACE" ]; then echo "$IFACE"; return 0; fi
    local ext; ext=$(external_wifi_iface)
    if [ -n "$ext" ]; then echo "$ext"; return 0; fi
    if [ "$FORCE" = "1" ]; then echo "wlan1"; return 0; fi
    return 1
}

is_running() { pid_running "$PIDFILE" "hcxdumptool"; }

# newest capture file in the loot dir
latest_cap() { ls -t "$LOOT_DIR"/*.pcapng 2>/dev/null | head -1; }

# -- capture -----------------------------------------------------------------
do_capture() {
    command -v hcxdumptool >/dev/null 2>&1 || die "hcxdumptool not found - opkg install -d mmc hcxdumptool"
    if is_running; then die "A capture is already running (PID $(cat "$PIDFILE")). Use --stop first."; fi
    local ifc; ifc=$(pick_iface) || die "No external WiFi adapter found. Plug in the A8000 (USB-A), or pass --force to use the internal radio (disrupts PineAP)."
    [ -e "/sys/class/net/$ifc" ] || die "Interface $ifc not present."
    if [ "$ifc" = "wlan0" ] || [ "$ifc" = "wlan1" ]; then
        confirm "Use INTERNAL radio $ifc for capture? This disrupts PineAP for the duration." || exit 0
    fi
    local stamp cap; stamp=$(date +%Y%m%d-%H%M%S); cap="$LOOT_DIR/cap-$stamp.pcapng"
    # -F = hop all channels; -c locks one (faster/targeted). --rds=1 = live
    # display sorted by most-recent PMKID/EAPOL.
    local chan_args="-F"; [ -n "$CHANNEL" ] && chan_args="-c $CHANNEL"
    say "Capturing on $ifc ($([ -n "$CHANNEL" ] && echo "ch $CHANNEL" || echo "all channels")) -> $cap"
    if [ "$BACKGROUND" = "1" ] || [ "$SECONDS_ARG" = "0" ]; then
        ( hcxdumptool -i "$ifc" -w "$cap" $chan_args --rds=1 >"$LOGFILE" 2>&1 ) &
        echo $! > "$PIDFILE"
        sleep 1
        if ! is_running; then die "hcxdumptool exited immediately - see $LOGFILE."; fi
        say "Capture running detached (PID $(cat "$PIDFILE")). Stop with --stop. File: $cap"
        [ "$SECONDS_ARG" != "0" ] && ( sleep "$SECONDS_ARG"; kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$PIDFILE" ) &
        return 0
    fi
    # foreground timed capture
    hcxdumptool -i "$ifc" -w "$cap" $chan_args --rds=1 >"$LOGFILE" 2>&1 &
    local hpid=$!; echo "$hpid" > "$PIDFILE"
    local waited=0
    while kill -0 "$hpid" 2>/dev/null && [ "$waited" -lt "$SECONDS_ARG" ]; do sleep 1; waited=$((waited+1)); done
    kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null; rm -f "$PIDFILE"
    say "Capture finished: $cap"
    echo "$cap"
}

# -- convert (pcapng -> .22000 hashline) -------------------------------------
do_convert() {
    command -v hcxpcapngtool >/dev/null 2>&1 || die "hcxpcapngtool not found."
    local cap="${POSFILE:-$(latest_cap)}"
    [ -n "$cap" ] && [ -f "$cap" ] || die "No capture file (give one, or run --capture first)."
    local out="${cap%.pcapng}.22000"
    hcxpcapngtool -o "$out" "$cap" >>"$LOGFILE" 2>&1
    if [ -s "$out" ]; then
        say "Wrote hashline: $out ($(wc -l < "$out") hash(es)). Pull it off-box for hashcat -m 22000, or --crack it here."
        echo "$out"
    else
        rm -f "$out" 2>/dev/null
        die "No PMKID/EAPOL hashes in $cap yet - capture longer, or the AP/clients produced nothing crackable."
    fi
}

# -- crack (aircrack-ng dictionary) ------------------------------------------
do_crack() {
    local cap="${POSFILE:-$(latest_cap)}"
    [ -n "$cap" ] && [ -f "$cap" ] || die "No capture file to crack."
    if [ -z "$WORDLIST" ]; then
        say "No --wordlist given. Converting to a 22000 hashline for off-box hashcat instead:"
        do_convert
        return 0
    fi
    [ -f "$WORDLIST" ] || die "Wordlist not found: $WORDLIST"
    command -v aircrack-ng >/dev/null 2>&1 || die "aircrack-ng not found - opkg install -d mmc aircrack-ng"
    say "Cracking $cap with $WORDLIST (aircrack-ng, dictionary - slow on MIPS)..."
    aircrack-ng -w "$WORDLIST" "$cap" 2>&1 | tee -a "$LOGFILE" | grep -iE "KEY FOUND|Passphrase|handshake|PMKID" || true
}

case "$MODE" in
    capture) do_capture ;;
    convert) do_convert ;;
    crack)   do_crack ;;
    auto)
        cap=$(do_capture | tail -1)
        [ -f "$cap" ] || cap=$(latest_cap)
        POSFILE="$cap"; do_convert || true
        [ -n "$WORDLIST" ] && do_crack
        ;;
    list)   ls -lt "$LOOT_DIR" 2>/dev/null || say "No loot yet." ;;
    status) if is_running; then say "Capture running (PID $(cat "$PIDFILE"))."; else say "Not running."; fi ;;
    stop)
        if is_running; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; say "Capture stopped."
        else say "Nothing running."; fi ;;
esac

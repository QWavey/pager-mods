#!/bin/bash
# ssidpool.sh - Manage the PineAP SSID impersonation pool. Wraps
# PINEAPPLE_SSID_POOL_ADD / LIST / DELETE / CLEAR / START / STOP /
# COLLECT_START / COLLECT_STOP.
#
# Usage:
#   ssidpool.sh add "SSID" ["SSID2" ...]
#   ssidpool.sh delete "SSID" ["SSID2" ...]
#   ssidpool.sh list
#   ssidpool.sh clear
#   ssidpool.sh --on [random]      start advertising the pool (optional random BSSID)
#   ssidpool.sh --off                stop advertising
#   ssidpool.sh --collect on|off       auto-collect probed SSIDs into the pool
#   ssidpool.sh                          interactive mode

set -u
TOOL_NAME="ssidpool.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh):
# --on/--off/--collect printed a success message unconditionally
# regardless of the underlying PINEAPPLE_SSID_POOL_* command's real exit
# code.
case "${1:-}" in
    add) shift; [ $# -eq 0 ] && die "add needs at least one SSID"; PINEAPPLE_SSID_POOL_ADD "$@" ;;
    delete) shift; [ $# -eq 0 ] && die "delete needs at least one SSID"; PINEAPPLE_SSID_POOL_DELETE "$@" ;;
    list) PINEAPPLE_SSID_POOL_LIST ;;
    clear) confirm "Clear the entire SSID pool?" && PINEAPPLE_SSID_POOL_CLEAR ;;
    --on)
        { if [ "${2:-}" = "random" ]; then PINEAPPLE_SSID_POOL_START random; else PINEAPPLE_SSID_POOL_START; fi; } \
            && say "Advertising started." || die "Failed to start advertising."
        ;;
    --off) PINEAPPLE_SSID_POOL_STOP && say "Advertising stopped." || die "Failed to stop advertising." ;;
    --collect)
        case "${2:-}" in
            on) PINEAPPLE_SSID_POOL_COLLECT_START && say "Probe collection on." || die "Failed to start probe collection." ;;
            off) PINEAPPLE_SSID_POOL_COLLECT_STOP && say "Probe collection off." || die "Failed to stop probe collection." ;;
            *) die "--collect expects on/off" ;;
        esac
        ;;
    -h|--help) usage ;;
    "")
        # CONSISTENCY FIX (found via code review - same gap already fixed
        # for --on/--off/--collect above, missed throughout this entire
        # interactive block: none of choices 2-7 checked success/failure
        # at all).
        echo "== ssidpool.sh interactive =="
        echo "1) List pool  2) Add SSID  3) Delete SSID  4) Clear pool"
        echo "5) Start advertising  6) Stop advertising  7) Toggle probe collection"
        c=$(ask "Choose" "1")
        case "$c" in
            1) PINEAPPLE_SSID_POOL_LIST ;;
            2) s=$(ask "SSID to add" ""); PINEAPPLE_SSID_POOL_ADD "$s" && say "Added." || err "Failed to add '$s'." ;;
            3) s=$(ask "SSID to delete" ""); PINEAPPLE_SSID_POOL_DELETE "$s" && say "Deleted." || err "Failed to delete '$s'." ;;
            4) confirm "Clear the entire pool?" && { PINEAPPLE_SSID_POOL_CLEAR && say "Cleared." || err "Failed to clear the pool."; } ;;
            5) r=$(ask "Random BSSID per SSID? (y/N)" "N"); case "$r" in
                   y|Y) PINEAPPLE_SSID_POOL_START random && say "Advertising started." || err "Failed to start advertising." ;;
                   *) PINEAPPLE_SSID_POOL_START && say "Advertising started." || err "Failed to start advertising." ;;
               esac ;;
            6) PINEAPPLE_SSID_POOL_STOP && say "Advertising stopped." || err "Failed to stop advertising." ;;
            7) c2=$(ask "Collection on/off" "on"); case "$c2" in
                   on) PINEAPPLE_SSID_POOL_COLLECT_START && say "Probe collection on." || err "Failed to start probe collection." ;;
                   *) PINEAPPLE_SSID_POOL_COLLECT_STOP && say "Probe collection off." || err "Failed to stop probe collection." ;;
               esac ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

#!/bin/bash
# mgmt.sh - Manage the Pager's Management AP. Wraps WIFI_MGMT_AP /
# WIFI_MGMT_AP_DISABLE / WIFI_MGMT_AP_HIDE / WIFI_MGMT_AP_CLEAR.
#
# Usage:
#   mgmt.sh --on --name "SSID" --pw "password"
#   mgmt.sh --off
#   mgmt.sh --hide
#   mgmt.sh --clear
#   mgmt.sh --status
#   mgmt.sh                interactive mode
#
# Options:
#   --on              Enable/configure the Management AP (needs --name)
#   --name SSID        Management AP SSID
#   --pw PASS           Management AP password (WPA2/WPA3-SAE-mixed)
#   --off              Disable the Management AP
#   --hide              Hide the Management AP SSID
#   --clear              Wipe the Management AP configuration
#   --status              Show current Management AP config
#   -y, --yes              Don't prompt for confirmation
#   -h, --help               This help

set -u
TOOL_NAME="mgmt.sh"
CFG_NS="mgmt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_ON=0; DO_OFF=0; DO_HIDE=0; DO_CLEAR=0; DO_STATUS=0
SSID=""; PASS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --on) DO_ON=1; shift ;;
        --name) need_arg "--name" "$#"; SSID="$2"; shift 2 ;;
        --pw) need_arg "--pw" "$#"; PASS="$2"; shift 2 ;;
        --off) DO_OFF=1; shift ;;
        --hide) DO_HIDE=1; shift ;;
        --clear) DO_CLEAR=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

if [ "$DO_STATUS" = "1" ]; then
    say "Management AP:"
    uci -q get wireless.wlan0mgmt.ssid 2>/dev/null | sed 's/^/  SSID: /'
    disabled=$(uci -q get wireless.wlan0mgmt.disabled 2>/dev/null)
    [ "$disabled" = "1" ] && echo "  state: off" || echo "  state: on"
    exit 0
fi

if [ "$DO_CLEAR" = "1" ]; then
    confirm "Wipe the Management AP configuration entirely?" || die "Aborted."
    WIFI_MGMT_AP_CLEAR wlan0mgmt
    say "Cleared."
    exit 0
fi

# BUG FOUND AND FIXED (found via code review, same class as the last_ssid
# fix below): these printed a success message unconditionally regardless
# of whether WIFI_MGMT_AP_HIDE/_DISABLE actually succeeded.
[ "$DO_HIDE" = "1" ] && { WIFI_MGMT_AP_HIDE wlan0mgmt && say "Management AP hidden." || err "Failed to hide the Management AP."; }
[ "$DO_OFF" = "1" ] && { WIFI_MGMT_AP_DISABLE wlan0mgmt && say "Management AP disabled." || err "Failed to disable the Management AP."; }

INTERACTIVE=0
[ "$DO_ON" = "0" ] && [ "$DO_OFF" = "0" ] && [ "$DO_HIDE" = "0" ] && [ "$DO_CLEAR" = "0" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== mgmt.sh =="
    if confirm "Configure/enable the Management AP now?"; then
        DO_ON=1
        SSID=$(ask "Management AP SSID" "$(cfg_get last_ssid)")
        PASS=$(ask_secret "Management AP password")
    fi
fi

if [ "$DO_ON" = "1" ]; then
    [ -z "$SSID" ] && die "--name is required with --on."
    [ -z "$PASS" ] && die "--pw is required with --on (Management AP cannot be open)."
    # BUG FOUND AND FIXED (found via code review): cfg_set ran unconditionally
    # after WIFI_MGMT_AP, so a failed apply still persisted "last_ssid" as if
    # it had succeeded - the next interactive run would suggest a name that
    # was never actually applied. Only remember it on success now.
    if WIFI_MGMT_AP wlan0mgmt "$SSID" sae-mixed "$PASS"; then
        say "Management AP set to '$SSID'."
        cfg_set last_ssid "$SSID"
    else
        die "Failed to set the Management AP."
    fi
fi

exit 0

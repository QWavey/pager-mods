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
#
# BIG CHANGE (found via code review while looking at this file's own
# --on path below): --off/--hide fired IMMEDIATELY with no confirmation at
# all, ever, even without -y - unlike --clear just above (which always
# confirms) and unlike virtually every other AP-changing script in this
# toolkit (openap.sh/EvilTwin.sh/config.sh all confirm before applying).
# This is the ONE AP in the whole toolkit whose own settings can cut off
# the very management channel you're issuing the command through (Management
# WiFi is a br-lan member alongside USB-C/eth0 - see reset.sh's header) -
# if anything here deserves the same "warn before you might disconnect
# yourself" caution this session's other incidents were all about, it's
# this script, not fewer prompts than the less-consequential ones.
if [ "$DO_HIDE" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
    confirm "Hide the Management AP's SSID? If you're connected to it over Management WiFi right now (not USB-C), this can make reconnecting harder." || die "Aborted."
fi
if [ "$DO_OFF" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
    confirm "Disable the Management AP? If you're connected to it over Management WiFi right now (not USB-C), this WILL disconnect your current session." || die "Aborted."
fi
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
    # BIG CHANGE (same reasoning as --off/--hide above): a CLI `mgmt.sh --on
    # --name ... --pw ...` used to apply immediately with NO confirmation
    # at all, unlike this script's own interactive mode (which always asks
    # first). Changing the SSID/password disconnects anyone already
    # associated over Management WiFi with the OLD credentials, same risk
    # class as --off/--hide. Skipped when INTERACTIVE already asked
    # ("Configure/enable the Management AP now?") - re-confirming the exact
    # same intent a second time would just be friction, not more safety.
    if [ "$INTERACTIVE" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
        confirm "Set the Management AP to '$SSID'? If you're connected to it over Management WiFi right now (not USB-C), you'll need to reconnect with the new credentials afterward." || die "Aborted."
    fi
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

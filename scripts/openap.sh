#!/bin/bash
# openap.sh - Manage the Pineapple Open AP directly. Wraps WIFI_OPEN_AP /
# WIFI_OPEN_AP_DISABLE / WIFI_OPEN_AP_HIDE / WIFI_OPEN_AP_CLEAR.
#
# For a full clone-with-internet-passthrough setup, use EvilTwin.sh instead
# - this is the bare single-purpose wrapper for just the Open AP itself.
#
# Usage:
#   openap.sh --on --name "SSID" [--bssid AA:BB:CC:DD:EE:FF]
#   openap.sh --off / --hide / --clear / --status
#   openap.sh                interactive mode
#
# Options:
#   --on            Enable the Open AP (needs --name)
#   --name SSID      SSID to broadcast
#   --bssid MAC       Specific BSSID (default: device MAC)
#   --off            Disable the Open AP
#   --hide            Hide the SSID
#   --clear            Wipe the Open AP configuration
#   --status            Show current Open AP config
#   -y, --yes            Don't prompt for confirmation
#   -h, --help             This help

set -u
TOOL_NAME="openap.sh"
CFG_NS="openap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_ON=0; DO_OFF=0; DO_HIDE=0; DO_CLEAR=0; DO_STATUS=0
SSID=""; BSSID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --on) DO_ON=1; shift ;;
        --name) need_arg "--name" "$#"; SSID="$2"; shift 2 ;;
        --bssid) need_arg "--bssid" "$#"; BSSID="$2"; shift 2 ;;
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
    say "Open AP:"
    uci -q get wireless.wlan0open.ssid 2>/dev/null | sed 's/^/  SSID: /'
    disabled=$(uci -q get wireless.wlan0open.disabled 2>/dev/null)
    [ "$disabled" = "1" ] && echo "  state: off" || echo "  state: on"
    exit 0
fi

if [ "$DO_CLEAR" = "1" ]; then
    confirm "Wipe the Open AP configuration entirely?" || die "Aborted."
    WIFI_OPEN_AP_CLEAR wlan0open
    say "Cleared."
    exit 0
fi

INTERACTIVE=0
[ "$DO_ON" = "0" ] && [ "$DO_OFF" = "0" ] && [ "$DO_HIDE" = "0" ] && [ "$DO_CLEAR" = "0" ] && INTERACTIVE=1

# BUG FOUND AND FIXED (found via code review, same class as the last_ssid
# fix below): these printed a success message unconditionally regardless
# of whether WIFI_OPEN_AP_HIDE/_DISABLE actually succeeded.
#
# BIG CHANGE (same gap found and fixed in mgmt.sh this sweep): --off/--hide
# fired IMMEDIATELY with no confirmation at all, ever, even without -y. The
# risk here is different from mgmt.sh's (this is wlan0open, not the
# management AP, so it can't disconnect your own SSH/control session) but
# still real: silently killing an Open AP that has real connected clients
# mid-engagement, with zero warning, is exactly the kind of "no feedback
# before an irreversible-feeling action" gap this session's other fixes
# were about. Skipped when INTERACTIVE already asked, to avoid asking twice.
if [ "$INTERACTIVE" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
    [ "$DO_HIDE" = "1" ] && { confirm "Hide the Open AP's SSID? Any devices actively probing for it by name will stop finding it." || die "Aborted."; }
    [ "$DO_OFF" = "1" ] && { confirm "Disable the Open AP? This disconnects any clients currently connected to it." || die "Aborted."; }
fi
[ "$DO_HIDE" = "1" ] && { WIFI_OPEN_AP_HIDE wlan0open && say "Open AP hidden." || err "Failed to hide the Open AP."; }
[ "$DO_OFF" = "1" ] && { WIFI_OPEN_AP_DISABLE wlan0open && say "Open AP disabled." || err "Failed to disable the Open AP."; }

if [ "$INTERACTIVE" = "1" ]; then
    echo "== openap.sh =="
    if confirm "Enable the Open AP now?"; then
        DO_ON=1
        SSID=$(ask "Open AP SSID" "$(cfg_get last_ssid)")
    fi
fi

if [ "$DO_ON" = "1" ]; then
    [ -z "$SSID" ] && die "--name is required with --on."
    # BUG FOUND AND FIXED (found via code review): --bssid had no format
    # check before being handed to WIFI_OPEN_AP - the exact same gap
    # already found and fixed for EvilTwin.sh's own --bssid (which wraps
    # the same kind of call), missed here. A typo'd BSSID would only
    # surface as a generic "Failed to set the Open AP" instead of a clear,
    # immediate reason.
    [ -n "$BSSID" ] && { is_valid_mac "$BSSID" || die "'$BSSID' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."; }
    if [ "$INTERACTIVE" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
        confirm "Enable the Open AP as '$SSID'?" || die "Aborted."
    fi
    # BUG FOUND AND FIXED (found via code review): cfg_set ran unconditionally
    # even when WIFI_OPEN_AP failed, so a rejected SSID was still remembered
    # as "last_ssid" and offered again next time as if it had worked.
    if [ -n "$BSSID" ]; then
        ok=1; WIFI_OPEN_AP wlan0open "$SSID" "$BSSID" || ok=0
    else
        ok=1; WIFI_OPEN_AP wlan0open "$SSID" || ok=0
    fi
    if [ "$ok" = "1" ]; then
        say "Open AP set to '$SSID'."
        cfg_set last_ssid "$SSID"
    else
        die "Failed to set the Open AP."
    fi
fi

exit 0

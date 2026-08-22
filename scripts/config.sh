#!/bin/bash
#
# config.sh - Device configuration helper for the WiFi Pineapple Pager.
#
# Wraps OFFICIAL Hak5 commands only:
#   WIFI_MGMT_AP / _DISABLE / _HIDE / _CLEAR     Management AP identity
#   PINEAPPLE_MIMIC_ENABLE / _DISABLE            Open AP mimic mode
#   PINEAPPLE_SSID_POOL_START [random]           Randomized BSSID for the SSID pool
#   PINEAPPLE_DEVICE_FILTER_MODE / NETWORK_FILTER_MODE   allow/deny scoping
#   PAYLOAD_SET/GET/DEL_CONFIG                   Persistent settings store
#     (shared with EvilTwin.sh / LanScan.sh / PayloadRunner.sh)
#
# NOTE ON HOSTNAME / SYSTEM IDENTITY:
#   There is no documented Hak5 command to change the underlying OpenWRT
#   hostname or the client-mode (wlan0cli) MAC address. Those aren't
#   Pineapple-specific features - they're generic OpenWRT/Linux config
#   (uci system, or the wireless macaddr option). This script keeps that
#   OFF by default and only touches it with --system-hostname, clearly
#   labelled as "generic OpenWRT, not an official Pineapple command."
#
# Usage:
#   config.sh                          interactive menu
#   config.sh --show                   show current config
#   config.sh [options]
#
# Options:
#   --mgmt-ssid SSID          Set the Management AP SSID
#   --mgmt-pw PASS             Set the Management AP password (WPA2/WPA3-SAE-mixed)
#   --mgmt-hide                 Hide the Management AP
#   --mgmt-disable               Disable the Management AP
#   --mimic on|off                 Toggle PineAP Open-AP mimic mode
#   --ssid-pool-random on|off      Randomize BSSID per SSID when advertising the pool
#   --device-filter allow|deny     Set PineAP client (MAC) filter mode
#   --network-filter allow|deny    Set PineAP network (SSID) filter mode
#   --set KEY VALUE                 Store an arbitrary named setting (shared store)
#   --get KEY                        Print a stored setting
#   --del KEY                        Delete a stored setting
#   --system-hostname NAME            Generic OpenWRT hostname change (NOT a Hak5 command, off by default)
#   --show                             Print current PineAP / config state
#   -y, --yes                          Don't prompt for confirmation
#   -h, --help                          This help

set -u
TOOL_NAME="config.sh"
CFG_NS="pagerconfig"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

MGMT_SSID=""
MGMT_PW=""
MGMT_HIDE=0
MGMT_DISABLE=0
MIMIC=""
SSID_POOL_RANDOM=""
DEVICE_FILTER=""
NETWORK_FILTER=""
SET_KEY=""
SET_VAL=""
GET_KEY=""
DEL_KEY=""
SYS_HOSTNAME=""
SHOW=0
ASSUME_YES=0
ANY_FLAG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --mgmt-ssid) [ $# -lt 2 ] && die "--mgmt-ssid needs a value"; MGMT_SSID="$2"; ANY_FLAG=1; shift 2 ;;
        --mgmt-pw) [ $# -lt 2 ] && die "--mgmt-pw needs a value"; MGMT_PW="$2"; ANY_FLAG=1; shift 2 ;;
        --mgmt-hide) MGMT_HIDE=1; ANY_FLAG=1; shift ;;
        --mgmt-disable) MGMT_DISABLE=1; ANY_FLAG=1; shift ;;
        --mimic) [ $# -lt 2 ] && die "--mimic needs a value (on/off)"; MIMIC="$2"; ANY_FLAG=1; shift 2 ;;
        --ssid-pool-random) [ $# -lt 2 ] && die "--ssid-pool-random needs a value (on/off)"; SSID_POOL_RANDOM="$2"; ANY_FLAG=1; shift 2 ;;
        --device-filter) [ $# -lt 2 ] && die "--device-filter needs a value (allow/deny)"; DEVICE_FILTER="$2"; ANY_FLAG=1; shift 2 ;;
        --network-filter) [ $# -lt 2 ] && die "--network-filter needs a value (allow/deny)"; NETWORK_FILTER="$2"; ANY_FLAG=1; shift 2 ;;
        --set) [ $# -lt 3 ] && die "--set needs a KEY and a VALUE"; SET_KEY="$2"; SET_VAL="$3"; ANY_FLAG=1; shift 3 ;;
        --get) [ $# -lt 2 ] && die "--get needs a KEY"; GET_KEY="$2"; ANY_FLAG=1; shift 2 ;;
        --del) [ $# -lt 2 ] && die "--del needs a KEY"; DEL_KEY="$2"; ANY_FLAG=1; shift 2 ;;
        --system-hostname) [ $# -lt 2 ] && die "--system-hostname needs a value"; SYS_HOSTNAME="$2"; ANY_FLAG=1; shift 2 ;;
        --show) SHOW=1; ANY_FLAG=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

show_config() {
    echo "== Management AP (wlan0mgmt) =="
    uci -q get wireless.wlan0mgmt.ssid 2>/dev/null | sed 's/^/  SSID: /'
    uci -q get wireless.wlan0mgmt.disabled 2>/dev/null | sed 's/^/  disabled: /'
    echo
    echo "== PineAP filters (/etc/config/pineapd) =="
    grep -A2 "config ssid_filter" /etc/config/pineapd 2>/dev/null | sed 's/^/  network: /'
    grep -A2 "config mac_filter" /etc/config/pineapd 2>/dev/null | sed 's/^/  device:  /'
    echo
    echo "== Stored config ($CFG_NS namespace) =="
    echo "  (individual keys only - use --get KEY to read one)"
    echo
    echo "== System hostname =="
    uci -q get system.@system[0].hostname 2>/dev/null | sed 's/^/  /'
}

# --show always shows the config. If it was the ONLY flag given, we're done;
# otherwise fall through and also apply whatever other changes were requested
# (--show used to be silently dropped in that combined case - it isn't anymore).
if [ "$SHOW" = "1" ]; then
    show_config
    if [ -z "$MGMT_SSID$MIMIC$SSID_POOL_RANDOM$DEVICE_FILTER$NETWORK_FILTER$SET_KEY$GET_KEY$DEL_KEY$SYS_HOSTNAME" ] \
       && [ "$MGMT_HIDE" = "0" ] && [ "$MGMT_DISABLE" = "0" ]; then
        exit 0
    fi
    echo
fi

INTERACTIVE=0
[ "$ANY_FLAG" = "0" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== config.sh interactive menu =="
    echo "1) Show current configuration"
    echo "2) Set Management AP identity (SSID/password/hide/disable)"
    echo "3) Toggle PineAP mimic mode"
    echo "4) Toggle SSID pool BSSID randomization"
    echo "5) Set PineAP device/network filter modes"
    echo "6) Store/read/delete a named setting"
    echo "7) Change system hostname (generic OpenWRT, not a Hak5 command)"
    echo "0) Exit"
    choice=$(ask "Choose an option" "0")
    case "$choice" in
        1) show_config; exit 0 ;;
        2)
            MGMT_SSID=$(ask "Management AP SSID" "")
            if confirm "Set a password (WPA2/WPA3-SAE-mixed)? (No = leave as-is)"; then
                read -r -s -p "Management AP password: " MGMT_PW; echo
            fi
            confirm "Hide this SSID?" && MGMT_HIDE=1
            ;;
        3)
            MIMIC=$(ask "Mimic mode (on/off)" "on")
            ;;
        4)
            SSID_POOL_RANDOM=$(ask "SSID pool BSSID randomization (on/off)" "on")
            ;;
        5)
            DEVICE_FILTER=$(ask "Device (MAC) filter mode (allow/deny)" "")
            NETWORK_FILTER=$(ask "Network (SSID) filter mode (allow/deny)" "")
            ;;
        6)
            # BUG FOUND AND FIXED (found via code review): a blank key here
            # (just hitting enter - the prompt's own default IS "") fell
            # through to the bottom-of-script `[ -n "$GET_KEY" ]`-style
            # guards, which silently skip the whole operation with NO
            # message at all - picking "get" and giving no key produced
            # completely empty output, indistinguishable from a hang or
            # crash. Fail clearly right here instead, same pattern this
            # toolkit already uses for every other required-value prompt
            # (clientip.sh's MAC, EvilTwin.sh's cloned SSID, etc.).
            action=$(ask "set/get/del" "get")
            case "$action" in
                set) SET_KEY=$(ask "Key" ""); [ -z "$SET_KEY" ] && die "A key is required."; SET_VAL=$(ask "Value" "") ;;
                get) GET_KEY=$(ask "Key" ""); [ -z "$GET_KEY" ] && die "A key is required." ;;
                del) DEL_KEY=$(ask "Key" ""); [ -z "$DEL_KEY" ] && die "A key is required." ;;
            esac
            ;;
        7)
            say "This is a generic OpenWRT setting, not an official Pineapple command."
            SYS_HOSTNAME=$(ask "New system hostname" "$(uci -q get system.@system[0].hostname)")
            ;;
        *) say "Nothing to do."; exit 0 ;;
    esac
fi

CHANGED=0

# BUG FOUND AND FIXED (found via code review): --mgmt-pw (or the
# interactive "leave SSID blank, just set a password" path) with no
# --mgmt-ssid was a silent no-op - the whole password-setting block below
# is gated on MGMT_SSID being non-empty, so MGMT_PW just sat there unused
# and the script printed "Nothing changed." with exit 0, looking exactly
# like success. The reverse case (SSID given, password reused from
# cfg_get) was already handled; this mirrors it by reusing the currently-
# configured SSID from uci when only a password is given.
if [ -z "$MGMT_SSID" ] && [ -n "$MGMT_PW" ]; then
    MGMT_SSID=$(uci -q get wireless.wlan0mgmt.ssid 2>/dev/null)
    [ -z "$MGMT_SSID" ] && die "--mgmt-pw given with no --mgmt-ssid, and no Management AP is currently configured to reuse the SSID from. Pass --mgmt-ssid too."
fi

if [ -n "$MGMT_SSID" ]; then
    say "Setting Management AP SSID to '$MGMT_SSID'..."
    if [ -n "$MGMT_PW" ]; then
        # BUG FOUND AND FIXED (found via code review): cfg_set ran
        # unconditionally even when WIFI_MGMT_AP failed, so a rejected
        # password (e.g. too short for WPA2/SAE) still got saved as
        # "mgmt_last_pw" and would silently be reused as if it had worked.
        if WIFI_MGMT_AP wlan0mgmt "$MGMT_SSID" sae-mixed "$MGMT_PW"; then
            CHANGED=1
            cfg_set mgmt_last_pw "$MGMT_PW"
        else
            err "Failed to set the Management AP."
        fi
    else
        PREV_PW=$(cfg_get mgmt_last_pw)
        if [ -z "$PREV_PW" ]; then
            die "No password given (--mgmt-pw) and no previously saved Management AP password to reuse. Refusing to set an empty WPA key - that could lock you out of Management WiFi. Pass --mgmt-pw explicitly."
        fi
        # BUG FOUND AND FIXED (found via code review, same class as the
        # explicit-password branch just above): on failure this branch set
        # neither CHANGED nor printed any error - the only visible symptom
        # was the generic "Nothing changed." at the very end of the script,
        # which reads as "there was nothing to do" rather than "this was
        # attempted and failed", exactly the ambiguity the branch above
        # already avoids for the explicit-password case.
        WIFI_MGMT_AP wlan0mgmt "$MGMT_SSID" sae-mixed "$PREV_PW" && CHANGED=1 || err "Failed to set the Management AP."
    fi
fi
# BUG FOUND AND FIXED (found via code review): these two calls had NO
# feedback of any kind, success or failure - CHANGED was set to 1
# regardless of whether WIFI_MGMT_AP_HIDE/_DISABLE actually succeeded, and
# nothing was ever printed either way. Sibling script mgmt.sh wraps these
# exact same two commands and already checks them ("WIFI_MGMT_AP_HIDE
# wlan0mgmt && say ... || err ..."), specifically because - per mgmt.sh's
# own header - this is the one AP in the toolkit whose own settings can cut
# off the very management channel a command might be issued through, so a
# silent failure here is worse than most. Brought in line with mgmt.sh.
[ "$MGMT_HIDE" = "1" ] && { WIFI_MGMT_AP_HIDE wlan0mgmt && { say "Management AP hidden."; CHANGED=1; } || err "Failed to hide the Management AP."; }
[ "$MGMT_DISABLE" = "1" ] && { WIFI_MGMT_AP_DISABLE wlan0mgmt && { say "Management AP disabled."; CHANGED=1; } || err "Failed to disable the Management AP."; }

# BUG FOUND AND FIXED (found via code review): all four blocks below
# (--mimic/--ssid-pool-random/--device-filter/--network-filter) called
# their PINEAPPLE_* command and then printed a success message
# UNCONDITIONALLY, never checking whether the call actually succeeded. This
# is exactly the same command config.sh's own header lists as wrapping
# PINEAPPLE_MIMIC_ENABLE/_DISABLE and PINEAPPLE_SSID_POOL_START - and the
# sibling scripts that ALSO wrap those exact same platform commands
# (mimic.sh: "PINEAPPLE_MIMIC_ENABLE && say ... || die/err ..."; ssidpool.sh:
# "PINEAPPLE_SSID_POOL_START && say ... || err ...") already check their
# exit codes for this very reason. config.sh silently drifted from that
# established convention by reimplementing the same calls without the
# check. Fixed the same way here, and applied the identical pattern to
# --device-filter/--network-filter for consistency.
if [ -n "$MIMIC" ]; then
    case "$MIMIC" in
        on|1|true)  PINEAPPLE_MIMIC_ENABLE && { say "Mimic mode: on"; CHANGED=1; } || err "Failed to enable mimic mode." ;;
        off|0|false) PINEAPPLE_MIMIC_DISABLE && { say "Mimic mode: off"; CHANGED=1; } || err "Failed to disable mimic mode." ;;
        *) err "--mimic expects on/off" ;;
    esac
fi

if [ -n "$SSID_POOL_RANDOM" ]; then
    case "$SSID_POOL_RANDOM" in
        on|1|true)  PINEAPPLE_SSID_POOL_START random && { say "SSID pool advertising: on, randomized BSSID"; CHANGED=1; } || err "Failed to start SSID pool advertising." ;;
        off|0|false) PINEAPPLE_SSID_POOL_START && { say "SSID pool advertising: on, fixed BSSID"; CHANGED=1; } || err "Failed to start SSID pool advertising." ;;
        *) err "--ssid-pool-random expects on/off" ;;
    esac
fi

if [ -n "$DEVICE_FILTER" ]; then
    case "$DEVICE_FILTER" in
        allow|deny) PINEAPPLE_DEVICE_FILTER_MODE "$DEVICE_FILTER" && { say "Device filter mode: $DEVICE_FILTER"; CHANGED=1; } || err "Failed to set the device filter mode." ;;
        *) err "--device-filter expects allow/deny" ;;
    esac
fi

if [ -n "$NETWORK_FILTER" ]; then
    case "$NETWORK_FILTER" in
        allow|deny) PINEAPPLE_NETWORK_FILTER_MODE "$NETWORK_FILTER" && { say "Network filter mode: $NETWORK_FILTER"; CHANGED=1; } || err "Failed to set the network filter mode." ;;
        *) err "--network-filter expects allow/deny" ;;
    esac
fi

# BUG FOUND AND FIXED (found via code review - directly answers this
# file's own header question "does every config write actually persist
# correctly?"): --set and --del called cfg_set/cfg_del and then printed
# "Stored .../Deleted ..." UNCONDITIONALLY, never looking at either
# wrapper's real exit code. cfg_set()/cfg_del() (lib/common.sh) are thin
# wrappers whose own return status IS PAYLOAD_SET_CONFIG/PAYLOAD_DEL_
# CONFIG's real exit code (the >/dev/null 2>&1 redirection inside them only
# silences output, it doesn't touch $?) - so a failed write (storage full,
# the shared PAYLOAD_*_CONFIG store unavailable, etc.) would still report
# success, indistinguishable from a genuine one. Verified with a standalone
# snippet: a function that `return 1`s, called bare as `f; echo done`,
# unconditionally reaches the echo - confirming this exact call shape
# (`cmd; say ...` with no &&/||) can never surface a failure, exactly
# matching the "unconditional success message" class already fixed
# throughout this codebase (bands.sh/gps.sh/screen.sh/wigle.sh/
# reconsession.sh, etc.) for other platform calls - just missed here for
# config.sh's own PAYLOAD_*_CONFIG writes.
if [ -n "$SET_KEY" ]; then
    cfg_set "$SET_KEY" "$SET_VAL" && { say "Stored $SET_KEY = $SET_VAL"; CHANGED=1; } || err "Failed to store $SET_KEY - the setting may not have been saved."
fi

if [ -n "$GET_KEY" ]; then
    val=$(cfg_get "$GET_KEY")
    echo "$GET_KEY = $val"
fi

if [ -n "$DEL_KEY" ]; then
    cfg_del "$DEL_KEY" && { say "Deleted $DEL_KEY"; CHANGED=1; } || err "Failed to delete $DEL_KEY."
fi

if [ -n "$SYS_HOSTNAME" ]; then
    say "About to change the system hostname to '$SYS_HOSTNAME'."
    say "This is a GENERIC OpenWRT setting (uci system), not an official Hak5/Pineapple command."
    if confirm "Proceed?"; then
        # BIG CHANGE: this whole block used to run uci set/commit and
        # /etc/init.d/system reload with no error checking and no timeout at
        # all, then print "Hostname set" unconditionally - the same two
        # classes of bug (untimed subsystem-reload call, unconditional
        # success message) this session's own incident history found and
        # fixed for reset.sh's network reload and mgmt.sh/openap.sh's
        # cfg_set-on-failure. /etc/init.d/system reload is the exact same
        # kind of call as /etc/init.d/network reload - a subsystem confused
        # enough not to respond promptly would hang this indefinitely.
        # Bounded the same way, and now actually checks whether uci set/
        # commit succeeded before claiming the hostname changed.
        if uci set system.@system[0].hostname="$SYS_HOSTNAME" && uci commit system; then
            timeout 10 /etc/init.d/system reload >/dev/null 2>&1
            say "Hostname set to $SYS_HOSTNAME"
            CHANGED=1
        else
            err "Failed to set the hostname (uci set/commit failed) - nothing was changed."
        fi
    else
        say "Skipped."
    fi
fi

[ "$CHANGED" = "0" ] && say "Nothing changed."
exit 0

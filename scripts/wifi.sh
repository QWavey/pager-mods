#!/bin/bash
#
# wifi.sh - Master WiFi kill-switch / restore for the WiFi Pineapple Pager.
#           Uses ONLY official Hak5 commands (WIFI_*, PINEAPPLE_*).
#
# --off silences everything the Pager is actively broadcasting/associating
# with: Management AP, Open AP, WPA AP, and the WiFi client connection.
# It records what was actually running (not blindly everything) so --on
# brings back exactly what was on before, nothing more.
#
# How restore works without a duplicate credential store: WIFI_*_AP_DISABLE
# only flips the interface's "disabled" flag - it does NOT erase the
# SSID/password already configured via WIFI_MGMT_AP / WIFI_OPEN_AP /
# WIFI_WPA_AP / WIFI_CONNECT. So --on reads those values back with a
# read-only `uci -q get` and re-issues the SAME official setter command
# that was already used to configure them - nothing is invented here.
#
# Recon channel hopping is paused/resumed unconditionally (harmless either
# way per the Hak5 docs). PCAP capture, Wigle logging, and SSID pool
# advertising are stopped on --off but deliberately NOT auto-resumed on
# --on - those are data-capture actions that should be restarted
# explicitly, not silently.
#
# Usage:
#   wifi.sh --off       Silence Mgmt/Open/WPA APs + WiFi client, pause recon hopping
#   wifi.sh --on        Restore whatever was silenced by the last --off
#   wifi.sh --status     Show current state
#   wifi.sh               interactive menu
#
# Options:
#   -y, --yes    Don't prompt for confirmation
#   -h, --help    This help

set -u
TOOL_NAME="wifi.sh"
CFG_NS="wifimaster"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

is_iface_enabled() {
    # is_iface_enabled IFACE -> 0 (enabled) or 1 (disabled OR never configured)
    # Must NOT default to "enabled" just because the uci query came back
    # empty - an interface that was never configured at all (fresh device,
    # e.g. wlan0open before EvilTwin.sh/config.sh has ever touched it) has
    # no uci section yet, and that must read as "off", not "on".
    if ! uci -q get "wireless.$1" >/dev/null 2>&1; then
        return 1
    fi
    local val
    val=$(uci -q get "wireless.$1.disabled" 2>/dev/null)
    [ "$val" = "1" ] && return 1
    return 0
}

DO_OFF=0
DO_ON=0
DO_STATUS=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --off) DO_OFF=1; shift ;;
        --on) DO_ON=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

show_status() {
    say "Current WiFi state:"
    echo
    for pair in "wlan0mgmt:Management AP" "wlan0open:Open AP" "wlan0wpa:WPA AP"; do
        iface="${pair%%:*}"; label="${pair#*:}"
        if is_iface_enabled "$iface"; then
            ssid=$(uci -q get "wireless.$iface.ssid" 2>/dev/null)
            echo "  $label ($iface): ON  - SSID: ${ssid:-?}"
        else
            echo "  $label ($iface): off"
        fi
    done
    # BUG FOUND AND FIXED: this used is_iface_enabled (a uci
    # "wireless.*.disabled" flag check) for wlan0cli too - but that flag is
    # what the AP-style _DISABLE commands toggle; the client uses
    # WIFI_CONNECT/WIFI_DISCONNECT instead, which have no documented reason
    # to touch that same flag. common.sh's own is_wifi_connected exists
    # specifically because wlan0cli's real state has to be read a different
    # way (the interface itself only exists once actually associated -
    # confirmed live, see lib/common.sh). Using the wrong check here likely
    # meant this always reported "ON" once wlan0cli had ever been
    # configured once, regardless of whether it was still connected.
    if is_wifi_connected; then
        ssid=$(uci -q get "wireless.wlan0cli.ssid" 2>/dev/null)
        echo "  WiFi client (wlan0cli): ON - SSID: ${ssid:-?}"
    else
        echo "  WiFi client (wlan0cli): off"
    fi
    echo
    if [ "$(cfg_get killed)" = "1" ]; then
        echo "  wifi.sh --off was used - state saved for --on:"
        for k in mgmt open wpa client; do
            [ "$(cfg_get was_${k}_on)" = "1" ] && echo "    - $k was on before --off"
        done
    fi
}

if [ "$DO_STATUS" = "1" ]; then
    show_status
    exit 0
fi

INTERACTIVE=0
[ "$DO_OFF" = "0" ] && [ "$DO_ON" = "0" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== wifi.sh interactive =="
    show_status
    echo
    echo "1) Turn WiFi off (kill switch)"
    echo "2) Turn WiFi back on (restore)"
    echo "3) Just show status"
    echo "0) Exit"
    choice=$(ask "Choose an option" "0")
    case "$choice" in
        1) DO_OFF=1 ;;
        2) DO_ON=1 ;;
        3) exit 0 ;;
        *) say "Nothing to do."; exit 0 ;;
    esac
fi

if [ "$DO_OFF" = "1" ]; then
    confirm "Turn off Management/Open/WPA APs, disconnect the WiFi client, and pause recon hopping?" || die "Aborted."

    say "Snapshotting and disabling active WiFi surfaces..."

    # BUG FOUND AND FIXED (found via code review): a kill switch that
    # silently fails to actually kill something is worse than no kill
    # switch at all - a user relying on "WiFi is off" for privacy/safety
    # before this fix had no way to know if one of the DISABLE calls
    # below had actually been rejected, since none of their exit codes
    # were checked and the final "WiFi is off" message printed
    # unconditionally regardless. Track failures and say so plainly,
    # both inline and in the final summary.
    KILL_FAILURES=0

    if is_iface_enabled "wlan0mgmt"; then
        say "Disabling Management AP..."
        WIFI_MGMT_AP_DISABLE wlan0mgmt || { err "Failed to disable the Management AP - it may still be broadcasting."; KILL_FAILURES=$((KILL_FAILURES + 1)); }
        cfg_set was_mgmt_on 1
    else
        cfg_set was_mgmt_on 0
    fi

    if is_iface_enabled "wlan0open"; then
        say "Disabling Open AP..."
        WIFI_OPEN_AP_DISABLE wlan0open || { err "Failed to disable the Open AP - it may still be broadcasting."; KILL_FAILURES=$((KILL_FAILURES + 1)); }
        cfg_set was_open_on 1
    else
        cfg_set was_open_on 0
    fi

    if is_iface_enabled "wlan0wpa"; then
        say "Disabling WPA AP..."
        WIFI_WPA_AP_DISABLE wlan0wpa || { err "Failed to disable the WPA AP - it may still be broadcasting."; KILL_FAILURES=$((KILL_FAILURES + 1)); }
        cfg_set was_wpa_on 1
    else
        cfg_set was_wpa_on 0
    fi

    # Same is_wifi_connected fix as show_status() above - is_iface_enabled
    # checks the wrong signal for the client interface, which could make
    # --off think the client "was on" (and --on then reconnect it) even
    # when the user had already disconnected it deliberately beforehand.
    if is_wifi_connected; then
        say "Disconnecting WiFi client..."
        WIFI_DISCONNECT wlan0cli || { err "Failed to disconnect the WiFi client - it may still be associated."; KILL_FAILURES=$((KILL_FAILURES + 1)); }
        cfg_set was_client_on 1
    else
        cfg_set was_client_on 0
    fi

    say "Pausing recon channel hopping..."
    PINEAPPLE_HOPPING_STOP 2>/dev/null

    say "Stopping PCAP capture / Wigle logging / SSID pool advertising (not auto-resumed on --on)..."
    WIFI_PCAP_STOP 2>/dev/null
    WIGLE_STOP 2>/dev/null
    PINEAPPLE_SSID_POOL_STOP 2>/dev/null

    cfg_set killed 1
    if [ "$KILL_FAILURES" -eq 0 ]; then
        say "WiFi is off. Run 'wifi.sh --on' to restore."
    else
        err "WiFi is NOT fully off - $KILL_FAILURES surface(s) above failed to disable. Check 'wifi.sh --status' and retry before relying on this as a kill switch."
    fi
fi

if [ "$DO_ON" = "1" ]; then
    if [ "$(cfg_get killed)" != "1" ]; then
        say "No 'wifi.sh --off' snapshot found - nothing to restore. (Resuming recon hopping anyway.)"
    fi

    say "Resuming recon channel hopping..."
    PINEAPPLE_HOPPING_START 2>/dev/null

    if [ "$(cfg_get was_mgmt_on)" = "1" ]; then
        ssid=$(uci -q get "wireless.wlan0mgmt.ssid" 2>/dev/null)
        key=$(uci -q get "wireless.wlan0mgmt.key" 2>/dev/null)
        enc=$(uci -q get "wireless.wlan0mgmt.encryption" 2>/dev/null); [ -z "$enc" ] && enc="sae-mixed"
        if [ -n "$ssid" ] && [ -n "$key" ]; then
            say "Restoring Management AP '$ssid'..."
            WIFI_MGMT_AP wlan0mgmt "$ssid" "$enc" "$key" || err "Restoring Management AP failed."
        else
            err "Could not restore Management AP - SSID/key missing from saved config. Use config.sh to reconfigure it."
        fi
    fi

    if [ "$(cfg_get was_open_on)" = "1" ]; then
        ssid=$(uci -q get "wireless.wlan0open.ssid" 2>/dev/null)
        if [ -n "$ssid" ]; then
            say "Restoring Open AP '$ssid'..."
            WIFI_OPEN_AP wlan0open "$ssid" || err "Restoring Open AP failed."
        else
            err "Could not restore Open AP - SSID missing from saved config."
        fi
    fi

    if [ "$(cfg_get was_wpa_on)" = "1" ]; then
        ssid=$(uci -q get "wireless.wlan0wpa.ssid" 2>/dev/null)
        key=$(uci -q get "wireless.wlan0wpa.key" 2>/dev/null)
        enc=$(uci -q get "wireless.wlan0wpa.encryption" 2>/dev/null); [ -z "$enc" ] && enc="psk2"
        if [ -n "$ssid" ] && [ -n "$key" ]; then
            say "Restoring WPA AP '$ssid'..."
            WIFI_WPA_AP wlan0wpa "$ssid" "$enc" "$key" || err "Restoring WPA AP failed."
        else
            err "Could not restore WPA AP - SSID/key missing from saved config. Use EvilTwin.sh --on instead if this was a clone AP."
        fi
    fi

    if [ "$(cfg_get was_client_on)" = "1" ]; then
        ssid=$(uci -q get "wireless.wlan0cli.ssid" 2>/dev/null)
        key=$(uci -q get "wireless.wlan0cli.key" 2>/dev/null)
        enc=$(uci -q get "wireless.wlan0cli.encryption" 2>/dev/null); [ -z "$enc" ] && enc="psk2"
        if [ -n "$ssid" ]; then
            say "Reconnecting WiFi client to '$ssid'..."
            if [ -n "$key" ]; then
                WIFI_CONNECT wlan0cli "$ssid" "$enc" "$key" ANY
            else
                WIFI_CONNECT wlan0cli "$ssid" open NONE ANY
            fi
            WIFI_WAIT wlan0cli 30
        else
            err "Could not reconnect WiFi client - SSID missing from saved config."
        fi
    fi

    cfg_set killed 0
    say "Done. PCAP capture, Wigle logging, and SSID pool advertising were NOT auto-resumed - restart those explicitly if you want them (EvilTwin.sh --record / WIGLE_START / PINEAPPLE_SSID_POOL_START)."
fi

exit 0

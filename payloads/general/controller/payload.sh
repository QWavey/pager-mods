#!/bin/bash
# Title: Controller
# Author: florian
# Description: On-screen launcher grid (3×2 themes). Pick a theme, it presents
# submenu with all available tools, gathers parameters on-screen, manages state.
# Version: 2.0
#
# All toolkit scripts are accessible via on-screen menus with parameter gathering
# and persistent state (/root/loot/*). No SSH needed on-site.

S=/root/scripts
CONTROLLER_LIB="$(dirname "$0")/lib"

# Source the modular tool UI library (all tool_*_menu functions)
if [ -f "$CONTROLLER_LIB/tool_ui.sh" ]; then
    . "$CONTROLLER_LIB/tool_ui.sh"
fi

# need SCRIPT - guard that a backing script is present
need() {
    if [ ! -x "$S/$1" ]; then
        ERROR_DIALOG "$1 not found - run the toolkit setup.py first."
        return 1
    fi
    return 0
}

# find_external_wifi - first wlan2+ (external adapter)
find_external_wifi() {
    for i in /sys/class/net/wlan[2-9]; do
        [ -e "$i" ] && { basename "$i"; return 0; }
    done
    return 1
}

# -- WiFi theme (airscout, deauth, wifikit, wpskit, EvilTwin, ssidpool) -----
theme_wifi() {
    local a
    a=$(LIST_PICKER "WiFi" "WiFi Recon (Airscout)" "Deauth Target" "Capture (Wifikit)" "WPS (Wpskit)" "Evil Twin" "Beacon Flood" "Back" "WiFi Recon (Airscout)") || return
    case "$a" in
    "WiFi Recon (Airscout)")    need airscout.sh && tool_airscout_menu ;;
    "Deauth Target")            need deauth.sh && tool_deauth_menu ;;
    "Capture (Wifikit)")        need wifikit.sh && tool_wifikit_menu ;;
    "WPS (Wpskit)")             need wpskit.sh && tool_wpskit_menu ;;
    "Evil Twin")                need EvilTwin.sh && tool_eviltwin_menu ;;
    "Beacon Flood")             need ssidpool.sh && tool_ssidpool_menu ;;
    esac
}

# -- LAN theme (LanScan, lanpwn, clientiso, dnsspoof, deadnet, topomap) -----
theme_lan() {
    local a
    a=$(LIST_PICKER "LAN" "Scan (LanScan)" "Auto-Pwn (Lanpwn)" "Isolation Test" "DNS Spoof" "LAN Kill" "Topology Map" "Back" "Scan (LanScan)") || return
    case "$a" in
    "Scan (LanScan)")           need LanScan.sh && tool_lanscan_menu ;;
    "Auto-Pwn (Lanpwn)")        need lanpwn.sh && tool_lanpwn_menu ;;
    "Isolation Test")           need clientiso.sh && tool_clientiso_menu ;;
    "DNS Spoof")                need dnsspoof.sh && tool_dnsspoof_menu ;;
    "LAN Kill")                 need deadnet.sh && tool_deadnet_menu ;;
    "Topology Map")             need topomap.sh && tool_topomap_menu ;;
    esac
}

# -- Bluetooth theme (scan, flood, jam, adv-spam, disrupt) -----------------
theme_bluetooth() {
    local a
    a=$(LIST_PICKER "Bluetooth" "Scan" "Flood Target" "Jam Area" "Adv Spam" "Disrupt" "Back" "Scan") || return
    need bluetooth.sh || return
    case "$a" in
    "Scan")         tool_bluetooth_menu ;; # which internally calls bluetooth.sh --scan
    "Flood Target") tool_bluetooth_menu ;;
    "Jam Area")     tool_bluetooth_menu ;;
    "Adv Spam")     tool_bluetooth_menu ;;
    "Disrupt")      tool_bluetooth_menu ;;
    esac
}

# -- Dual-Radio theme (internal twin+deauth herd, rogue 5GHz, adapter info) --
theme_dualradio() {
    local ext
    ext=$(find_external_wifi)
    local label; [ -n "$ext" ] && label="Dual-Radio ($ext found)" || label="Dual-Radio (no external)"

    local a
    a=$(LIST_PICKER "$label" "Evil Twin + Deauth" "Rogue 5GHz AP" "Adapter Info" "Back" "Evil Twin + Deauth") || return
    case "$a" in
    "Evil Twin + Deauth")
        need EvilTwin.sh deauth.sh || return
        local ssid
        ssid=$(TEXT_PICKER "AP SSID (internal twin)" "FreeWiFi") || return
        CONFIRMATION_DIALOG "Start internal twin ($ssid) + internal deauth until B?" || return
        LOG "Starting twin + deauth herd..."
        "$S/EvilTwin.sh" --open "$ssid" -y >/tmp/twin.log 2>&1
        if ! "$S/deauth.sh" --broadcast --channel 1 -y >/tmp/deauth.log 2>&1; then
            "$S/EvilTwin.sh" --off -y
            ERROR_DIALOG "Deauth failed."
            return
        fi
        ALERT "Twin ($ssid) + deauth running - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deauth.sh" --stop -y >/dev/null 2>&1
        "$S/EvilTwin.sh" --off -y >/dev/null 2>&1
        ALERT "Herd stopped"
        ;;
    "Rogue 5GHz AP")
        [ -z "$ext" ] && { ERROR_DIALOG "No external adapter - plug in the A8000."; return; }
        need rogueap.sh || return
        tool_rogueap_menu
        ;;
    "Adapter Info")
        [ -z "$ext" ] && { LOG "No external adapter detected."; return; }
        LOG "External adapter: $ext"
        LOG "$(iw dev "$ext" info 2>&1)"
        iw phy "phy$(cat /sys/class/net/$ext/phy80211/name 2>/dev/null | sed 's/phy//')" info 2>/dev/null | grep -A6 'Supported interface modes' | head -20 | xargs LOG
        ALERT "Adapter info logged"
        ;;
    esac
}

# -- Implant theme (U1-U4: usbclone, walledgarden, stealthnet, mgmt) --------
theme_implant() {
    local a
    a=$(LIST_PICKER "Implant" "USB-C Device Clone" "DNS Walled-Garden" "Stealth Intercept" "Mgmt AP (OOB)" "Gadget Drop (planned)" "Back" "USB-C Device Clone") || return
    case "$a" in
    "USB-C Device Clone")       need usbclone.sh && tool_usbclone_menu ;;
    "DNS Walled-Garden")        need walledgarden.sh && tool_walledgarden_menu ;;
    "Stealth Intercept")        need stealthnet.sh && tool_stealthnet_menu ;;
    "Mgmt AP (OOB)")            need mgmt.sh && tool_mgmt_menu ;;
    "Gadget Drop (planned)")    ALERT "USB-C PoisonTap gadget - coming soon" ;;
    esac
}

# -- Loot theme (list, save, archive, clear) --------------------------------
theme_loot() {
    need loot.sh || return
    tool_loot_menu
}

# -- main loop ---------------------------------------------------------------
while :; do
    __t=$(LIST_PICKER "Controller" "WiFi" "LAN" "Bluetooth" "Dual-Radio" "Implant" "Loot" "WiFi") || exit 0
    case "$__t" in
        "WiFi")       theme_wifi ;;
        "LAN")        theme_lan ;;
        "Bluetooth")  theme_bluetooth ;;
        "Dual-Radio") theme_dualradio ;;
        "Implant")    theme_implant ;;
        "Loot")       theme_loot ;;
    esac
done

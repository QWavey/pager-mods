#!/bin/bash
# tool_ui.sh - on-screen UI wrappers for each tool in the toolkit.
# Handles parameter gathering, state persistence, and reset/clear options.
# Sourced into payload.sh; uses Hak5 primitives (LIST_PICKER, TEXT_PICKER, etc).

# -- usbclone: device identity clone/restore ------------------------------------
# Presents: capture PC identity from tethered host / clone to LAN adapter /
# restore original / show captured identity / clear state.
tool_usbclone_menu() {
    local act
    act=$(LIST_PICKER "USB-C Device Clone" "Capture identity from tethered PC" "Clone to LAN adapter (eth1)" "Show captured identity" "Restore original MAC" "Reset state" "Back" "Capture identity from tethered PC") || return
    case "$act" in
    "Capture identity from tethered PC")
        CONFIRMATION_DIALOG "Plug the Pager's USB-C into the target PC (it will DHCP and leak its identity). Ready?" || return
        LOG "Capturing PC identity from eth0 tether..."
        "$S/usbclone.sh" --capture --iface eth1 -y >/tmp/usbclone.log 2>&1
        if [ -f /root/loot/usbclone/identity.env ]; then
            LOG "Identity captured: $(cat /root/loot/usbclone/identity.env | head -1)"
            ALERT "Captured. Unplug USB-C, then select 'Clone to LAN' to apply."
        else
            ERROR_DIALOG "Capture failed - see logs."
        fi
        ;;
    "Clone to LAN adapter (eth1)")
        if [ ! -f /root/loot/usbclone/identity.env ]; then
            ERROR_DIALOG "No identity captured yet. Plug the Pager into the target PC first."
            return
        fi
        CONFIRMATION_DIALOG "Apply captured identity to eth1 (USB-A adapter)? You can restore later." || return
        LOG "Cloning identity to eth1..."
        "$S/usbclone.sh" --clone --iface eth1 -y >/tmp/usbclone.log 2>&1
        ALERT "Cloned. Now plug eth1 into the target LAN - it will DHCP as the captured device."
        ;;
    "Show captured identity")
        if [ -f /root/loot/usbclone/identity.env ]; then
            LOG "Captured identity: $(cat /root/loot/usbclone/identity.env)"
        else
            LOG "No identity captured yet."
        fi
        ;;
    "Restore original MAC")
        CONFIRMATION_DIALOG "Restore eth1 to its real MAC? (Undo the clone.)" || return
        LOG "Restoring eth1's original MAC..."
        "$S/usbclone.sh" --restore --iface eth1 -y >/tmp/usbclone.log 2>&1
        ALERT "Restored. eth1 is back to normal."
        ;;
    "Reset state")
        CONFIRMATION_DIALOG "Clear all captured identities and restore eth1? This is permanent." || return
        rm -rf /root/loot/usbclone
        "$S/usbclone.sh" --restore --iface eth1 -y >/dev/null 2>&1
        ALERT "State cleared."
        ;;
    esac
}

# -- walledgarden: DNS walled garden redirect ------------------------------------
# Presents: enable / disable / status / set allowed IP.
tool_walledgarden_menu() {
    local act
    act=$(LIST_PICKER "DNS Walled Garden" "Enable" "Disable" "Status" "Set allowed IP" "Back" "Enable") || return
    case "$act" in
    "Enable")
        local ip
        ip=$(TEXT_PICKER "Allowed IP address" "172.16.52.1") || return
        CONFIRMATION_DIALOG "Every DNS lookup will resolve to $ip. Continue?" || return
        LOG "Enabling walled garden..."
        "$S/walledgarden.sh" --on --ip "$ip" -y >/tmp/wg.log 2>&1
        ALERT "Walled garden active on $ip."
        ;;
    "Disable")
        LOG "Disabling walled garden..."
        "$S/walledgarden.sh" --off -y >/dev/null 2>&1
        ALERT "Walled garden OFF - normal DNS restored."
        ;;
    "Status")
        local status
        status=$("$S/walledgarden.sh" --status 2>&1)
        LOG "$status"
        ;;
    "Set allowed IP")
        local ip
        ip=$(TEXT_PICKER "Allowed IP" "172.16.52.1") || return
        say "To change the IP, disable and re-enable with the new address."
        ;;
    esac
}

# -- stealthnet: silent intercept -----------------------------------------------
# Presents: enable / disable / status.
tool_stealthnet_menu() {
    local act
    act=$(LIST_PICKER "Stealth Intercept" "Enable (intercept tethered host)" "Disable" "Status" "Back" "Enable (intercept tethered host)") || return
    case "$act" in
    "Enable (intercept tethered host)")
        CONFIRMATION_DIALOG "Make the tethered PC see hanging internet (silent forward+capture). Only on authorized networks!" || return
        LOG "Starting stealth intercept..."
        "$S/stealthnet.sh" --on --host-iface br-lan -y >/tmp/stealth.log 2>&1
        ALERT "Intercept active - host sees no internet, Pager captures traffic."
        ;;
    "Disable")
        LOG "Disabling stealth intercept..."
        "$S/stealthnet.sh" --off -y >/dev/null 2>&1
        ALERT "Stealth intercept OFF - host's internet works normally."
        ;;
    "Status")
        local status
        status=$("$S/stealthnet.sh" --status 2>&1)
        LOG "$status"
        ;;
    esac
}

# -- topomap: network topology mapper -------------------------------------------
# Presents: scan / show results / clear.
tool_topomap_menu() {
    local act
    act=$(LIST_PICKER "Network Topology" "Scan wired LAN" "Show last scan" "Clear results" "Back" "Scan wired LAN") || return
    case "$act" in
    "Scan wired LAN")
        local duration
        duration=$(NUMBER_PICKER "Scan duration (seconds)" "30") || return
        LOG "Mapping network topology on eth1 (${duration}s)..."
        "$S/topomap.sh" --scan --duration "$duration" --iface eth1 -y >/tmp/topo.log 2>&1
        local result
        result=$("$S/topomap.sh" --show 2>&1 | head -50)
        LOG "$result"
        ;;
    "Show last scan")
        local result
        result=$("$S/topomap.sh" --show 2>&1 | head -50)
        if [ -z "$result" ]; then
            LOG "No scan results yet. Run a scan first."
        else
            LOG "$result"
        fi
        ;;
    "Clear results")
        rm -rf /root/loot/topomap
        ALERT "Topology cache cleared."
        ;;
    esac
}

export -f tool_usbclone_menu tool_walledgarden_menu tool_stealthnet_menu tool_topomap_menu

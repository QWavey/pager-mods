#!/bin/bash
# tool_ui.sh - on-screen UI wrappers for every tool in the toolkit.
# Handles parameter gathering, state persistence, mode selection, and reset.
# Sourced into payload.sh; uses Hak5 primitives (LIST_PICKER, TEXT_PICKER, etc).

S=${S:-/root/scripts}

# -- WiFi theme tools ---------------------------------------------------------------

# airscout: passive 802.11 recon + client fingerprint
tool_airscout_menu() {
    local act
    act=$(LIST_PICKER "WiFi Recon (Airscout)" "Scan for APs and clients" "Show last scan" "Client OS fingerprint" "PMF posture report" "Clear cache" "Back" "Scan for APs and clients") || return
    case "$act" in
    "Scan for APs and clients")
        LOG "Scanning WiFi (passive, no association)..."
        "$S/airscout.sh" --scan -y >/tmp/airscout.log 2>&1
        local result; result=$("$S/airscout.sh" --report 2>&1 | head -40)
        LOG "$result"
        ALERT "Scan done - $(cat /tmp/airscout.log | grep -c 'SSID' || echo '?') APs found"
        ;;
    "Show last scan")
        local result; result=$("$S/airscout.sh" --report 2>&1 | head -50)
        [ -n "$result" ] && LOG "$result" || LOG "No scan results yet."
        ;;
    "Client OS fingerprint")
        LOG "Analyzing client probe requests (OS fingerprints from rand-MAC + IE patterns)..."
        "$S/airscout.sh" --clients -y 2>&1 | head -50 | xargs LOG
        ;;
    "PMF posture report")
        LOG "Checking AP 802.11w (PMF) posture..."
        "$S/airscout.sh" --pmf -y 2>&1 | head -50 | xargs LOG
        ;;
    "Clear cache")
        rm -rf /root/loot/airscout 2>/dev/null
        ALERT "Airscout cache cleared."
        ;;
    esac
}

# deauth: targeted deauth against a specific AP + client
tool_deauth_menu() {
    local act
    act=$(LIST_PICKER "Deauth (Target)" "Pick target AP and client" "Show running" "Stop" "Back" "Pick target AP and client") || return
    case "$act" in
    "Pick target AP and client")
        local bssid client channel
        bssid=$(MAC_PICKER "Target AP MAC" "") || return
        client=$(MAC_PICKER "Target client (or broadcast)" "") || return
        channel=$(NUMBER_PICKER "Channel" "1") || return
        CONFIRMATION_DIALOG "Deauth $client from $bssid on CH$channel?" || return
        LOG "Starting deauth..."
        "$S/deauth.sh" --bssid "$bssid" --client "$client" --channel "$channel" -y >/tmp/deauth.log 2>&1
        ALERT "Deauth running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deauth.sh" --stop -y >/dev/null 2>&1
        ALERT "Deauth stopped"
        ;;
    "Show running")
        [ -f /tmp/pager-deauth.pid ] && LOG "Deauth running (PID $(cat /tmp/pager-deauth.pid))" || LOG "Not running"
        ;;
    "Stop")
        "$S/deauth.sh" --stop -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    esac
}

# wifikit: WPA handshake + PMKID capture/crack
tool_wifikit_menu() {
    local act
    act=$(LIST_PICKER "WiFi Capture (Wifikit)" "Capture handshake/PMKID" "Convert to hashline" "Crack with wordlist" "Show captures" "Clear" "Back" "Capture handshake/PMKID") || return
    case "$act" in
    "Capture handshake/PMKID")
        local secs channel
        secs=$(NUMBER_PICKER "Capture duration (sec)" "60") || return
        channel=$(NUMBER_PICKER "Channel (0=hop)" "0") || return
        LOG "Capturing handshakes/PMKID on external adapter..."
        "$S/wifikit.sh" --capture --seconds "$secs" $([ "$channel" != "0" ] && echo "--channel $channel") -y >/tmp/wifikit.log 2>&1
        ALERT "Capture done - convert or crack"
        ;;
    "Convert to hashline")
        LOG "Converting latest capture to 22000 hashline..."
        local hash; hash=$("$S/wifikit.sh" --convert -y 2>&1)
        LOG "$hash"
        ALERT "Hashline ready (pull off-box for hashcat or --crack)"
        ;;
    "Crack with wordlist")
        local wl; wl=$(TEXT_PICKER "Wordlist path" "/root/wordlist.txt") || return
        LOG "Cracking with aircrack-ng (slow on MIPS)..."
        "$S/wifikit.sh" --crack --wordlist "$wl" -y 2>&1 | tee /tmp/wifikit-crack.log | head -50 | xargs LOG
        ;;
    "Show captures")
        LOG "$(ls -lt /root/loot/wifikit/*.pcapng 2>/dev/null | head -10)"
        ;;
    "Clear")
        rm -rf /root/loot/wifikit 2>/dev/null
        ALERT "Wifikit loot cleared"
        ;;
    esac
}

# wpskit: WPS scan + Pixie-Dust
tool_wpskit_menu() {
    local act
    act=$(LIST_PICKER "WPS (Wpskit)" "Scan for WPS APs" "Pixie-Dust attack" "Show results" "Clear" "Back" "Scan for WPS APs") || return
    case "$act" in
    "Scan for WPS APs")
        LOG "Scanning for WPS-enabled APs (needs external adapter)..."
        "$S/wpskit.sh" --scan -y 2>&1 | tee /tmp/wpskit-scan.log | head -40 | xargs LOG
        ;;
    "Pixie-Dust attack")
        local bssid
        bssid=$(MAC_PICKER "Target AP MAC" "") || return
        CONFIRMATION_DIALOG "Run Pixie-Dust attack on $bssid?" || return
        LOG "Attacking $bssid (reaver pixie)..."
        "$S/wpskit.sh" --pixie --bssid "$bssid" -y 2>&1 | tee /tmp/wpskit-pixie.log | head -50 | xargs LOG
        ;;
    "Show results")
        LOG "$(cat /tmp/wpskit-scan.log 2>/dev/null | head -50)"
        ;;
    "Clear")
        rm -rf /root/loot/wpskit 2>/dev/null
        ALERT "WPS results cleared"
        ;;
    esac
}

# EvilTwin: clone an AP
tool_eviltwin_menu() {
    local act
    act=$(LIST_PICKER "Evil Twin (Clone AP)" "Pick an AP to clone" "Manual SSID" "Stop" "Back" "Pick an AP to clone") || return
    case "$act" in
    "Pick an AP to clone")
        local ssid
        ssid=$(TEXT_PICKER "SSID to clone" "WiFi") || return
        CONFIRMATION_DIALOG "Clone '$ssid' with open auth?" || return
        LOG "Starting Evil Twin on internal radio..."
        "$S/EvilTwin.sh" --cloned "$ssid" -y >/tmp/eviltwin.log 2>&1
        ALERT "Twin up - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/EvilTwin.sh" --off -y >/dev/null 2>&1
        ALERT "Twin stopped"
        ;;
    "Manual SSID")
        local ssid
        ssid=$(TEXT_PICKER "New SSID" "FreeWiFi") || return
        LOG "Starting Evil Twin..."
        "$S/EvilTwin.sh" --open "$ssid" -y >/tmp/eviltwin.log 2>&1
        ALERT "Open AP '$ssid' running - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/EvilTwin.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Stop")
        "$S/EvilTwin.sh" --off -y >/dev/null 2>&1
        ALERT "Evil Twin OFF"
        ;;
    esac
}

# ssidpool: beacon flood with SSID pool
tool_ssidpool_menu() {
    local act
    act=$(LIST_PICKER "Beacon Flood" "Start auto-collect + flood" "Stop" "Show SSIDs" "Back" "Start auto-collect + flood") || return
    case "$act" in
    "Start auto-collect + flood")
        CONFIRMATION_DIALOG "Collect nearby SSIDs and flood until B?" || return
        LOG "Starting beacon flood..."
        "$S/ssidpool.sh" --collect on -y >/dev/null 2>&1
        "$S/ssidpool.sh" --on random -y >/tmp/ssidpool.log 2>&1 || { ERROR_DIALOG "Flood failed"; return; }
        ALERT "Beacon flood running - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/ssidpool.sh" --off -y >/dev/null 2>&1
        "$S/ssidpool.sh" --collect off -y >/dev/null 2>&1
        ALERT "Flood stopped"
        ;;
    "Stop")
        "$S/ssidpool.sh" --off -y >/dev/null 2>&1
        ALERT "Flood stopped"
        ;;
    "Show SSIDs")
        [ -f /root/loot/ssidpool/pool.txt ] && LOG "$(head -20 /root/loot/ssidpool/pool.txt)" || LOG "No pool yet"
        ;;
    esac
}

# -- LAN theme tools ----------------------------------------------------------------

# LanScan: deep scan with multiple modes
tool_lanscan_menu() {
    local act
    act=$(LIST_PICKER "LAN Scan (Deep)" "Ping sweep" "Quick scan" "Service scan" "Full + vuln" "Show results" "Back" "Quick scan") || return
    case "$act" in
    "Ping sweep"|"Quick scan"|"Service scan"|"Full + vuln")
        local mode="${act%% *}"
        [ "$act" = "Ping sweep" ] && mode="ping"
        [ "$act" = "Quick scan" ] && mode="quick"
        [ "$act" = "Service scan" ] && mode="service"
        [ "$act" = "Full + vuln" ] && mode="full"
        LOG "Running $mode scan on eth1..."
        "$S/LanScan.sh" --mode "$mode" --iface eth1 -y 2>&1 | tee /tmp/lanscan.log | head -100 | xargs LOG
        ;;
    "Show results")
        LOG "$(cat /tmp/lanscan.log 2>/dev/null | head -50)"
        ;;
    esac
}

# lanpwn: auto-pwn (discover + NSE + creds + SMB loot)
tool_lanpwn_menu() {
    local act
    act=$(LIST_PICKER "LAN Auto-Pwn" "Full auto-pwn" "Discovery only" "NSE vuln scan" "Default creds" "SMB loot" "Show report" "Back" "Full auto-pwn") || return
    case "$act" in
    "Full auto-pwn")
        CONFIRMATION_DIALOG "Scan, NSE, creds, SMB on eth1? (several minutes, auth networks only)" || return
        LOG "Auto-pwn running..."
        "$S/lanpwn.sh" --auto --iface eth1 -y 2>&1 | tee /tmp/lanpwn.log | tail -50 | xargs LOG
        ALERT "Done - see /root/loot/lanpwn/"
        ;;
    "Discovery only")
        LOG "Discovering hosts on eth1..."
        "$S/lanpwn.sh" --scan --iface eth1 -y 2>&1 | head -50 | xargs LOG
        ;;
    "NSE vuln scan")
        LOG "Running NSE scripts on discovered services..."
        "$S/lanpwn.sh" --nse --iface eth1 -y 2>&1 | head -80 | xargs LOG
        ;;
    "Default creds")
        LOG "Probing HTTP/FTP default credentials..."
        "$S/lanpwn.sh" --creds --iface eth1 -y 2>&1 | head -50 | xargs LOG
        ;;
    "SMB loot")
        LOG "Enumerating and looting SMB shares..."
        "$S/lanpwn.sh" --smb --iface eth1 -y 2>&1 | head -50 | xargs LOG
        ;;
    "Show report")
        [ -f /root/loot/lanpwn/REPORT.txt ] && LOG "$(cat /root/loot/lanpwn/REPORT.txt)" || LOG "No report yet"
        ;;
    esac
}

# clientiso: test client isolation
tool_clientiso_menu() {
    local act
    act=$(LIST_PICKER "Client Isolation Test" "Scan for isolated clients" "Test isolation" "Show results" "Back" "Test isolation") || return
    case "$act" in
    "Scan for isolated clients"|"Test isolation")
        LOG "Testing client-to-client reachability on eth1..."
        "$S/clientiso.sh" --iface eth1 -y 2>&1 | tee /tmp/clientiso.log | head -50 | xargs LOG
        ALERT "Isolation test done"
        ;;
    "Show results")
        LOG "$(cat /tmp/clientiso.log 2>/dev/null)"
        ;;
    esac
}

# dnsspoof: DNS redirect
tool_dnsspoof_menu() {
    local act
    act=$(LIST_PICKER "DNS Spoof" "Add redirect" "List redirects" "Start spoofing" "Stop" "Clear" "Back" "Start spoofing") || return
    case "$act" in
    "Add redirect")
        local domain ip
        domain=$(TEXT_PICKER "Domain to redirect" "example.com") || return
        ip=$(TEXT_PICKER "Redirect to IP" "172.16.52.1") || return
        LOG "Adding $domain -> $ip..."
        "$S/dnsspoof.sh" --add "$domain" "$ip" -y >/dev/null 2>&1
        ALERT "Added"
        ;;
    "List redirects")
        LOG "$("$S/dnsspoof.sh" --list 2>&1)"
        ;;
    "Start spoofing")
        CONFIRMATION_DIALOG "Start DNS spoofing on eth1 (redirects added above)?" || return
        "$S/dnsspoof.sh" --on --iface eth1 -y >/tmp/dnsspoof.log 2>&1
        ALERT "DNS spoofing running - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/dnsspoof.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Stop")
        "$S/dnsspoof.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Clear")
        "$S/dnsspoof.sh" --clear -y >/dev/null 2>&1
        ALERT "Cleared"
        ;;
    esac
}

# deadnet: LAN kill (silent disconnect)
tool_deadnet_menu() {
    local act
    act=$(LIST_PICKER "LAN Kill (DeadNet)" "Disconnect a host" "Disconnect all" "Stop" "Back" "Disconnect a host") || return
    case "$act" in
    "Disconnect a host")
        local ip
        ip=$(TEXT_PICKER "Target IP to disconnect" "") || return
        CONFIRMATION_DIALOG "Silently disconnect $ip from the gateway?" || return
        LOG "Killing $ip..."
        "$S/deadnet.sh" --ip "$ip" --iface eth1 -y >/tmp/deadnet.log 2>&1
        ALERT "Disconnected - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deadnet.sh" --stop -y >/dev/null 2>&1
        ;;
    "Disconnect all")
        CONFIRMATION_DIALOG "Disconnect ALL hosts on eth1 from gateway?" || return
        LOG "Killing all..."
        "$S/deadnet.sh" --all --iface eth1 -y >/tmp/deadnet.log 2>&1
        ALERT "All disconnected - B to restore"
        WAIT_FOR_BUTTON_PRESS B
        "$S/deadnet.sh" --stop -y >/dev/null 2>&1
        ;;
    "Stop")
        "$S/deadnet.sh" --stop -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    esac
}

# -- Bluetooth theme ----------------------------------------------------------------

tool_bluetooth_menu() {
    local act
    act=$(LIST_PICKER "Bluetooth" "Scan" "Flood a target" "Jam area" "Adv spam" "Disrupt" "Stop" "Back" "Scan") || return
    case "$act" in
    "Scan")
        LOG "Scanning for Bluetooth devices..."
        "$S/bluetooth.sh" --scan -y 2>&1 | head -50 | xargs LOG
        ;;
    "Flood a target")
        local addr; addr=$(TEXT_PICKER "Target BT MAC" "") || return
        LOG "Flooding $addr..."
        "$S/bluetooth.sh" --flood --target "$addr" -y >/tmp/bt.log 2>&1
        ALERT "Flooding - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop -y >/dev/null 2>&1
        ;;
    "Jam area")
        LOG "Jamming BT in area..."
        "$S/bluetooth.sh" --jam -y >/tmp/bt.log 2>&1
        ALERT "Jamming - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop -y >/dev/null 2>&1
        ;;
    "Adv spam")
        LOG "Spamming BT advertisements..."
        "$S/bluetooth.sh" --adv --spam -y >/tmp/bt.log 2>&1
        ALERT "Spamming - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop -y >/dev/null 2>&1
        ;;
    "Disrupt")
        LOG "Disrupting BT connections..."
        "$S/bluetooth.sh" --disrupt -y >/tmp/bt.log 2>&1
        ALERT "Disrupting - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/bluetooth.sh" --stop -y >/dev/null 2>&1
        ;;
    "Stop")
        "$S/bluetooth.sh" --stop -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    esac
}

# -- Dual-Radio theme ---------------------------------------------------------------

tool_rogueap_menu() {
    local act
    act=$(LIST_PICKER "Rogue 5GHz AP" "Start on external adapter" "With NAT uplink" "Stop" "Status" "Back" "Start on external adapter") || return
    case "$act" in
    "Start on external adapter")
        local ssid pw
        ssid=$(TEXT_PICKER "AP SSID" "FakeNetwork-5GHz") || return
        pw=$(TEXT_PICKER "Password (leave blank for open)" "") || return
        LOG "Starting 5GHz rogue AP on the external adapter..."
        if [ -n "$pw" ]; then
            "$S/rogueap.sh" --on --ssid "$ssid" --password "$pw" -y >/tmp/rogueap.log 2>&1
        else
            "$S/rogueap.sh" --on --ssid "$ssid" -y >/tmp/rogueap.log 2>&1
        fi
        ALERT "5GHz AP up - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/rogueap.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "With NAT uplink")
        local ssid
        ssid=$(TEXT_PICKER "AP SSID" "Uplink-5GHz") || return
        LOG "Starting 5GHz AP with NAT uplink..."
        "$S/rogueap.sh" --on --ssid "$ssid" --nat -y >/tmp/rogueap.log 2>&1
        ALERT "5GHz AP + NAT up - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/rogueap.sh" --off -y >/dev/null 2>&1
        ;;
    "Stop")
        "$S/rogueap.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Status")
        LOG "$("$S/rogueap.sh" --status 2>&1)"
        ;;
    esac
}

# -- Implant / Loot themes ----------------------------------------------------------

# usbclone: already defined above, include here for completeness
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

# walledgarden: already defined above
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

# stealthnet: already defined above
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

# topomap: already defined above
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

# mgmt: out-of-band management AP
tool_mgmt_menu() {
    local act
    act=$(LIST_PICKER "Out-of-Band Mgmt AP" "Start management AP" "Stop" "Status" "Back" "Start management AP") || return
    case "$act" in
    "Start management AP")
        local ssid pw
        ssid=$(TEXT_PICKER "Mgmt AP SSID" "pager-oob") || return
        pw=$(TEXT_PICKER "Mgmt AP password (>=8 chars, blank=default)" "") || return
        if [ -n "$pw" ] && [ "${#pw}" -lt 8 ]; then
            ERROR_DIALOG "Password must be 8+ characters."
            return
        fi
        LOG "Starting out-of-band mgmt AP..."
        if [ -n "$pw" ]; then
            "$S/mgmt.sh" --on --name "$ssid" --pw "$pw" -y >/tmp/mgmt.log 2>&1
        else
            "$S/mgmt.sh" --on --name "$ssid" -y >/tmp/mgmt.log 2>&1
        fi
        ALERT "Mgmt AP '$ssid' up on 172.16.52.1 - B to stop"
        WAIT_FOR_BUTTON_PRESS B
        "$S/mgmt.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Stop")
        "$S/mgmt.sh" --off -y >/dev/null 2>&1
        ALERT "Stopped"
        ;;
    "Status")
        LOG "$("$S/mgmt.sh" --status 2>&1)"
        ;;
    esac
}

# loot: list/save/archive
tool_loot_menu() {
    local act
    act=$(LIST_PICKER "Loot Management" "List all loot" "Save current loot" "Archive all" "Clear old" "Back" "List all loot") || return
    case "$act" in
    "List all loot")
        LOG "$(ls -lt /root/loot/ 2>/dev/null | head -50)"
        ;;
    "Save current loot")
        LOG "Archiving current loot to USB..."
        "$S/loot.sh" --save -y 2>&1 | head -30 | xargs LOG
        ALERT "Loot saved"
        ;;
    "Archive all")
        LOG "Archiving all loot..."
        "$S/loot.sh" --archive -y 2>&1 | head -30 | xargs LOG
        ALERT "All loot archived"
        ;;
    "Clear old")
        CONFIRMATION_DIALOG "Clear old loot (keep recent 5)?" || return
        "$S/loot.sh" --clear -y 2>/dev/null
        ALERT "Old loot cleared"
        ;;
    esac
}

export -f tool_airscout_menu tool_deauth_menu tool_wifikit_menu tool_wpskit_menu \
         tool_eviltwin_menu tool_ssidpool_menu tool_lanscan_menu tool_lanpwn_menu \
         tool_clientiso_menu tool_dnsspoof_menu tool_deadnet_menu tool_bluetooth_menu \
         tool_rogueap_menu tool_usbclone_menu tool_walledgarden_menu tool_stealthnet_menu \
         tool_topomap_menu tool_mgmt_menu tool_loot_menu

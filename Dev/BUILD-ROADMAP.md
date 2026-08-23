# Build roadmap — the 27 approved red-team tools

Tracking the approved loadout (`approved-ideas.txt`) to "ready". Order is mine
(user delegated it); grouped by dependency so shared cores get built first.
Status: [ ] todo · [~] in progress · [x] built & wired · [H] needs on-device /
hardware test by user · [!] blocked (missing tooling, needs a workaround).

Device tooling confirmed: hcxpcapngtool, tcpdump, nmap, hostapd, dnsmasq, iw,
ethtool, python3.11+scapy present. opkg-installable: aircrack-ng, hcxdumptool,
nmap-full (NSE). Missing/hard: hashcat, impacket, responder (→ scapy-native or
offload).

## Foundation
- [x] **C1–C5** Controller — on-screen 3×2 grid launcher (done, deployed)

## Cluster A — WiFi capture & crack (top-approved)
- [H] **W1** WPA handshake capture + crack  (wifikit.sh: hcxdumptool→hcxpcapngtool→aircrack-ng/offload; wired in Controller; needs A8000 on-device capture test)
- [H] **W2** PMKID clientless capture  (wifikit.sh captures PMKID+EAPOL together)
- [H] **W11** Handshake+PMKID combo harvester  (wifikit.sh single capture → one 22000 hashline)
- [H] **DR7** Capture-while-cracking  (wifikit.sh --background capture + --crack against growing file)

## Cluster B — WiFi offense (mostly exist or thin)
- [H] **W5** WPS Pixie-Dust  (wpskit.sh: wash scan validated live + reaver pixie; attack needs A8000/target — wired in Controller)
- [x] **W6** Targeted deauth  (deauth.sh — wired in Controller)
- [x] **W7** SSID beacon flood  (ssidpool.sh — wired)
- [ ] **W8** Client-isolation tester  (probe peer reachability on the AP subnet)
- [x] **W9** PMF / 802.11w posture test  (airscout.sh reports PMF required/optional/off per AP — validated live)
- [ ] **W12** Rogue 5GHz twin  (hostapd on 5GHz / external adapter)
- [x] **W13** Client OS fingerprint (air)  (airscout.sh: probe-request IE fingerprint + rand-MAC flag — validated live, wired in Controller)
- [x] **W3** Karma / known-beacon twin  (EvilTwin.sh — wired)

## Cluster C — Wired LAN offense (USB-A adapter)
- [H] **L10** Deep scan → exploit shortlist  (lanpwn.sh --scan + --nse; LanScan.sh also wired)
- [H] **L1** Auto-pwn on plug-in  (lanpwn.sh --auto: discover→nse→creds→smb→report; wired in Controller)
- [ ] **L2** Responder + NTLM relay  (scapy LLMNR/NBNS/mDNS poisoner; relay = hard, phase 2)
- [H] **L3** Default-cred auto-login + config exfil  (lanpwn.sh --default-creds: HTTP basic-auth/FTP-anon)
- [H] **L4** SMB share auto-loot  (lanpwn.sh --smb-loot; smbclient installed — verifying lib deps)
- [x] **L5** Selective MITM + inject  (dnsspoof.sh/deadnet.sh — wired via LAN theme)
- [ ] **L6** Pivot + reverse tunnel  (ssh -R / socat over mgmt radio — socat installed)
- [ ] **L7** AD recon + Kerberoast  (impacket missing → scapy/manual, phase 2)
- [H] **L8** Printer / IoT exploitation  (lanpwn.sh --nse with 609 NSE scripts installed)
- [ ] **L9** Egress-buster + covert exfil  (port-knock outbound map + DNS/ICMP tunnel)

## Cluster D — Dual-radio (internal + external A8000)
- [~] **Dual-radio herd** internal twin + internal deauth  (Controller — done)
- [ ] **DR-ext** External A8000 as injector  (per-iface deauth/capture; needs A8000 attached) [H]

## Cluster E — Implant / C2
- [ ] **I1** USB-C gadget drop (PoisonTap)  (USB Ethernet gadget + DHCP/route/DNS trap) [H]

## Cluster F — POST-HTML ideas (build after the 27)
- [ ] **U1** USB-C device clone / whitelist bypass  (enumerate what the PC presents over USB-C gadget, clone identity onto LAN) [H]
- [ ] **U2** DNS walled-garden redirect  (dnsmasq: answer all lookups with one allowed page; USB-C host bridged to LAN)
- [ ] **U3** Stealth intercept ("hanging" internet)  (silent forward+withhold; nft/tc + proxy)
- [ ] **U4** Network topology mapper  (TTL/hop, LLDP/CDP, ARP, traceroute → switch/repeater/router tree)

## Cluster G — Bettercap & Wifite (build LAST)
- [ ] **BC1** bettercap (Go) + bettercap.sh  (clone github.com/bettercap/bettercap, build/port MIPS)
- [ ] **WF1** wifite2 (Python) + wifite2.sh  (clone github.com/derv82/wifite2, port)

## Notes
- Cracking on-box: aircrack-ng dictionary against a small wordlist; big cracks
  export the 22000 hash to pull off-box (no hashcat on MIPS).
- NTLM-relay/Kerberoast need impacket (not in opkg) — capture natively now,
  relay/roast in a phase-2 pass (pip install into /mmc, or offload the hashes).
- [H] items I build blind and you verify on the device / with the A8000 or a
  target PC attached — I can't exercise those paths over SSH.

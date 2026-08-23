# Pager Toolkit

Bash toolkit for a Hak5 WiFi Pineapple Pager, deployed over SSH via
`setup.py`. `scripts/` are CLI tools you SSH in and run directly;
`payloads/` are the on-screen Payload-menu wrappers around them;
`scripts/guiserver/` is an optional local web control panel.

## Deploy

```
python setup.py                # incremental - only pushes what changed since the last push
python setup.py --force        # ignore the incremental cache, push everything
python sync.py                 # wait for SSH to come up, then run setup.py
python sync.py --watch         # keep watching scripts/ and payloads/ for local changes, auto-push
```

Both read `ip=`/`password=` from `config.txt` next to them (copy
`config.txt.example` and fill in your own device's values - `config.txt`
itself is gitignored, never committed).

## What's here

### PineAP / access-point control

- `EvilTwin.sh`: dynamic evil-twin / clone-AP launcher.
- `openap.sh`: manage the Open AP directly (enable/disable/hide/clear).
- `mgmt.sh`: manage the Management AP (enable/disable/hide/clear).
- `mimic.sh`: toggle PineAP mimic mode (karma - answer any probed SSID).
- `ssidpool.sh`: manage the SSID-impersonation pool (add/list/delete/start/stop).
- `filters.sh`: manage PineAP device (MAC) and network (SSID) filters.
- `bands.sh`: set which WiFi bands recon monitors.
- `examine.sh`: lock recon to one channel/BSSID for handshake collection, or resume hopping.
- `reconsession.sh`: start a fresh recon session; pause/resume channel hopping.
- `dns.sh`: override the system DNS handed out to clients.
- `dnsspoof.sh`: manipulate DNS given to Pineapple AP clients (add/remove spoofed hosts).

### Client disruption

- `deauth.sh`: deauthenticate WiFi clients via PineAP (outside attacker or LAN-side).
- `bluetooth.sh`: Bluetooth recon + disruption over the Pager's internal radio.
- `deadnet.sh`: disconnect wired-LAN devices via ARP-cache poisoning + IPv6 dead-router spoofing.

### Wired LAN & packet capture

- `sniff.sh`: LAN packet sniffer, with a bridge/tap mode for a two-NIC PC-through-Pager setup.
- `tracer.sh`: live, continuously-scrolling packet trace (watch traffic as it happens).
- `pc_link.sh`: detect a PC wired directly to the Pager and capture + summarize its traffic.
- `LanScan.sh`: nmap-based LAN scanner over the Ethernet/USB-C interface.
- `pcap.sh`: start/stop the Pineapple's own optimized WiFi packet capture.

### WiFi client & connectivity

- `connect.sh`: connect the Pager itself to a WiFi network (auto-detects encryption).
- `wifi.sh`: master WiFi kill-switch / restore, official commands only.
- `clientip.sh`: look up a connected client's IP address by MAC.
- `vpn.sh`: configure/enable/disable OpenVPN or WireGuard.
- `autossh.sh`: maintain a persistent outbound SSH tunnel (phone-home access).

### Recon output & loot

- `loot.sh`: list and archive collected loot (handshakes, pcaps, wardriving logs).
- `wigle.sh`: wardriving log control + Wigle.net upload.
- `report.sh`: generate one readable engagement report from everything captured this session.
- `gps.sh`: list/configure the USB GPS receiver, show live status.

### Device & platform

- `battery.sh`: show battery level and charge state.
- `led.sh`: control the Pager's LEDs.
- `ringtone.sh`: play a ringtone and/or vibrate.
- `screen.sh`: turn the physical display on/off.
- `config.sh`: device configuration helper.
- `reset.sh`: put the device back to a known-good state (bridges, radios, orphaned background jobs).
- `crash_logger.sh`: continuously mirror dmesg/logread to persistent storage, so a crash-reboot doesn't erase its own evidence.
- `alert.sh`: push a message to the Pager's screen from SSH.
- `webui.sh`: start/stop the Pager Control Panel (`scripts/guiserver/`).
- `PayloadRunner.sh`: launcher for the Pager's real payload system.

### Payloads (on-screen menu)

Each wraps one or more of the scripts above behind `payloads/general/<name>/payload.sh`.

- `lan_sniffer`: live LAN traffic view, auto-detected adapter or full bridge/tap; HTTP/DNS/credential hits flagged live.
- `wifi_deauth`: continuous deauth against a chosen network's clients, with mesh-AP grouping and dynamic escalation.
- `bluetooth_jam`: scan, L2CAP-flood, jam, BLE-advert flood, or occupy the 2.4GHz band.
- `deadnet_lan_kill`: discover live LAN hosts, then ARP-poison the wired LAN to disconnect them.
- `pc_link_recon`: detect the directly-wired PC and capture + summarize its traffic.
- `packet_tracer`: live packet trace over WiFi, wired LAN, or passive nearby-WiFi monitoring.
- `custom_lan_scan`: nmap scan of the wired LAN, pick a mode on-screen.
- `reset_device`: undo anything this toolkit left in a non-standard state, or restart/reboot.

### Shared code

- `scripts/lib/common.sh`: shared helpers sourced by every script above - `say`/`err`/`die`, config-store access, confirm/ask prompts, PID-reuse-safe process tracking, and the shared LAN-topology reconciler.
- `scripts/lib/deadnet/`: the vendored `deadnet` core tool (trimmed to just the ~30KB engine) that `deadnet.sh` drives.

### Control panel (optional)

Not the main focus of this project - most work happens over SSH and payloads.

- `scripts/guiserver/server.py`: thin HTTP backend that shells out to the same scripts above; binds only to `br-lan`, never the internet-facing uplink.
- `scripts/guiserver/static/`: the panel's frontend (`app.js`, `index.html`, `style.css`).

### Tests

- `scripts/tests/test_sniff_logic.sh`: offline regression checks for `sniff.sh`'s argument validation, block-boundary parsing, and protocol classification.
- `scripts/tests/test_payload_logic.sh`: offline regression checks for `lan_sniffer/payload.sh`'s pure-logic pieces (progress bar, duration parsing).

### Deploy tooling

- `setup.py`: one-shot installer - uploads `scripts/`, deploys payloads, sets up autostart and PATH.
- `sync.py`: waits for the Pager's SSH to come back up, then runs `setup.py`; `--watch` auto-pushes on local file changes.

### Archive

- `Dev/BOOT_PERFORMANCE.md`: a measured breakdown of where the Pager's ~2.5-3 minute boot time actually goes, and what's safe to touch.
- `Dev/POSTMORTEMS.md`: sixteen incidents that bit us once - full writeups, grouped by area, each collapsible.
- `old/`: pre-hardening versions of `deadnet.sh` and `deadnet_lan_kill/payload.sh`, kept for reference.

## Postmortems

Sixteen incidents that bit us once - moved to
[`Dev/POSTMORTEMS.md`](Dev/POSTMORTEMS.md) to keep this file focused on
"what is this and how do I use it." Worth a read before touching
`deauth.sh`, `sniff.sh`, or anything Bluetooth-related.

## Notes

- `payload.sh`'s own `# Version:` header comment must stay in sync with
  its `PAYLOAD_META` entry in `setup.py` (title/author/description/version
  shown on-device) - `setup.py` warns on drift between the two.
- `deadnet.sh` / `deadnet_lan_kill` were excluded from ongoing bug-hunt/
  improve passes for most of this project's history ("considered good
  enough as-is") until explicitly brought back in scope and hardened to
  match the rest of the toolkit's conventions (real `--background` +
  PIDFILE tracking, single-instance protection, input validation).

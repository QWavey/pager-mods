# Pager Toolkit

Bash toolkit for a Hak5 WiFi Pineapple Pager (root@172.16.52.1), deployed
over SSH via `setup.py`. `scripts/` are CLI tools you SSH in and run
directly; `payloads/` are the on-screen Payload menu wrappers around them;
`guiserver/` is an optional local web control panel.

## Deploying

```
python setup.py            # incremental - only pushes what changed since the last push
python setup.py --force      # ignore the incremental cache, push everything
python sync.py               # wait for SSH to come up, then run setup.py
python sync.py --watch         # keep watching scripts/ and payloads/ for local changes, auto-push
```

Both read `ip=`/`password=` from `config.txt` next to them.

## Postmortems - things that bit us once, don't repeat them

**Never touch system-wide library/linker config.** An earlier attempt to
make python3 (installed to the `/mmc` partition) resolvable from anywhere
by writing a system-wide ld-musl path file bricked the device - only fixed
by a full factory reset. The fix that actually works is
`resolve_python3()` in `scripts/lib/common.sh`: it sets
`LD_LIBRARY_PATH=/mmc/usr/lib` as a **per-invocation** env var prefix on
the specific command being run, never as a persistent system file. If
python3 needs finding again anywhere, use that helper - don't touch
`/etc/ld.so.conf`-equivalents or anything system-wide on this device.

**Trap-based background cleanup is unreliable on this device.** The
obvious pattern for a graceful `--stop` - set a `STOPPING` flag, trap
`INT`/`TERM` to set it, let the loop notice and clean up after breaking
out - was live-tested in isolation (`kill $PID` sent to a backgrounded
loop using exactly this pattern) and the process died without ever
reaching its post-loop cleanup line. Any script whose background loop
touches shared radio state (WiFi channel lock via
`PINEAPPLE_EXAMINE_CHANNEL`, Bluetooth Direct Test Mode, anything that
isn't self-resetting) MUST do its real cleanup **unconditionally in the
top-level `--stop` handler**, not only inside the loop's own trap. See
`deauth.sh`'s and `bluetooth.sh`'s `DO_STOP` blocks for the pattern - it's
a harmless no-op if the loop's own cleanup already ran, and a real save if
it didn't.

**`btmgmt` hangs forever if it isn't the shell's direct foreground
process.** Confirmed across 5+ backgrounding mechanisms (subshells,
`nohup`, disowned jobs, etc.) - it just never returns. Fixed by preferring
commands with their own duration flag (`btmgmt add-adv ... -D N`) over any
polling/wait loop around `btmgmt`, and wrapping every other `btmgmt` call
in `timeout N` as defense-in-depth, since even the GUI server itself runs
as a backgrounded process.

**recon.db's `ssid` column is BLOB, not TEXT.** SQLite's storage-class
comparison rules mean `s.ssid = 'literal'` never matches even byte-
identical content. Always `CAST(s.ssid AS TEXT) = '...'` when comparing
against it (and `sql_escape()` first - SSIDs are attacker-controlled data
being embedded in a SQL string literal).

**WiFi deauth can silently transmit on the wrong channel.** Recon hops
channels roughly once/second, and `PINEAPPLE_DEAUTH_CLIENT` is fire-and-
forget per Hak5's own docs - it doesn't itself guarantee the radio is
parked on the target's channel at the moment it transmits. If hopping
moved on first, the deauth frame goes out on the wrong channel and does
nothing, with no error. `deauth.sh` locks the channel via
`PINEAPPLE_EXAMINE_CHANNEL` before every transmission now (with a couple
seconds of overlap past the sleep interval to close the loop-boundary
race) - verified live at 0 off-channel samples across repeated runs.

**`deauth.sh --all` used to send almost nothing.** It sourced its target
list from recon's `hostap_client` table (which AP each specific client MAC
is associated to) - live-checked that table directly and found it
completely empty in practice, so every round found zero targets and sent
no deauth frames at all. Fixed: Hak5's docs say the target argument
accepts `FF:FF:FF:FF:FF:FF` for "all clients" - broadcast target already
disconnects every client of a BSSID with no per-client tracking needed.
`--all` now attacks every AP recon has beaconed from (the reliably-
populated `ssid` table, same source `--scan`/`--ssid` already use)
instead. Also added channel-grouping (`attack_ap_pairs` in `deauth.sh`) so
consecutive APs on the same channel share one lock instead of re-locking
per-AP - more of each round is spent actually transmitting, not
re-confirming a lock that already holds.

**Deauth "works sometimes" against a client with fast auto-reconnect is
not a bug to chase further** - it's the expected signature of hitting a
protocol ceiling. Per Hak5's own docs: PMF/802.11w and WPA3 networks are
immune to injected deauth by design, and some clients ignore disconnect
attempts regardless of network type. `deauth.sh --burst N` raises
disruption pressure within that ceiling; nothing raises it past the
ceiling itself.

**Don't flap `eth0`'s link state to force a tethered client's DHCP
renewal - it isn't a plain PHY.** `sniff.sh --bridge eth0 eth1 --dhcp`
lets the Pager keep SSH reachable while sniffing by pulling a real DHCP
lease on the bridge itself, but the tethered PC's own NIC never sees a
link-state change (the USB-C cable stays plugged in throughout), so its
OS may not proactively renew and can be left looking like "no internet"
even though the bridge and the Pager's own lease both work. A fix that
briefly set `eth0 down` then `up` right after the bridge came up (to
mimic a cable unplug/replug and trigger the client's own renewal) was
tried and live-tested - it made things *worse*, dropping the tethered PC
and requiring a full physical reset of the device, worse than any
previous failure in that same development pass. Root cause: `eth0` on
this hardware is documented (see `detect_usb_c` in `scripts/sniff.sh`) as
the SoC's own USB-Ethernet **gadget controller**, not a plain Ethernet
PHY - toggling it isn't guaranteed to be a quick carrier blip the way it
would be on a real NIC; it can tie into the USB gadget function's
bind/unbind state, which the host can see as a full device
detach/re-enumeration rather than "cable unplugged," and that takes far
longer to recover than a 1-second sleep budgeted for. Reverted; the
known limitation is now just documented in `sniff.sh`'s own output
(manual `ipconfig /release`+`/renew` on Windows, `dhclient -r`+`dhclient`
on Linux, on the client). If this is revisited, do it with a WiFi-based
second SSH session already open (`scripts/mgmt.sh` to enable the
Management AP) as a safety net **before** touching `eth0` again, not
live on the same connection being disrupted.

**OPEN INVESTIGATION (not yet root-caused - do not guess a fix without a
live re-test): the tethered PC's internet access can die during a plain
`--bridge` (no `--dhcp` involved).** Live-observed via
`sniff.sh --iface br-sniff`'s own packet log during a real Bridge/tap
run: a DNS query to the LAN's local resolver (a private/ULA IPv6
address) went out and got a correct answer back through the bridge, but
every subsequent TCP SYN from the same client to the public internet
(Google's IPv6 ranges) got zero replies - repeated retries, no SYN-ACK,
no RST, for the whole capture window. That's a real, reproducible
outage, not the DHCP-renewal issue the rest of this postmortem is about
(this client was on IPv6 SLAAC, not DHCP - there's no "stale lease" to
renew here). `br_netfilter` was checked and ruled out with direct
evidence (module not loaded, `/proc/sys/net/bridge/bridge-nf-call-*`
don't even exist on this kernel) - the standard "bridged traffic
accidentally hits the firewall's FORWARD chain" explanation doesn't
apply here. True root cause is still open: worth re-checking whether
`fw4`'s zone/interface-name matching (its `wan`/`lan` zones are keyed to
`eth1`/`wlan0cli`/`br-lan` by name, not aware of the ad-hoc `br-sniff`
sniff.sh creates outside UCI) somehow still applies to `br-sniff`
traffic despite `br_netfilter` being absent, or whether this was simply
an unrelated ISP/WAN hiccup at that exact moment - both are plausible
and neither is confirmed. Next step when the device is available again:
reproduce with a second, WiFi-based SSH session open (`scripts/mgmt.sh`)
so the state can be inspected (`nft list ruleset` counters, `ip -s link`
drop counts) WHILE the outage is happening, instead of only after the
fact.

**Tiny UX reports from the same session, not yet confirmed by a live
retest:** (1) the duration picker (Timer/Infinite) could show a leftover
"pick a time" `NUMBER_PICKER` prompt even after "Infinite" was chosen -
hardened the comparison in `pick_duration()` to match tolerantly instead
of an exact string equality, and added a 1s settle pause before that
picker in case it was actually an input-event timing race with the
ALERT right before it; (2) stopping a running capture sometimes surfaced
the platform's own generic "Stop payload execution / Exit payload log"
menu instead of this payload's own confirm-then-save-log flow - most
likely the platform's own kill-payload control being used instead of
this payload's B-button handling, which this script has no way to
override, but not confirmed without seeing it reproduced live.

## Structure

- `scripts/` - the real tools (deauth, bluetooth, sniff, tracer, recon
  helpers, etc.) plus `scripts/lib/common.sh` for shared helpers.
- `payloads/<category>/<name>/payload.sh` - Payload-menu wrappers, driven
  by `PAYLOAD_META` in `setup.py` (title/author/description/version shown
  on-device - keep the `# Version:` header comment in each `payload.sh` in
  sync with its `PAYLOAD_META` entry, `setup.py` warns on drift).
- `scripts/guiserver/` - optional local web control panel, gated by
  `ALLOWED_SCRIPTS` in `server.py`. Deliberately not the main focus of
  this project - most work happens over SSH/CLI and payloads.
- `deadnet.sh` / `deadnet_lan_kill` were excluded from ongoing improve/
  bug-hunt passes for most of this project's history ("considered good
  enough as-is") until explicitly brought back in-scope and hardened to
  match the rest of the toolkit's conventions (real `--background` +
  PIDFILE tracking, single-instance protection, input validation). Pre-
  improvement versions are kept at `backups/Deadnet_lan_old.sh` and
  `backups/deadnet_lan_kill_payload_old.sh` for reference.

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

**UPDATE (second live report, more detail): the internet outage during a
plain `--bridge` self-heals after roughly 1-2 minutes, and is worse for
already-open connections than new ones.** Confirmed on a second, longer
bridge session: sites the browser already had warm/cached connections to
kept loading (fast, since no fresh ARP/routing resolution was needed);
brand-new destinations failed or loaded very slowly during the outage
window; plain `http://` sites never loaded at all during that window in
either case. All of this is consistent with the ARP/neighbor-cache
staleness theory from the first report - existing flows ride on
already-resolved neighbor entries and mostly survive, new flows need a
fresh ARP/ND resolution that isn't settling immediately after the
topology change, and it clears up once the cache naturally times out and
re-resolves (matches the observed ~1-2 minute recovery). Still not fully
root-caused (the `fw4`/br_netfilter possibilities from the first report
remain open, unconfirmed), but "self-heals in 1-2 minutes" changes the
practical severity from "the bridge silently drops your connection" to
"there's a real, bounded settling window right after bridging" - worth
mentioning explicitly in the payload's own confirmation dialog rather
than just chasing a code fix for something that may be inherent to how
ARP/ND resolution works after a topology change.

**Live packet-feed content that LOOKS broken but isn't:** the "spammy"
raw feed occasionally shows lines like `ethertype Unknown (0x88e1)` or
`(0x8912)` followed by a hex dump of mostly `0000 0000 0000...` bytes.
This is normal, correct tcpdump behavior, not a bug - some devices on a
real LAN (this looked like HomePlug/powerline-networking control
traffic) send proprietary Ethernet frame types tcpdump has no specific
decoder for, and its documented fallback for those is exactly this: a
raw hex+ASCII dump of whatever's there, which for a short, mostly-empty
control frame is legitimately going to be a wall of zero bytes. It's
genuinely captured, genuinely uninteresting data, not a parsing failure.

**CRITICAL, CONFIRMED LIVE - the device actually crashed during an
extended, busy capture.** Root-caused and fixed: `run_creds_watcher()`
and `run_packet_feed()` both re-scan the ENTIRE growing capture file
from byte 0 every cycle (every 5s and 2s respectively), with no upper
bound - for a long capture against genuinely busy real traffic (the
report: several browser tabs, YouTube, multiple sites), the file grows
into the multiple-MB range, and every cycle re-decodes the whole thing
again (`tcpdump -A`'s ASCII conversion is typically several times larger
than the binary it's decoding). `run_creds_watcher` additionally wrote
that whole decoded dump out to a `/tmp` file every cycle - `/tmp` on a
device like this is conventionally tmpfs (RAM-backed), meaning a second
full, ever-growing copy competing for the same 251MB total RAM budget as
the live tcpdump capture itself, the concurrent `run_packet_feed`
re-decode, and everything else running. This also explains two other
live reports from the same sessions: "Stop monitoring and exit" having a
long delay before taking effect (a `kill` sent to a subshell blocked
inside a single unbounded `tcpdump -A -r`/`grep` call on an ever-larger
file isn't actionable until that call returns - bash defers signal
handling for a blocked foreground command), and "button A doesn't pause
it" (the on-screen log appears to drain already-queued messages
independently of the script's own process state - a deep backlog of
individually-queued `LOG` calls, one per new line during a busy feed,
keeps visibly scrolling for a while even after the scroller is killed).
Fixed with a `MAX_LIVE_WATCH_BYTES` (4MB) cap - past that size, both
live watchers cleanly stop themselves with one explanatory log line and
hand off entirely to `--summary`, which still scans the complete file
exactly once - plus `timeout`-wrapping every tcpdump/grep call in both
functions (and in `summarize_pcap` too) so a worst-case delay is now
bounded instead of "however long a full-file scan happens to take," and
batching the payload's own scroller into one `LOG` call per poll tick
instead of one per line, to shrink the platform's own queued-message
backlog. Not yet re-verified live (device was rebooting) - the reasoning
and each piece is verified in isolation, but the actual crash scenario
itself needs a real re-test with a similarly busy, extended capture.

**Tiny UX report, now actually fixed (was previously guessed at twice
and still wrong both times):** the duration picker (Timer/Infinite)
showing a leftover "pick a time"-ish dialog after Infinite was already
chosen, dismissed with a single A press. The dismiss-with-one-press
detail was the giveaway - that's `ALERT`'s behavior, not `NUMBER_PICKER`
misfiring. Root cause: the `ALERT "Bridge is up - pick a capture
duration next"` call (which fires before the duration picker in the
code) appears to get queued by the platform and not actually render
until after the very next `LIST_PICKER`'s own interaction finishes - an
ordering problem no settle-pause between the two calls can fix, since
the ALERT was already queued before the pause even started. Removed the
ALERT entirely (replaced with a plain `LOG`, which needs no dismissal so
it can never appear out of order) rather than guess at the timing a
third time.

**Still open, not confirmed by a live retest:** stopping a running
capture sometimes surfaced the platform's own generic "Stop payload
execution / Exit payload log" menu instead of this payload's own
confirm-then-save-log flow - most likely the platform's own kill-payload
control being used instead of this payload's B-button handling, which
this script has no way to override, but not confirmed without seeing it
reproduced live.

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
  improvement versions are kept at `old/Deadnet_lan_old.sh` and
  `old/deadnet_lan_kill_payload_old.sh` for reference.

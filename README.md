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

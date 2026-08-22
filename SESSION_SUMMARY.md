# Session Summary (2026-08-22)

## What happened, in order

1. **"Keep SSH alive while sniffing" feature** (bridge eth0+eth1, DHCP lease
   on the bridge) was iterated live. Real bugs found and fixed: a stale
   route on the enslaved interface, a self-defeating teardown order
   (releasing DHCP/tearing down the bridge *before* restoring eth0 to
   br-lan, in three places), and the underlying `pid_running()` regression.
2. An `eth0` down/up "link flap" was added to force the tethered client to
   renew its DHCP lease automatically. Tested live and made things worse
   (a full device lockout needing physical recovery) - traced to `eth0`
   being documented as the SoC's own USB-Ethernet **gadget controller**,
   not a plain PHY, so toggling it isn't a safe assumption. **Reverted**
   (commit `1fe4fe7`). Known limitation documented instead: manual client
   DHCP renew if needed.
3. **LAN Sniffer payload/display fixes** (commit `bcfe0f6`):
   - Removed the `--dhcp` prompt from the payload (kept in `sniff.sh` for
     manual use) - it had no visible payoff without the reverted flap.
   - The bridge setup used to be one big blocking call with zero visible
     progress. Now streams a live, reset.sh-style progress bar while it
     runs (`BRIDGE_PROGRESS_FILE` in `sniff.sh`, tailed by the payload).
   - `run_creds_watcher()` rewritten to tag live HTTP/creds hits with
     source IP and destination host (`[HTTP] 1.2.3.4 -> example.com ...`)
     instead of raw, context-free header lines. Verified against both
     synthetic data and busybox's real `awk` on the device.
   - **Honest finding**: all of today's real captures had zero plaintext
     HTTP/DNS - traffic was pure encrypted IPv6 TCP. The new tagging is
     confirmed correct; it can't show URLs that were never sent in the
     clear. Not a code bug.
4. **Two more live reports, fixed/documented locally** (commit `6db1d6b`,
   **not yet deployed** - device went offline before `setup.py` could run):
   - Duration picker's exact-string match hardened (leftover "pick a
     time" prompt reported even after choosing Infinite) + a 1s settle
     pause before it, in case of an input-timing race.
   - **Open, unconfirmed**: internet access died for the tethered PC
     during a plain `--bridge` (no `--dhcp`) - DNS to the local resolver
     worked through the bridge, but TCP SYNs to the public internet got
     zero replies. `br_netfilter` was checked and ruled out with direct
     evidence (module not loaded, sysctls don't exist on this kernel).
     True cause still open - see README.md's postmortem section for the
     exact next diagnostic steps (a second WiFi-based SSH session so the
     device stays reachable while reproducing it).
   - Also reported, not yet investigated: stopping a capture sometimes
     shows the platform's own generic "Stop payload execution / Exit
     payload log" menu instead of this payload's own save-log flow -
     likely the platform's own kill-payload control, unconfirmed.

## State right now

- Git: all work is **committed** on `master` through `6db1d6b`. Nothing
  uncommitted.
- Device: **not fully up to date** - it has commit `bcfe0f6`'s fixes
  deployed (confirmed live), but **not** `6db1d6b`'s two hardening fixes.
  Run `python setup.py` next time the device is reachable to push them.
- No background jobs, no pending live tests, nothing waiting on input.

## Next steps (for next session)

1. `python setup.py` to deploy the pending duration-picker hardening.
2. Re-test Bridge/tap live with a WiFi Management-AP session open as a
   safety net (`scripts/mgmt.sh`), specifically to reproduce and diagnose
   the internet-outage issue with `nft list ruleset` counters / `ip -s
   link` watched *during* the outage, not just after.
3. Investigate the "Stop payload execution / Exit payload log" report if
   it recurs - likely needs Hak5 platform SDK docs on button/control
   precedence, which weren't available this session.

---

# Archived: previous session (part 2 - late night)

*(Kept for the record - this documents earlier, unrelated work: the
custom-payload-visibility bug chain, deadnet.sh's discovery rewrite, and
setup.py becoming the single deploy entry point. Superseded by everything
above, not by anything below.)*

## The real bug: custom payloads invisible on the physical Payloads screen

Took several attempts to actually nail this - documenting the full chain so
it's never a mystery again:

1. First theory (wrong-ish): missing `_hak5_manifest.json`. Added it. Didn't
   fix it alone, but it IS real - the dashboard reads payload metadata from
   this file, not by parsing `payload.sh` headers live.
2. Second theory (also part of it): wrong directory/file permissions.
   Real payloads are `drwx------` (dir) and `-rw-r--r--` (payload.sh, i.e.
   **not executable** - the dashboard/PayloadRunner.sh always invoke it via
   `bash payload.sh` explicitly, never relying on the execute bit). Fixed.
3. Third, and the one that actually mattered: **the dashboard app process
   never actually restarted.** `/etc/init.d/pineapplepager restart` calls a
   `stop_service()` that has a bug in Hak5's own script - it stops `pineapd`
   (the WiFi daemon) instead of the `/pineapple/pineapple` process it
   actually starts. So every "restart" I did was a no-op on the process
   that matters; it kept running with its stale in-memory payload cache
   from boot. Fix: kill the actual PID directly (`ps w | grep pineapple`),
   procd cleanly respawns it. **`setup.py` now does this automatically**
   after deploying payloads.
4. Fourth and final piece: **"Do not create your own category"** - this is
   an actual rule from Hak5's own payload repo README. Every real payload
   lives at `user/<EXISTING category>/<name>/payload.sh` (e.g.
   `user/general/ping/`) - never as its own top-level category directly
   under `user/`. Our payloads were doing exactly that. Moved all three
   into `user/general/`.

All four together is what actually fixed it (confirmed live - you saw them
appear). `setup.py --skip-payloads` skips this whole step if you ever need
to for some reason.

## deadnet.sh - major rewrite (client discovery)

You asked for it to discover clients, not just blast the whole subnet
blind. It now:
- Runs an nmap ping-sweep of the actual subnet before attacking, shows you
  every live host (IP + MAC + vendor when resolvable) it found
- Saves the discovery to `/root/loot/deadnet/discovery-*.txt`
- `deadnet.sh --discover` to just scan without attacking
- `deadnet.sh --status` to check if a background run is active
- The underlying ARP-poison attack itself still covers the whole subnet
  (that's inherent to how ARP poisoning works - scapy can't be selective
  about *whose* ARP cache gets poisoned without a fundamentally different
  attack), but you now know exactly who's there before you commit, and
  it's logged for the record.
- The `deadnet_lan_kill` payload now runs discovery FIRST and LOGs the
  results to the physical screen (via `LOG`), not buried in a background
  log file you'd never see.
- The awk parser for nmap's output was tested against real captured
  sample output (including a no-MAC-resolved case) before I trusted it -
  verified correct, not guessed.

## sniff.sh - major rewrite (auto-summary + creds scan)

Every capture now auto-generates a readable report when it finishes:
- Top talker IPs (works for both IPv4 and IPv6)
- Protocol breakdown - **note:** I initially wrote this using literal
  "TCP"/"DNS" string matching and caught it as wrong via testing - tcpdump's
  default output almost never contains those literal words (it shows
  `Flags [S]` for TCP, and query markers like `A?` for DNS instead).
  Rewrote and verified against synthetic tcpdump output samples before
  trusting it.
- A cleartext-credential pattern scan (HTTP Basic Auth headers, form
  `password=`/`user=` params, FTP/Telnet `USER`/`PASS` lines) - flagged
  clearly as "pattern hits, not guaranteed valid creds," not overclaimed.
- `--background`/`--stop`/`--status` for detached captures
- `--summary FILE` to re-run the report on any old capture

## New: report.sh

Aggregates everything the toolkit has captured this session (handshakes,
LAN scans, deadnet discoveries, sniff captures, WIFI_PCAP, wardriving logs,
payload run logs) into one readable report. `--save` writes it to
`/root/loot/reports/`, `--save --archive` also archives all current loot
after. Doesn't do anything the toolkit wasn't already capable of - just
makes sense of everything it already collected in one place.

## setup.py - now the single source of truth for a full reinstall

Previously only deployed `scripts/`; payload deployment was a set of
one-off scripts I ran by hand. Folded all of that into `setup.py` itself:
- Deploys `payloads/<category>/<name>/` correctly nested, with the right
  permissions and a generated manifest, for every payload
- Force-restarts the pineapple app process afterward so they're visible
  immediately (the *correct* restart, not the buggy init.d one)
- scapy now installs by default (deadnet.sh needs it) - `--skip-scapy` to skip
- `--skip-payloads` to skip the payload deployment step

**Everything in this session is local-only right now** - your LAN/SSH was
down while I did this work, exactly as you said. Nothing has been tested
live since the payload-category fix you confirmed working. Local syntax
checks pass on all 35 files in the package (bash -n on every .sh/gui/help,
py_compile on setup.py).

## To deploy everything once you're reconnected

```
cd pager-setup
python setup.py
```

One command, idempotent, does everything above including the payload fix
and the correct process restart.

## Known limitation, stated plainly

I could not live-test `deadnet.sh --discover`'s nmap parsing or
`sniff.sh`'s summary/protocol classifier against the real device tonight -
both were verified against synthetic/sample data that matches real
output formats seen earlier this session, but not against a live run.
Test these first before relying on them for something that matters.

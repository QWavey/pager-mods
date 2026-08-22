# Continuous Bug Hunt - Progress Log

Running per user instruction: bug-hunt only (no refactors/improvements) across
every file, continuously, until the user's next message. Improvement-shaped
ideas get parked via /quick-map instead of implemented here.

Starting point: commit 03821bb ("lan_sniffer payload - clear ALERT before the
duration prompt"). Backup + full git history from earlier sessions still intact.

## Confirmed bugs found and fixed (this run)

1. common.sh: topology_log() prune step raced on a shared temp filename
   across processes - now PID-suffixed.
2. server.py: background Popen() objects were never reaped - zombie
   accumulation over a long Control Panel session. Tracked + poll()-reaped
   on every request (rejected the SIGCHLD=SIG_IGN approach first tried -
   it can break subprocess.run()'s own waitpid() bookkeeping).
3. setup.py: prune_stale_scripts() forgot a path from its own state cache
   even when the remote delete failed, so a genuinely-failed removal would
   never be retried on any future run.
4. sync.py: --watch --force applied --force to every watch-triggered push
   forever, not just the first one (docs say "first push"), defeating
   --watch's whole incremental point.
5. reset.sh: 3 ip-link calls in the br-sniff teardown still used a
   hardcoded `timeout 5` instead of the shared ip_link() wrapper - silently
   ignored PAGER_IP_LINK_TIMEOUT while every other call site respected it.
6. loot.sh, ssidpool.sh, autossh.sh, dnsspoof.sh: no -y/--yes flag defined
   at all despite a CLI-reachable confirm() gate (--archive/clear/--clear
   respectively) - could never be scripted/automated. reconsession.sh had
   the mirror-image bug: an earlier fix this session added a confirm()
   gate to --new that checks $ASSUME_YES, but no flag ever set it either -
   my own regression, now fixed the same way. All fixed with a pre-scan
   loop that also FILTERS -y/--yes out of "$@" (not just detects it), so it
   can't land as a literal positional arg to add/delete/--setup/etc.
7. EvilTwin.sh (x3), LanScan.sh (x1), tracer.sh (x2): raw, unbounded
   `ip link show` calls with no timeout protection at all (worse than
   reset.sh's old hardcoded-timeout bug - these had NO timeout), unlike
   sniff.sh/reset.sh/common.sh which all route through the shared
   ip_link() wrapper. Converted to ip_link() for consistency/safety.

## Reviewed, no new bugs found

- scripts/lib/common.sh (full re-read)
- scripts/guiserver/server.py (full re-read)
- setup.py, sync.py (full re-read)
- scripts/filters.sh (post-refactor re-check)
- scripts/deauth.sh: scan_ssid_groups/ssid_group_pairs/all_ap_pairs/sql_escape
- scripts/bluetooth.sh: run_disrupt() dwell/channel arithmetic
- scripts/mgmt.sh (full re-read)
- scripts/gps.sh, clientip.sh, screen.sh, dns.sh (dnsspoof.sh's -y gap
  found separately, see above)
- app.js ACTIONS table vs index.html: cross-checked every referenced
  element ID (inputs, outputs, buttons) - all present, no duplicates, no
  mismatches
- payloads/general/pc_link_recon, custom_lan_scan (fresh re-read)
- scripts/LanScan.sh (rest of file, beyond the ip_link fix above)

## Improvement-shaped ideas parked (not acted on here - see /quick-map output)

(filled in if any surface)

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

## Reviewed, no new bugs found

- scripts/lib/common.sh (full re-read)
- scripts/guiserver/server.py (full re-read)
- setup.py, sync.py (full re-read)
- scripts/filters.sh (post-refactor re-check)
- scripts/deauth.sh: scan_ssid_groups/ssid_group_pairs/all_ap_pairs/sql_escape
- app.js ACTIONS table vs index.html: cross-checked every referenced
  element ID (inputs, outputs, buttons) - all present, no duplicates, no
  mismatches
- payloads/general/pc_link_recon, custom_lan_scan (fresh re-read)

## Improvement-shaped ideas parked (not acted on here - see /quick-map output)

(filled in if any surface)

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

8. wigle.sh: CLI --login had no success/failure check at all (unlike its
   own interactive-menu counterpart); interactive choice 5 (upload) also
   discarded WIGLE_UPLOAD's real exit code silently.
9. app.js (Control Panel): reconNew/openOn/openOff/mgmtOn/mgmtOff never
   passed "-y" to scripts whose actions are gated behind confirm() (added
   earlier this session for reconsession.sh --new, and pre-existing for
   openap.sh --off / mgmt.sh --on+--off). server.py's subprocess.run()
   doesn't redirect the child's stdin, so confirm()'s `read` either hits
   immediate EOF (ASSUME_YES unset -> "Aborted.") or blocks until the
   action's own request timeout - these five Control Panel buttons could
   never actually complete. Fixed by adding "-y" plus a matching
   confirmAuthorized() JS-side gate for the two/four that are actually
   consequential (openOn doesn't need one).

10. bluetooth.sh: --disrupt --background was the one launch path in this
    file with no post-launch liveness check, unlike --flood/--jam-area
    right next to it which already fixed this exact class - could claim
    "Started in background" even if the subshell died immediately (no
    hci0/hcitool). Also meant the bluetooth_jam payload's own `if ! ...
    --disrupt --background; then ERROR_DIALOG` check could never actually
    trigger, since bluetooth.sh always returned 0 either way.

11. scripts/loot.sh: its own -y/--yes fix (from earlier in this same sweep)
    had been made in the working tree but never actually committed - caught
    via a repo-wide `git status` sanity sweep after everything else looked
    clean. Committed now; it had already been deployed to the device
    (setup.py deploys from the working tree regardless of git state) but
    the git history was missing it.

## Live verification (device reachable this session)

- Deployed via `python setup.py --skip-python3 --skip-scapy` - all changed
  files uploaded successfully, usb_monitor.sh confirmed still running.
- `bash -n` on every changed script passed on the ACTUAL device (mipsel
  bash), not just this Windows dev machine.
- Live-ran and confirmed working: `ssidpool.sh clear -y`, `reconsession.sh
  --new -y`, `autossh.sh --clear -y`, `dnsspoof.sh --clear -y`,
  `bands.sh --iface wlan1mon --2 --5 --6`, `openap.sh --off -y` - every one
  of these would have failed (die "Aborted.") before this session's fixes.
- `logread`/`dmesg` on the live device show zero errors/crashes/hangs -
  system is healthy after all these changes.
- Repo-wide `bash -n` sweep (every *.sh under scripts/ and payloads/) and
  `python -m py_compile` on all three .py files: 100% clean, nothing
  accidentally broken by this session's edits.

## Full-toolkit coverage checkpoint (this run)

Every file has now been read at least once this run (many multiple times,
several 2-3x across earlier phases of this session too):

- scripts/*.sh (all 39 CLI scripts, plus `gui`/`help`): reviewed, fixes
  above applied where found.
- payloads/general/*/payload.sh (all 7 non-deadnet payloads): reviewed,
  no new bugs beyond what earlier phases already fixed.
- scripts/guiserver/server.py + static/{app.js,index.html,style.css}:
  reviewed, ALLOWED_SCRIPTS/LOG_FILES cross-checked against real scripts
  and log paths (no drift found), index.html element IDs cross-checked
  against app.js references (no drift found).
- setup.py, sync.py: reviewed in full, no new bugs.
- scripts/lib/common.sh core primitives (say/err/die, cfg_get/set/del,
  need_arg, is_valid_mac, pid_running, print_help): reviewed, all correct.
- Targeted pattern sweeps (unquoted comparisons, unquoted SSID/password
  usage in platform commands, $RANDOM usage): clean, nothing found beyond
  what's already fixed/documented.
- .deploy_state.json sanity-checked against the real local file tree: no
  stale entries.
- deauth.sh (1783 lines, the largest/most complex file): re-read start,
  attack-loop functions (run_attack_loop/attack_ap_pairs/escalate_check/
  find_target_bssid/start_sentinel/run_reactive_strike/run_multi_bssid_loop/
  run_all_loop/launch_attack), and the final dispatch - no new bugs; this
  file has clearly already been through many live-diagnosed hardening
  rounds in earlier phases of this session.

deadnet.sh / deadnet_lan_kill payload remain explicitly out of scope per
standing user instruction.

## Improvement-shaped ideas parked (not acted on here - see /quick-map output)

(filled in if any surface)

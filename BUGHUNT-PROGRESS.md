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

## Live incident investigation (device report: stuck LAN bridge, reset errors, USB notification)

Investigated via live SSH: dmesg (uptime-correlated against the reported
screenshot's own on-screen clock), the actual /tmp/pager-reset.log,
usb_monitor.sh's log, and repeated live re-tests of the specific commands
that errored.

15. reset.sh: `btmgmt clr-adv` (used in reset_bluetooth()) is NOT safe to
    call unconditionally - confirmed live it returns a real nonzero exit
    ("Invalid Parameters") whenever zero advertising instances are
    currently registered, which is the NORMAL case on almost every reset
    run. This made reset.sh report a false "Bluetooth radio may still be
    in a bad state" on nearly every normal run. Fixed: check the real
    instance count (btmgmt advinfo) first, only call/check clr-adv when
    there's actually something to clear. Live-verified: a full `reset.sh
    --all` now reports "Done." for Bluetooth instead of a false error.
16. reset.sh: reordered --all/no-flags to run network recovery FIRST
    instead of last (was: processes/wifi/bluetooth/network). Motivated by
    the live incident where WiFi/Bluetooth reset commands ran while the
    network was still disrupted from a prior LAN-bridge attempt.
17. reset.sh: PINEAPPLE_EXAMINE_RESET still timed out once even AFTER the
    reorder (network confirmed fine beforehand, ruling out network
    contention specifically) - re-diagnosed via 4 immediate repeat calls
    (all ~0.2s) plus /proc/loadavg showing a real, decaying load spike.
    This is genuine occasional contention on modest embedded hardware, not
    a code bug - widened the timeout 10s->15s and added one retry after a
    short pause (matching the same "transient vs genuinely wedged"
    distinction already used elsewhere in this file). Live-verified: a
    subsequent full `reset.sh --all` completed 100% clean, all four steps
    reporting "Done."
18. lan_sniffer payload: the reported "stuck at Starting LAN Sniffer"
    screenshot was live-diagnosed (not guessed) via dmesg timestamps
    correlated against the screenshot's own on-screen clock (uptime math:
    7433.45s uptime at 15:09:47 wall-clock => the dmesg bridge-up event at
    ~7080-7081s falls almost exactly at the screenshot's visible "03:04
    PM"). The bridge itself DID come up successfully in under 10s (both
    ports reached kernel "forwarding state") - the apparent hang is the
    on-screen LOG/ALERT calls immediately after the bridge call stalling,
    consistent with this session's own separately-confirmed finding
    (EvilTwin.sh's PINEAPPLE_MIMIC_DISABLE, reset.sh's PINEAPPLE_EXAMINE_
    RESET above) that local platform IPC can transiently stall around a
    network-topology change. Can't be eliminated from the payload itself
    (it's the platform's own IPC being busy) - added a LOG call BEFORE the
    risky bridge call instead, so real progress shows before that stall
    window starts rather than the screen looking frozen from the very
    beginning.
19. usb_monitor.sh / USB on-screen notification: re-confirmed detection
    itself genuinely works (live log evidence: real attach/detach events
    with correct bus IDs and vendor identification - "ASIX (ASIX
    AX88179B)" - captured accurately). Re-confirmed via enumerating EVERY
    hak5cmd symlink on the device (ALERT, LOG, PROMPT, CONFIRMATION_DIALOG,
    ERROR_DIALOG, pickers, spinners - the complete list) that no
    toast/auto-dismissing notification primitive exists on this firmware
    at all - this is a genuine, already-previously-diagnosed platform API
    ceiling (ALERT pops up but never auto-dismisses per Hak5's own docs;
    LOG doesn't pop up, only appends to a dedicated log view), not a new
    code bug. Asked the user to clarify what "doesn't work" means
    specifically before changing anything further, since the LOG-over-
    ALERT choice was already made deliberately based on earlier explicit
    user feedback ("the messages still don't go away after a while") and
    reverting it without confirmation risks re-introducing that exact
    complaint.

## Second live incident (follow-up report: still no packet spam, no save-log prompt)

20. sniff.sh: `--summary` with an empty value (now distinguishable from
    "flag never given" via a new SUMMARY_FLAG_GIVEN tracking var) now
    fails loudly instead of silently falling through into an unrelated,
    non-interactive-hostile capture/interactive code path.
21. lan_sniffer payload: run_live_capture() now checks its own sniff.sh
    launch actually succeeded (exit code AND a real CAPTURE_FILE) before
    entering the wait loop or calling --summary - both call sites updated
    to skip the summary/save-log/ALERT steps entirely on a failed launch.
22. sniff.sh: added one retry (after a short pause) to the interface-
    existence check - live evidence this session shows real, recurring
    transient contention on this device, which could misreport a
    genuinely-existing interface (like a freshly-created br-sniff) as
    missing.
23. **CRITICAL, self-introduced regression, caught via live verification of
    my own earlier fix**: item 13's pid_running() hardening used
    "sniff.sh" as the NAME_PATTERN for sniff.sh's own is_running() - but
    sniff.sh's run_capture_bg() is a documented special case (like
    webui.sh) that `exec`s directly into tcpdump/timeout, so the real
    backgrounded process's /proc/PID/cmdline NEVER contains "sniff.sh".
    This made is_running() always return false for a capture that was
    genuinely running fine - confirmed live: a real --background capture
    wrote a full, valid, non-empty .pcap file while sniff.sh reported
    "Capture exited immediately" and `--status` said "Not running" the
    whole time. This broke EVERY background sniff.sh capture's liveness
    reporting (GUI, payloads, CLI alike) - almost certainly the dominant
    real cause of "not spamming with IPs" (the launch was being reported
    as failed, so the payload's own now-added check would abort before
    ever showing the live view). Fixed by using "tcpdump" as the pattern.
    Systematically re-checked all 9 pid_running() call sites for the same
    class of mistake afterward and found one more:
24. tracer.sh: identical bug, identical fix - run_trace() also execs
    directly into tcpdump for both foreground and background, so
    "tracer.sh" was never the right NAME_PATTERN there either.
    Both fixes live-verified end-to-end on the device: a real background
    capture now correctly reports "Started (PID ...)", `--status` shows
    "Capture running" while active and "Not running" once the duration
    elapses, and `--summary` against the resulting real .pcap file
    produced a correct report (274 packets, real source IPs/protocols).

## User-directed follow-up work (post full-coverage checkpoint)

The user asked for two specific things after the checkpoint below: (1)
implement the parked pid_running() PID-reuse hardening (Tasks.md item 12),
and (2) bring deadnet.sh/deadnet_lan_kill back into scope for improvement
(previously explicitly excluded), keeping a backup first.

12. EvilTwin.sh: WiFi-uplink connect hardcoded "psk2" - same fragility
    connect.sh's own header already documents fixing for the general case
    ("tries psk2, sae-mixed, sae, psk in order"). A WPA3 uplink network
    would just fail outright here. Now retries the same 4 encryption
    types in the same order.
13. pid_running() (lib/common.sh): now takes an optional NAME_PATTERN and
    verifies /proc/$PID/cmdline actually contains it before treating a PID
    as a live match - closes the PID-reuse false-positive gap parked
    earlier. Fails open (identical to the old bare kill -0) whenever no
    pattern is given or /proc/$PID/cmdline can't be read, so it can only
    ever narrow a false "running", never introduce a new false negative.
    All 9 call sites updated (bluetooth.sh/crash_logger.sh/deauth.sh x2/
    sniff.sh/tracer.sh/usb_monitor.sh pass their own script name;
    PayloadRunner.sh passes "payload.sh"; webui.sh passes "server.py"
    since its background launch execs into python3, replacing its cmdline).
    Live-verified on the device: usb_monitor.sh --status still correctly
    reports Running against its real PID/cmdline.
14. deadnet.sh (brought back into scope per user request, backup kept at
    backups/Deadnet_lan_old.sh + backups/deadnet_lan_kill_payload_old.sh):
    - Real --background support - the file's own header comment claimed
      this already existed ("If started in the background... use
      deadnet.sh --stop") but no --background flag existed anywhere in
      the argument parser at all. The deadnet_lan_kill payload worked
      around this with a bare `&`, no PIDFILE, no liveness check.
    - is_running() rewritten from a fragile `ps | grep 'deadnet\.py'` name
      scan (the exact self-identification fragility deauth.sh's own
      history already moved away from) to the shared PIDFILE + hardened
      pid_running() pattern every other backgroundable script uses.
    - No single-instance protection existed at all - could launch two
      concurrent ARP-poisoning processes fighting over the same interface.
    - lan_available() used a raw, unbounded `ip link show` instead of the
      shared ip_link() wrapper (same class fixed in EvilTwin.sh/LanScan.sh/
      tracer.sh earlier this session).
    - --gateway-mac had no MAC format validation; --sleep/--cidr had no
      numeric validation at all (same classes fixed throughout the rest of
      the toolkit this session).
    - deadnet_lan_kill payload updated to use the new --background flag
      properly (with a liveness check) instead of its own external `&`
      workaround.
    - Live-verified on the device: syntax, --status, and all three new
      validation checks (bad --gateway-mac, bad --sleep, out-of-range
      --cidr) all behave correctly. Did NOT live-test the actual
      ARP-poisoning attack itself (would disrupt the real LAN).

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

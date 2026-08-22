# Big Change Sweep

## Round 2 honesty note (the skill got stricter, and it was right to)

The first pass through this file recorded 42 files with a "kept change" - but on
re-reading the sharpened skill (its new "'Real' is not 'big'" section names, almost
verbatim, several of exactly what round 1 did: `ip_link()`/`pid_running()` extraction,
`run_device`+`run_network` merging, added `--status`/`--list` flags), the honest
verdict is: **round 1 was an `/improve` sweep, correctly executed, wearing this
skill's name.** Every one of those 42 changes was real and safely verified - none of
them should be reverted - but almost none of them were actually *big* (structural,
rearchitecture-scale). That's being said plainly here rather than re-labeled.

Round 2 first attempt (kept, but re-graded): built a shared LAN-topology
reconciler (`lib/common.sh`/`sniff.sh`/`reset.sh`) and a unified
`watch_for_reconnect()` in `deauth.sh`. Both real, both verified, both still in
the tree. **Both were mis-graded as "big" by arguing from importance instead of
structure** - "this is the exact code behind the two hardest live bugs" is a
value/incident-history argument, not a size argument. Rated honestly by
structure alone: `watch_for_reconnect()` is a merge of two byte-for-byte
identical blocks (a dedup, full stop); `canonicalize_lan_topology()` is a merge
of two similar-but-not-identical procedures into one parameterized function
plus a small added logging helper (still "merge two functions," the skill's own
disqualified example, with a feature bolted on). Both filed as improve-tier
below, not as this round's big change.

**Round 2's actual big change**, once the importance-laundering was caught and
the bar re-applied honestly by structure alone: `scripts/guiserver/static/app.js`
(see its own entry below) - ~25 independently hand-written onClick handlers
replaced with one declarative ACTIONS table + one generic executor. 337 of 401
lines touched. Verified with a 20-case functional test (real file, sandboxed
VM, mocked DOM/fetch) - all passing. This clears the bar on its own terms:
most of the file's actual structure changed, not two lookalike blocks merged.

Everything below this note is the **round 1 + round 2 record**, improve-tier
work correctly attributed as such except where marked otherwise.

---

Full file-by-file big-change pass over every file we authored in this toolkit.
Baseline backed up to `C:\Users\flori\Downloads\pineapple\BACKUP\pager-setup_2026-08-22_09-32-01`
and committed to a fresh local git repo (commit `a27267d`, "Baseline before big-change sweep").
Every kept change gets its own commit so any single file's change can be reverted with
`git revert`/`git checkout` without touching the others.

**Out of scope (standing user instruction, not re-litigated here):** `scripts/deadnet.sh`,
`payloads/general/deadnet_lan_kill/`, and `scripts/lib/deadnet/*` (vendored third-party tool it wraps) -
explicitly called "good enough already" earlier this session.

**Also excluded as non-code:** docs (`README.md`, `BOOT_PERFORMANCE.md`, `SESSION_SUMMARY.md`, `Tasks.md`),
`config.txt`/`config.txt.example`, `.deploy_state.json` (generated cache), `.claude/wut-config`,
and `__pycache__/*.pyc` build artifacts (being removed from tracking, not "code we wrote").

**Radio/bridge-critical files** (`deauth.sh`, `sniff.sh`, `reset.sh`, `lan_sniffer/payload.sh`,
`wifi_deauth/payload.sh`) get real scrutiny but a deliberately higher bar for "rewrite" vs "leave
alone" - this exact class of code has already caused two real incidents this session (an SSH
lockout requiring a reboot, and one requiring a full factory reset) from confident-looking changes
that turned out wrong under live radio/bridge conditions I can't fully re-test without the physical
device in hand. Bold restructuring is still on the table where it's genuinely safe to reason about
and verify (bash -n, tracing, and where possible a live non-destructive check against the device at
172.16.52.1) - but "this file is already right, don't touch working incident-tested logic just to
look busier" is a legitimate, honestly-recorded verdict here, per the skill's own rules.

Order: foundation (`lib/common.sh`) first, then alphabetical by path within scripts/, then
payloads/, then the two installer scripts.

1. [x] scripts/lib/common.sh
2. [x] scripts/lib/raw_deauth.py
3. [x] scripts/EvilTwin.sh
4. [x] scripts/LanScan.sh
5. [x] scripts/PayloadRunner.sh
6. [x] scripts/alert.sh (verdict: left as-is - already fully hardened; the
   obvious generic pattern, "wrap every platform call in a timeout," was
   considered and explicitly rejected here since PROMPT/CONFIRMATION_DIALOG/
   ALERT/ERROR_DIALOG are all confirmed to block until a human dismisses
   them on the physical screen - that's their whole job, not a hang to
   guard against; timing one out would abandon a dialog on the physical
   screen while the shell process moved on, a regression, not a fix)
7. [x] scripts/autossh.sh
8. [x] scripts/bands.sh (verdict: left as-is - thin single-command wrapper,
   already handles its one real edge case; no genuine big-change candidate)
9. [x] scripts/battery.sh
10. [x] scripts/bluetooth.sh (adopted shared pid_running(); otherwise left
    as-is - this file is unusually thorough already, live-diagnosed timing
    fixes throughout; a forced rewrite here risks reintroducing exactly the
    hard-won hang/cleanup bugs its own comments document)
11. [x] scripts/clientip.sh (verdict: left as-is - 46-line thin wrapper,
    already handles its one edge case, no genuine big-change candidate)
12. [x] scripts/config.sh
13. [x] scripts/connect.sh (verdict: left as-is - already solid; the one real
    idea, shortening the psk2/sae-mixed/sae/psk retry loop's per-attempt
    timeout, would need live measurement of how a wrong-encryption-type
    failure actually behaves on this hardware, which isn't available right
    now - recorded rather than guessed)
14. [x] scripts/crash_logger.sh (adopted shared pid_running())
15. [x] scripts/deauth.sh - extracted shared launch_attack() (see commit log);
    otherwise deliberately conservative given incident history
16. [x] scripts/dns.sh (verdict: left as-is - trivial, already hardened)
17. [x] scripts/dnsspoof.sh (verdict: left as-is - trivial, already hardened;
    a --status/--list would need unconfirmed knowledge of where DNSSPOOF_*
    persists entries, not guessed)
18. [x] scripts/examine.sh - unified CLI/interactive validation into shared
    validate_channel/validate_time/validate_bssid helpers
19. [x] scripts/filters.sh - merged run_device()/run_network() (95%
    identical) into one run_filter(), fixed a real interactive-mode bug
    found in the process (a typo'd device/network silently fell back to
    "network" before; now a clear error)
20. [x] scripts/gps.sh (verdict: left as-is - trivial, already hardened)
21. [x] scripts/gui (verdict: left as-is - trivial launcher, already correct)
22. [x] scripts/guiserver/server.py - added /api/tail (safe, allowlisted,
    read-only log-tail endpoint) so the Control Panel isn't a black box
    during a backgrounded run
23. [x] scripts/guiserver/static/app.js - round 1: wired up live-tailing for
    deauth/sniff/bluetooth backgrounded actions, added a real authorization
    confirm() before every attack action, resumes tailing on load, caps
    tail growth (improve-tier, see round-2 note at the top of this file).
    ROUND 2 REAL BIG CHANGE: rearchitected the whole file's control-flow
    model - ~25 independently hand-written onClick handlers (each
    re-implementing "validate, confirm, run, display, maybe tail" by hand)
    replaced with one declarative ACTIONS table + one generic runAction()
    executor every button goes through. 337 of 401 lines touched (~84% of
    the file). Verified with a 20-case functional test running the REAL
    file in a sandboxed VM with a mocked DOM/fetch - covers static args,
    dynamic args with conditional branches (the etStart wifi-uplink path),
    validation-abort messages, confirm()-decline actually blocking the
    request, dynamic per-call timeouts, and the background-checkbox's
    dual effect on both the run() flag and the displayed message. All 20
    passing, matching the original handlers' exact behavior for equivalent
    input.
24. [x] scripts/guiserver/static/index.html (verdict: left as-is - already
    has every element app.js's new features needed, no gap found)
25. [x] scripts/guiserver/static/style.css (verdict: left as-is - .out
    already has max-height/overflow-y:auto, no gap found)
26. [x] scripts/help - added a drift-detection safety net (warns about any
    *.sh under scripts/ not yet listed), same class of gap server.py's
    ALLOWED_SCRIPTS already had
27. [x] scripts/led.sh - added success/failure reporting (was the one
    wrapper in the toolkit with zero feedback of any kind)
28. [x] scripts/loot.sh - --list now shows size + most-recent-file per
    directory, not just a bare count (busybox-safe: du -sh + ls -t, no
    GNU-find-only flags)
29. [x] scripts/mgmt.sh - added confirm() gates to --on/--off/--hide (they
    fired with ZERO confirmation ever, even without -y - the one AP in the
    toolkit that can disconnect your own management session)
30. [x] scripts/mimic.sh (verdict: left as-is - already fully hardened, no
    confirmed way to add --status without guessing at unverified platform
    internals)
31. [x] scripts/openap.sh - added confirm() gates to --on/--off/--hide (same
    zero-confirmation gap as mgmt.sh, worded for Open AP's actual risk -
    disrupting connected clients mid-engagement, not a management lockout)
32. [x] scripts/pc_link.sh (verdict: left as-is - already very solid, real
    exit-code propagation, eth0/SSH-traffic warning, no genuine gap found)
33. [x] scripts/pcap.sh (verdict: left as-is - trivial, already hardened)
34. [x] scripts/reconsession.sh - added confirm() gate to --new (starts a
    fresh recon session with zero confirmation before; --pause/--resume
    left alone since they're trivially reversible)
35. [x] scripts/report.sh - added a live-verified "Other loot" section that
    flags any loot subdirectory not covered by a named section, the same
    class of drift this file's own history already shows happened twice
    for real (pc_link's directory, wigle/payload-runs/archive missing
    entirely from an earlier version)
36. [x] scripts/reset.sh - reset_wifi()/reset_bluetooth()/reset_processes()
    now report honestly instead of unconditional "Done." (this was the
    bug-hunt finding flagged earlier this session, now actually applied)
37. [x] scripts/ringtone.sh - added --list (ls /root/ringtones/), shown
    directly in interactive mode too
38. [x] scripts/screen.sh (verdict: left as-is - trivial, already fully
    hardened on both CLI and interactive paths)
39. [x] scripts/sniff.sh - adopted shared ip_link()/pid_running() from
    common.sh (removed a local duplicate ip_link() that was shadowing the
    canonical one); otherwise deliberately conservative, same incident-
    history reasoning as deauth.sh
40. [x] scripts/ssidpool.sh - fixed a real gap: add/delete/clear (the
    flag-less CLI actions) had NO success/failure reporting at all, despite
    this file's own header comment claiming that class was already fixed
    everywhere in it
41. [x] scripts/tracer.sh - adopted shared pid_running()
42. [x] scripts/usb_monitor.sh - adopted shared pid_running(); otherwise
    left alone (exceptionally well-hardened already)
43. [x] scripts/vpn.sh - added --status (best-effort: openvpn via ps,
    wireguard via `wg show`), directly following through on this file's own
    stated concern about silent VPN failures
44. [x] scripts/webui.sh - adopted shared pid_running()
45. [x] scripts/wifi.sh (verdict: left as-is - exceptionally well-hardened
    already, real failure-tracking kill switch with honest reporting; no
    genuine gap found)
46. [x] scripts/wigle.sh - fixed two real gaps: --upload had zero success/
    failure check (the one action whose whole point is a real network
    call to Wigle.net); interactive choice 4 (Stop log) was missing both
    the timeout and any feedback, unlike every other choice in the same
    menu
47. [x] payloads/general/bluetooth_jam/payload.sh - fixed a real gap in 4 of
    5 background-launched actions (flood/jam/disrupt/disrupt-focus): none
    checked whether the --background launch actually survived before
    claiming "running - press B to stop", unlike Adv-spam (already fixed)
    and unlike this exact class already fixed in wifi_deauth/payload.sh
48. [x] payloads/general/custom_lan_scan/payload.sh (verdict: left as-is -
    already v2.0, already checks LanScan.sh's real exit code)
49. [x] payloads/general/lan_sniffer/payload.sh (verdict: left as-is -
    already v3.1, exceptionally hardened from earlier this session; the
    one payload most directly tied to this session's core LAN-bridge
    incident, deliberately not touched further without a genuinely new,
    safe insight)
50. [x] payloads/general/packet_tracer/payload.sh - real gap fixed: this
    payload's own name/description promise a "live... watch traffic as it
    happens" trace, but it actually blocked completely blind until B was
    pressed - ported lan_sniffer's already-proven live-scroll (bounded
    poll, A-pause/B-stop) mechanism instead of reinventing it
51. [x] payloads/general/pc_link_recon/payload.sh (verdict: left as-is -
    already v2.0, already checks pc_link.sh's real exit code)
52. [x] payloads/general/reset_device/payload.sh - now greps the captured
    log for ERROR: lines (which reset.sh's own fix earlier in this sweep
    actually produces now) instead of always showing "Reset complete" -
    reset.sh's own sub-steps log an error and continue rather than
    aborting, so the wait() exit code alone would never have caught this
53. [x] payloads/general/wifi_deauth/payload.sh - fixed the minor
    completeness gap flagged earlier this session: connected-but-no-
    recon.db no longer skips prefilling the BSSID via connected_bssid()
54. [x] setup.py - added prune_stale_scripts(): a script deleted locally
    (e.g. raw_deauth.py, removed as confirmed-dead code earlier this
    sweep) used to stay on the device forever, since upload_tree() only
    ever adds/updates, never deletes. Unit-tested locally against a fake
    sftp/state before touching anything real - only removes paths under
    scripts/ that state itself remembers pushing, never payload entries
55. [x] sync.py - --watch's snapshot() now skips __pycache__/*.pyc/.pyo,
    matching setup.py's own exclusion (the same "define changed vs what's
    actually pushed" drift setup.py already had to fix once for the same
    files)

---

Descriptions/verdicts filled in as each file is reached (see commit log for the authoritative
per-file diff - this file is the tracker, not the changelog).

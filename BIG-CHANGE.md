# Big Change Sweep

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
23. [x] scripts/guiserver/static/app.js - wired up live-tailing for deauth/
    sniff/bluetooth backgrounded actions, added a real authorization
    confirm() before every attack action (a gap the CLI/payload paths never
    had), resumes tailing on page load if already running, caps tail growth
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
36. [ ] scripts/reset.sh
37. [ ] scripts/ringtone.sh
38. [ ] scripts/screen.sh
39. [ ] scripts/sniff.sh
40. [ ] scripts/ssidpool.sh
41. [ ] scripts/tracer.sh
42. [ ] scripts/usb_monitor.sh
43. [ ] scripts/vpn.sh
44. [ ] scripts/webui.sh
45. [ ] scripts/wifi.sh
46. [ ] scripts/wigle.sh
47. [ ] payloads/general/bluetooth_jam/payload.sh
48. [ ] payloads/general/custom_lan_scan/payload.sh
49. [ ] payloads/general/lan_sniffer/payload.sh
50. [ ] payloads/general/packet_tracer/payload.sh
51. [ ] payloads/general/pc_link_recon/payload.sh
52. [ ] payloads/general/reset_device/payload.sh
53. [ ] payloads/general/wifi_deauth/payload.sh
54. [ ] setup.py
55. [ ] sync.py

---

Descriptions/verdicts filled in as each file is reached (see commit log for the authoritative
per-file diff - this file is the tracker, not the changelog).

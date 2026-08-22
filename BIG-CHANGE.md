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
15. [ ] scripts/deauth.sh
16. [ ] scripts/dns.sh
17. [ ] scripts/dnsspoof.sh
18. [ ] scripts/examine.sh
19. [ ] scripts/filters.sh
20. [ ] scripts/gps.sh
21. [ ] scripts/gui
22. [ ] scripts/guiserver/server.py
23. [ ] scripts/guiserver/static/app.js
24. [ ] scripts/guiserver/static/index.html
25. [ ] scripts/guiserver/static/style.css
26. [ ] scripts/help
27. [ ] scripts/led.sh
28. [ ] scripts/loot.sh
29. [ ] scripts/mgmt.sh
30. [ ] scripts/mimic.sh
31. [ ] scripts/openap.sh
32. [ ] scripts/pc_link.sh
33. [ ] scripts/pcap.sh
34. [ ] scripts/reconsession.sh
35. [ ] scripts/report.sh
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

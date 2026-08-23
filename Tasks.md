# Tasks

1. [x] Move old usb_monitor.sh aside (old/usb_monitor_old.sh)
2. [x] Rewrite scripts/usb_monitor.sh cleanly from scratch
3. [x] Keep proven detection + lifecycle logic, drop dismiss/debounce/python
4. [x] Syntax-check and deploy
5. [x] Verify the rewritten daemon runs healthy on the device
6. [x] Document the platform limitation in Dev/POSTMORTEMS.md
7. [ ] Live-test the rewrite with the user
8. [ ] Commit and offer to push

---

For 1. `git mv scripts/usb_monitor.sh old/usb_monitor_old.sh`. Done.

For 2. Fresh 372-line file (was 1072) - concise honest header, clean sections. Done.

For 3. Kept: mkdir lifecycle lock (PID-reuse-safe), --stop wait-for-exit, all detection helpers (get_internal_radio_usb_path, usb_vendor_name, describe_usb_device, process_usb_dmesg_lines, carrier + dmesg-watermark detection), USB_A_STATEFILE publishing. Dropped: alert-serialization lock, dismiss_alert.py coupling, debounce state machine, diagnostic logging. notify() is now say + LOG + ALERT, backgrounded/timeout-bounded, instant on every event. Done.

For 4. bash -n clean; deployed via setup.py, restarted cleanly. Done.

For 5. --status reports Running (PID 18871), process confirmed alive. Done.

For 6. Added a "USB monitor - on-screen notification" postmortem section documenting the full investigation and the confirmed platform limitation (ALERT render lag on real USB-C detach, proven with a bare 10-line watcher). Done.

For 7. User to do a real unplug/replug and confirm behaviour. Done when: user confirms.

For 8. Commit the rewrite + old-file move + postmortem, run repo bash -n sweep, ask about pushing. Done when: committed and user asked about push.

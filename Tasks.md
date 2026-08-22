# Tasks

1. [x] Fix the --reactive/sentinel frame-label bug in deauth.sh
2. [x] Validate and deploy the deauth.sh fix
3. [x] Investigate the USB toast-message auto-dismiss issue
4. [x] Investigate the USB insert/removal detector missed-event issue
5. [x] Fix and deploy usb_monitor.sh issues found
6. [x] Redirect the stopped bug-hunt agent to scripts/sniff.sh with a hard no-WiFi-connections rule
7. [x] Confirm the improve-50 agent (aab6d7ece7be358a4) is left alone, not messaged
8. [x] Launch /improve 30 + /bug-hunt 10 for sniff.sh only if the redirect doesn't already cover it

---

For 1. Update the grep pattern in run_reactive_strike() and start_sentinel() in scripts/deauth.sh from the long-form "Association Request"/"Reassociation Request" to the confirmed-correct short-form "Assoc Request"/"ReAssoc Request" (verified via tcpdump binary strings, no live connection needed). Document "Authentication" as an unconfirmed label rather than guessing - no bare "Authentication" string exists in the binary, unlike confirmed "DeAuthentication"/"Disassociation". Done when: both functions' grep patterns use the confirmed strings, with an honest comment about the unresolved Authentication label.

For 2. Run `bash -n scripts/deauth.sh` to confirm syntax, then `python setup.py` to deploy. Done when: syntax passes and setup.py reports the file uploaded successfully.

For 3. Read scripts/usb_monitor.sh to find how it triggers the on-screen toast/notification for connect/disconnect events, and determine why the message doesn't auto-dismiss after ~2 seconds. Check whether this is controllable from the script at all (vs. a platform-level ALERT/LOG behavior) before assuming a fix is possible. Done when: root cause is identified with confidence (confirmed via reading code, live process check, or explicit statement that it's a platform-level limitation not fixable from this script).

For 4. Read scripts/usb_monitor.sh's detection loop (udev, inotify, or polling) for a race condition or missed-event class of bug - e.g. a polling interval that could miss a fast plug/unplug, or a detection check that only fires on state transition without a periodic re-sync. Done when: root cause is identified with confidence, same bar as task 3.

For 5. Apply fixes found in tasks 3-4 to scripts/usb_monitor.sh, validate with bash -n, deploy via setup.py, and verify the running process is healthy afterward (ps check, no crash). Done when: fixes are deployed and the live process is confirmed running without errors.

For 6. Send a message to agent a9e687878de3790f0 redirecting its scope from scripts/deauth.sh to scripts/sniff.sh, explicitly restating as a hard, no-exceptions rule: never attempt a real WiFi association/connection during any testing, for any reason - passive listening only. Ask it to apply the same bug-hunt discipline it showed to sniff.sh, building on/improving the LAN sniffer/bridge functionality further (beyond the watchdog + unbridge fixes already made this session). Done when: message is sent and the agent resumes with the corrected scope.

For 7. No action - explicitly do not send any message to aab6d7ece7be358a4 as part of this task list. Done when: confirmed by the absence of any SendMessage call to it during this task run.

For 8. Only launch new /improve 30 + /bug-hunt 10 agents for sniff.sh if the redirected agent from task 6 is scoped narrowly enough (e.g. bug-hunt only) that it doesn't already cover an improve-style pass too - otherwise treat task 6's redirect as satisfying this ask, to avoid duplicate/conflicting agents on the same file. Done when: either new agents are launched with a clear non-overlapping scope, or a clear reasoned decision is recorded that the redirect already covers it.

---

# Parked improvement ideas (found during a pure bug-hunt pass, NOT implemented - recorded per user instruction to use quick-map instead of fixing improvement-shaped findings mid-hunt)

9. [ ] Add numeric validation to connect.sh's --timeout
10. [ ] Add numeric validation to clientip.sh's --timeout
11. [ ] Add numeric validation to PayloadRunner.sh's --timeout
12. [x] Harden pid_running() against PID-reuse false positives

---

For 9. connect.sh's --timeout is handed straight to WIFI_WAIT with no numeric check, unlike --duration/--channel elsewhere in the toolkit. Not a confirmed silent-failure bug (a garbage value already surfaces via the existing "Did not associate within Xs" die() path), just imprecise root-causing - add `case "$TIMEOUT" in *[!0-9]*) die "'--timeout' needs a whole number of seconds (got '$TIMEOUT')." ;; esac` right after arg parsing, matching the pattern already used elsewhere (e.g. sniff.sh's --duration/--count, deauth.sh's --channel). Done when: a non-numeric --timeout gives that specific message instead of the generic "did not associate" one.

For 10. Same idea for clientip.sh's --timeout (used in FIND_CLIENT_IP "$MAC" "$TIMEOUT") - already has a working fallback ("No IP found for $MAC...") but not a precise one. Same fix pattern as task 9. Done when: same criterion.

For 11. Same idea for PayloadRunner.sh's --timeout (used in `timeout "$TIMEOUT" "${cmd[@]}"`) - the existing liveness-check error message already mentions "a bad --timeout value" as a possible cause, so this is the lowest-priority of the three, but an explicit check would make that the CONFIRMED reason instead of a guess. Same fix pattern. Done when: same criterion.

For 12. DONE. lib/common.sh's pid_running() now takes an optional NAME_PATTERN and checks /proc/$PID/cmdline (translating NUL separators to spaces first) actually contains it before treating the PID as a live match - fails open (old bare kill -0 behavior) whenever no pattern is given or /proc/$PID/cmdline can't be read, so this can only ever narrow a false-positive "running", never introduce a new false-negative on an ordinary correctly-tracked process. All 9 call sites updated: bluetooth.sh/crash_logger.sh/deauth.sh (both is_running and sentinel_running)/sniff.sh/tracer.sh/usb_monitor.sh pass their own script name (their backgrounded process is a bash subshell of the same script, so its real cmdline still shows that name); PayloadRunner.sh passes "payload.sh" (the one generic marker every backgrounded payload's real cmdline contains); webui.sh passes "server.py" specifically, since its background launch `exec`s into python3, replacing the process image so its real cmdline shows the python interpreter's own argv, not "webui.sh".

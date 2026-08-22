#!/bin/bash
# Title: LAN Sniffer
# Author: florian
# Description: Live LAN traffic view (auto-detected USB-A adapter, or bridge/tap both wired ports - full internet access stays intact) - timer or infinite duration, A pauses/resumes, B asks to stop, then offers to save the full log. HTTP/DNS/creds flagged live.
# Version: 3.3
#
# This is a general-payload wrapper around sniff.sh's own capture pipeline
# (nothing new re-implemented here). There was no dedicated Payloads-menu
# entry for plain LAN sniffing before this - pc_link_recon covers the
# "detect a directly-tethered PC and capture its traffic" case specifically,
# and packet_tracer covers passive nearby-WiFi monitoring, but neither is
# "just capture+watch+summarize whatever's on the wired LAN", which is
# sniff.sh's actual design center. This fills that gap.
#
# BUG FOUND AND FIXED (reported live against this exact device): v1.0
# captured everything via `__out=$(sniff.sh ... 2>&1)` - a single blocking
# command substitution that shows NOTHING until the ENTIRE capture (and
# its post-capture summary) finishes - looked exactly like a hang. v2.0
# fixed that with a background capture + live-tailed log. v3.0 fixed three
# more real reports (bridge/tap wording, an orphaned bridge on a cancelled
# dialog, and a fixed-timer-only duration picker). v3.3 (this version)
# fixes three more, all reported live against this exact device:
#
#   1. The bridge setup itself was still one big blocking command
#      substitution - nothing printed inside it reached the screen until
#      the WHOLE call returned, leaving one static line on screen the
#      entire time ("it just stayed here"). Now runs in the background
#      while this payload tails sniff.sh's own live bridge-progress file
#      and renders a reset.sh-style [#####-----] progress bar as each real
#      setup step lands.
#   2. The --dhcp option (get SSH back on the tapped LAN without a reset
#      afterward) is removed from this flow - its own client-side
#      auto-renew mechanism was found unsafe and reverted (see
#      README.md's postmortem), and without it the option had no visible
#      payoff from here. sniff.sh --bridge --dhcp is still there directly
#      if this gets revisited later.
#   3. sniff.sh's own live watcher (run_creds_watcher) used to tag raw
#      HTTP/creds lines with no source or destination context - not the
#      "IP -> URL, like bettercap/Wireshark" view actually asked for.
#      Fixed there to pair every hit with the packet's own source IP and
#      (when present) the HTTP Host header it was headed to.
#
# Button behavior: A pauses/resumes the live view (pausing stops new
# lines from arriving so you can scroll back through what's already on
# screen without it moving; A again resumes). B asks "Stop monitoring and
# exit?" - answer no and it keeps running untouched; answer yes and it
# stops, shows the summary, then asks whether to save the full log.
#
# "Wireshark-like" live content: sniff.sh's own live watcher (see its
# run_creds_watcher) surfaces HTTP requests (tagged [HTTP], as
# "SRC_IP -> HOST  METHOD PATH") and credential hits (tagged
# [CREDS FOUND], matched text highlighted red over SSH) AS THEY'RE SEEN,
# into the same live-scrolling log this payload tails - not just raw
# per-packet header lines, and not only in the end-of-capture summary.
#
# HONEST LIMITATION: `WAIT_FOR_INPUT`/`WAIT_FOR_BUTTON_PRESS` are the only
# documented ways to react to a button press, and both BLOCK until
# something is pressed - there's no documented way to wait for a button
# AND keep periodically checking "did a TIMER capture finish on its own"
# at the same time. So with Timer mode, if the duration elapses without
# you pressing A or B, the live view keeps scrolling correctly, but this
# payload won't notice and tell you it's done until the NEXT button press
# - press anything once you're ready to wrap up. Infinite mode has no
# such gap (nothing to finish on its own - it just waits for B).
#
# On exit: the device's own on-screen log has real scrollback limits - a
# busy capture can produce far more lines than are comfortable (or even
# possible) to scroll back through on the physical screen. So you're
# asked whether to save the full log (the live scroll AND the summary) to
# a text file under /root/loot/sniff/ - review it properly later
# (scp/download it, or the Loot menu) instead of straining to scroll.

if [ ! -x /root/scripts/sniff.sh ]; then
    ERROR_DIALOG "sniff.sh not found - run the toolkit setup.py first."
    exit 1
fi

usb_a_iface() {
    local ifn devpath
    for ifn in /sys/class/net/*; do
        ifn="$(basename "$ifn")"
        case "$ifn" in eth0|lo|br-lan|wlan*) continue ;; esac
        devpath="$(readlink -f "/sys/class/net/$ifn/device" 2>/dev/null)"
        case "$devpath" in *usb*) echo "$ifn"; return ;; esac
    done
}

iface_up() { [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]; }

# bridge_progress_bar CUR TOTAL - same visual style as reset.sh's own
# progress_bar() (a 20-char [#####-----] bar + percent), reused here
# (asked for directly - "do a 5 bar the same we have in reset") so the
# bridge setup below gives the same familiar feedback instead of a
# different, unfamiliar indicator. CUR isn't bound to TOTAL (some setup
# steps are conditional, e.g. "bridge already exists"), so this caps at
# 100% rather than showing something like "140%" if more steps land than
# the nominal count.
bridge_progress_bar() {
    local cur="$1" total="$2" pct filled bar i
    pct=$(( cur * 100 / total ))
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( pct / 5 ))
    bar=""
    i=0
    while [ "$i" -lt 20 ]; do
        if [ "$i" -lt "$filled" ]; then bar="${bar}#"; else bar="${bar}-"; fi
        i=$((i + 1))
    done
    echo "[$bar] ${pct}%"
}

# pick_duration - Timer (a number of seconds, as before) or Infinite (runs
# until you press B). Echoes the value to pass as sniff.sh's --duration -
# empty string for Infinite, since sniff.sh already treats "no --duration"
# as "capture until stopped" natively - no new capability needed there.
pick_duration() {
    local __choice
    # REGRESSION FOUND AND FIXED (found via code review): a prior
    # "duplicate entry" cleanup mistook LIST_PICKER's REQUIRED trailing
    # default-selection argument for an accidental repeated menu item and
    # deleted it. Confirmed against Hak5's own docs:
    # `LIST_PICKER [title] [option] [default]` - the last argument is a
    # required "which option is preselected" parameter, separate from the
    # option list ("A default option must always be provided!"). Restored
    # here (defaulting to "Timer", the original pre-regression default).
    __choice=$(LIST_PICKER "Duration" "Timer" "Infinite (until B)" "Timer") || return 1
    if [ "$__choice" = "Infinite (until B)" ]; then
        echo ""
    else
        NUMBER_PICKER "Capture duration (seconds)" 30 || return 1
    fi
}

# maybe_save_log SUMMARY_TEXT - asks whether to save the full session
# (live scroll log + summary) to a persistent text file, since the
# device's own on-screen log has real scrollback limits for a busy
# capture. Named after the .pcap so the two stay associated.
maybe_save_log() {
    local summary="$1"
    if CONFIRMATION_DIALOG "Save the full log to a file for review later?"; then
        local dest
        if [ -n "$CAPTURE_FILE" ]; then
            dest="${CAPTURE_FILE%.pcap}.log.txt"
        else
            dest="/root/loot/sniff/lan_sniffer-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo log).log.txt"
        fi
        mkdir -p "$(dirname "$dest")" 2>/dev/null
        {
            echo "== LAN Sniffer log =="
            cat /tmp/pager-sniff.log 2>/dev/null
            echo
            echo "$summary"
        } > "$dest" 2>/dev/null
        LOG "Saved to $dest"
    else
        LOG "Not saved."
    fi
}

# BUG FOUND AND FIXED (reported live - the save-log prompt was replaced
# by what looked like a platform "stop/quit payload?" dialog instead):
# `tail -n 0 -f FILE | while read; do LOG; done` backgrounded as one job
# is actually TWO processes (tail, and the while-read loop) joined by a
# pipe - `kill "$SCROLLER_PID"` (the wrapping subshell) only stops the
# subshell coordinating them, not `tail -f` itself, which - since it
# blocks forever waiting for more input by design - can survive as an
# orphan indefinitely, the same root cause as this session's other
# orphaned-background-process bugs. A payload trying to exit while a
# child like that is still alive is very likely exactly what triggered
# the platform's own "still running, stop and quit?" dialog before this
# script's own maybe_save_log prompt ever got a chance to run.
#
# Fixed by not using `-f` (follow-forever) at all: poll the log's line
# count every second and dump only the genuinely NEW lines each time via
# a bounded `tail -n +N` (reads what's there and exits immediately - it
# can never block waiting for more input the way `-f` does, so even a
# worst-case kill mid-read leaves nothing that lingers).
SCROLLER_PID=""
start_scroll() {
    (
        local __last=0 __total
        while :; do
            __total=$(wc -l < /tmp/pager-sniff.log 2>/dev/null || echo 0)
            if [ "$__total" -gt "$__last" ] 2>/dev/null; then
                tail -n "+$((__last + 1))" /tmp/pager-sniff.log 2>/dev/null | while IFS= read -r __line; do LOG "$__line"; done
                __last="$__total"
            fi
            sleep 1
        done
    ) &
    SCROLLER_PID=$!
}
stop_scroll() {
    [ -n "$SCROLLER_PID" ] && kill "$SCROLLER_PID" 2>/dev/null
    SCROLLER_PID=""
}

# run_live_capture IFACE FILTER DURATION - shared by both Quick Capture and
# Bridge/tap below, so the live-scroll/pause/stop behavior is identical
# either way instead of duplicated (and possibly drifting) in two places.
# DURATION="" means infinite (see pick_duration above).
run_live_capture() {
    local iface="$1" filter="$2" dur="$3"
    local args=(--iface "$iface" --background -y)
    [ -n "$dur" ] && args+=(--duration "$dur")
    [ -n "$filter" ] && args+=(--filter "$filter")
    # Capture the exact output path from the launch call's own "Output:"
    # line (returns almost instantly since --background) instead of
    # guessing it back afterward via `ls -t` - exact, not "probably the
    # newest file".
    local __launch_out __launch_rc
    __launch_out=$(/root/scripts/sniff.sh "${args[@]}" 2>&1)
    __launch_rc=$?
    CAPTURE_FILE=$(echo "$__launch_out" | grep -oE '/root/loot/sniff/[^ ]+\.pcap' | head -1)

    # BUG FOUND AND FIXED (live-diagnosed via a real device report - "not
    # spamming with IPs and stuff" and, on the same run, "not asking to
    # save the log"): this launch's own exit code was never checked at
    # all - unlike every other --background launch in this toolkit
    # (deauth/bluetooth/sniff's own --bridge above, tracer, PayloadRunner),
    # which all verify the launch actually survived before proceeding.
    # If it fails (bad interface, tcpdump missing, a bad --filter),
    # CAPTURE_FILE ends up empty (nothing for the grep to match) and this
    # used to just barrel ahead into start_scroll()/WAIT_FOR_INPUT anyway -
    # tailing a log file that was never going to get new lines, looking
    # exactly like "not spamming" instead of the clear failure it actually
    # was. Worse, the empty CAPTURE_FILE later got handed straight to
    # `sniff.sh --summary ""` after the wait loop - sniff.sh's own fix for
    # THAT (see its own comment) means it now fails loudly instead of
    # silently misrouting into an unrelated interactive prompt, but this
    # is the right place to catch it, before ever entering the wait loop.
    if [ "$__launch_rc" -ne 0 ] || [ -z "$CAPTURE_FILE" ]; then
        LOG "$__launch_out"
        ERROR_DIALOG "Capture failed to start on $iface - see log for why (a bad interface, tcpdump missing, or an invalid filter are the likely causes)."
        return 1
    fi

    if [ -n "$dur" ]; then
        LOG "Live capture on $iface (${dur}s) - A: pause/resume view, B: stop."
    else
        LOG "Live capture on $iface (until stopped) - A: pause/resume view, B: stop."
    fi
    start_scroll
    local paused=0 __btn
    while true; do
        __btn=$(WAIT_FOR_INPUT)
        case "$__btn" in
            A)
                if [ "$paused" = "0" ]; then
                    stop_scroll
                    LOG "-- Paused. Scroll up to review. Press A to resume, B to stop. --"
                    paused=1
                else
                    LOG "-- Resuming live view --"
                    start_scroll
                    paused=0
                fi
                ;;
            B)
                # As asked for: B doesn't stop immediately - it confirms
                # first, so an accidental/exploratory press doesn't cut a
                # capture short. Answering no just keeps going untouched.
                if CONFIRMATION_DIALOG "Stop monitoring and exit?"; then
                    stop_scroll
                    /root/scripts/sniff.sh --stop >/dev/null 2>&1
                    break
                else
                    LOG "-- Continuing. Press B again when ready to stop. --"
                fi
                ;;
        esac
        if [ -n "$dur" ] && ! /root/scripts/sniff.sh --status 2>&1 | grep -q Running; then
            stop_scroll
            LOG "-- Capture finished (${dur}s elapsed). Press any button to see the summary. --"
            WAIT_FOR_INPUT >/dev/null
            break
        fi
    done
}

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here (and in pick_duration() above) mistook LIST_PICKER's
# REQUIRED trailing default-selection argument for an accidental repeated
# menu item and deleted it. Confirmed against Hak5's own docs:
# `LIST_PICKER [title] [option] [default]` - the last argument is a
# required "which option is preselected" parameter, separate from the
# option list ("A default option must always be provided!"). Restored
# here (defaulting to "Quick capture", the original pre-regression default).
__mode=$(LIST_PICKER "LAN Sniffer" "Quick capture" "Bridge/tap both adapters (keeps full internet access)" "Check adapter status" "Quick capture") || exit 0

case "$__mode" in
    "Check adapter status")
        __a=$(usb_a_iface)
        if iface_up eth0; then LOG "USB-C (eth0): connected"; else LOG "USB-C (eth0): not connected"; fi
        if [ -z "$__a" ]; then
            LOG "USB-A: no external adapter detected"
        elif iface_up "$__a"; then
            LOG "USB-A ($__a): connected"
        else
            LOG "USB-A ($__a): detected but link down"
        fi
        ALERT "Adapter status - see log"
        exit 0
        ;;

    "Bridge/tap both adapters (keeps full internet access)")
        LOG "Checking adapters (USB-C + USB-A)..."
        __a=$(usb_a_iface)
        if [ -z "$__a" ] || ! iface_up "$__a" || ! iface_up eth0; then
            ERROR_DIALOG "Bridge/tap needs BOTH USB-C and a connected USB-A adapter. Check 'Check adapter status' to see what's missing."
            exit 0
        fi
        LOG "USB-C (eth0) and USB-A ($__a) both connected."
        if ! CONFIRMATION_DIALOG "Bridge eth0 <-> $__a? The PC keeps FULL internet access through the router the whole time - the Pager just sits transparently in the middle and watches a copy of the traffic, it doesn't interrupt anything. Proceed?"; then
            LOG "User cancelled."
            exit 0
        fi
        # REMOVED (asked for directly - "the dhcp doesnt work, remove it
        # please"): this used to also offer --dhcp here (a real IP on the
        # tapped LAN so SSH stays reachable without a reset afterward -
        # see sniff.sh's own start_bridge_dhcp()). The Pager's own lease
        # genuinely worked (confirmed live via /tmp/pager-sniff-dhcp.log),
        # but nothing made that success visible from this payload, and the
        # client-side auto-renew mechanism that would have made it useful
        # end-to-end was reverted as unsafe (see README.md's postmortem -
        # it risked a full USB re-enumeration, not just a link blip). Left
        # out of this flow entirely for now rather than offering a feature
        # whose benefit doesn't actually land; sniff.sh --bridge --dhcp is
        # still there directly if this gets revisited later.
        #
        # BUG FOUND AND FIXED (reported live, twice - "it just stayed
        # here", and separately "doesn't spam me with info" during this
        # exact window): the bridge call used to be one big blocking
        # command substitution - nothing printed inside it (sniff.sh's own
        # step-by-step progress) ever reached the screen until the WHOLE
        # call returned, so one static line sat on screen for the entire
        # ~10s+ setup, indistinguishable from a hang. Fixed by running the
        # bridge command in the background and tailing sniff.sh's own
        # BRIDGE_PROGRESS_FILE (see its --bridge handler) while it runs,
        # rendering a reset.sh-style progress bar as each real step lands.
        LOG "Bridging $__a and eth0 now - this briefly touches the network stack, so expect a real pause between steps, not a hang."
        __bridge_progress_file="/tmp/pager-sniff-bridge-progress.log"
        rm -f "$__bridge_progress_file" /tmp/pager-sniff-bridge-out.log /tmp/pager-sniff-bridge-rc
        # BUG FOUND AND FIXED (defense-in-depth, CRITICAL): sniff.sh's own
        # `ip link` calls each carry a bounded timeout (see its `ip_link`
        # wrapper), but this outer timeout is a backstop against ANY other
        # unforeseen blocking condition inside sniff.sh --bridge (a wedged
        # sysfs read in check_adapters, etc.). 60s comfortably exceeds the
        # worst case of every internal 5s ip_link timeout firing in
        # sequence (at most ~10 calls = 50s).
        ( timeout 60 /root/scripts/sniff.sh --bridge eth0 "$__a" -y >/tmp/pager-sniff-bridge-out.log 2>&1
          echo $? >/tmp/pager-sniff-bridge-rc ) &
        __bridge_pid=$!
        __bridge_last=0
        __bridge_total=8
        while kill -0 "$__bridge_pid" 2>/dev/null; do
            sleep 1
            __bridge_cur=$(wc -l < "$__bridge_progress_file" 2>/dev/null || echo 0)
            if [ "$__bridge_cur" -gt "$__bridge_last" ] 2>/dev/null; then
                tail -n "+$((__bridge_last + 1))" "$__bridge_progress_file" 2>/dev/null | while IFS= read -r __pl; do LOG "$__pl"; done
                __bridge_last="$__bridge_cur"
                LOG "$(bridge_progress_bar "$__bridge_last" "$__bridge_total")"
            fi
        done
        wait "$__bridge_pid" 2>/dev/null
        # Final catch-up: the loop above only notices new progress lines
        # once per second, so whatever got written in the gap between the
        # last check and the process actually exiting (almost always the
        # final "Bridge is up" line) would otherwise never be shown - do
        # one last read of anything not yet displayed before checking the
        # result.
        __bridge_cur=$(wc -l < "$__bridge_progress_file" 2>/dev/null || echo 0)
        if [ "$__bridge_cur" -gt "$__bridge_last" ] 2>/dev/null; then
            tail -n "+$((__bridge_last + 1))" "$__bridge_progress_file" 2>/dev/null | while IFS= read -r __pl; do LOG "$__pl"; done
            __bridge_last="$__bridge_cur"
        fi
        __bridge_rc=$(cat /tmp/pager-sniff-bridge-rc 2>/dev/null); __bridge_rc=${__bridge_rc:-1}
        # BUG FOUND AND FIXED: this call's success/failure was never
        # checked - if bridging failed for any reason (ip link add/set
        # erroring, a rare race after the adapter checks above), the
        # script continued anyway straight into run_live_capture on an
        # interface ("br-sniff") that was never actually created, which
        # then just showed a live view with nothing ever scrolling and no
        # explanation why - looked exactly like a hang instead of the
        # clear ERROR_DIALOG this toolkit uses everywhere else for a real
        # failure.
        if [ "$__bridge_rc" -ne 0 ]; then
            LOG "$(cat /tmp/pager-sniff-bridge-out.log 2>/dev/null)"
            ERROR_DIALOG "Failed to create the bridge (or it timed out) - see log for details. eth0 should already be restored to br-lan by sniff.sh's own safety net."
            exit 1
        fi
        # BUG FOUND AND FIXED (reported live): after a successful bridge,
        # sniff.sh's own multi-line success output filled the visible log,
        # then pick_duration() immediately calls LIST_PICKER - a real
        # on-screen prompt waiting for a physical button press, but with
        # nothing distinguishing "still working" from "waiting on you"
        # after a wall of text just scrolled by. Looked exactly like a
        # hang (confirmed live: the underlying bridge had actually already
        # come up successfully - kernel logs showed both ports reach
        # forwarding state - the payload was just sitting at an
        # unannounced prompt). A one-off ALERT here (not LOG, which could
        # stay buried in the scroll) makes the transition unmistakable.
        ALERT "Bridge is up - pick a capture duration next"
        # BUG FOUND AND FIXED: previously the ONLY --unbridge call was
        # after run_live_capture returned successfully - if anything
        # between here and there went wrong (a cancelled picker, an
        # error), br-sniff was left up with no way to reach it from a
        # normal exit path. A real EXIT trap runs regardless of how/where
        # this script stops from here on, same "don't rely on the happy
        # path alone" lesson already learned elsewhere in this toolkit.
        # BUG FOUND AND FIXED (defense-in-depth): this trap is the ONLY
        # thing standing between a normal/error exit and eth0 being stuck
        # off br-lan - it must never be able to hang itself. sniff.sh's
        # own --unbridge now bounds every `ip_link` call it makes
        # internally, but an outer timeout here is a cheap extra backstop
        # against anything else unforeseen, same reasoning as the --bridge
        # call above.
        trap 'timeout 30 /root/scripts/sniff.sh --unbridge -y >/dev/null 2>&1' EXIT
        __dur=$(pick_duration) || exit 0
        # BUG FOUND AND FIXED: this never checked whether run_live_capture
        # actually got anywhere (see its own new liveness check) before
        # unconditionally calling --summary on whatever CAPTURE_FILE ended
        # up being (empty, if the launch failed) - the exact chain that
        # produced both "not spamming with IPs" and the missing save-log
        # prompt on the same live run (sniff.sh --summary "" used to fall
        # through into an unrelated, non-interactive-hostile code path
        # instead of erroring - see that file's own fix).
        if run_live_capture "br-sniff" "" "$__dur"; then
            __out=$(/root/scripts/sniff.sh --summary "$CAPTURE_FILE" 2>&1)
            LOG "$__out"
            maybe_save_log "$__out"
            ALERT "Capture complete - see log"
        fi
        ;;

    *)
        __a=$(usb_a_iface)
        if [ -n "$__a" ] && iface_up "$__a"; then
            __iface="$__a"
        elif iface_up eth0; then
            __iface="eth0"
            LOG "No USB-A adapter - using eth0 (built-in port, may include your own SSH session)."
        else
            ERROR_DIALOG "No wired LAN adapter connected - nothing to sniff."
            exit 0
        fi
        __dur=$(pick_duration) || exit 0
        __filter=$(TEXT_PICKER "tcpdump filter (blank = everything)" "") || exit 0
        # BUG FOUND AND FIXED (same class as the Bridge/tap case above): the
        # launch's own success was never checked before unconditionally
        # calling --summary on whatever CAPTURE_FILE ended up being.
        if run_live_capture "$__iface" "$__filter" "$__dur"; then
            __out=$(/root/scripts/sniff.sh --summary "$CAPTURE_FILE" 2>&1)
            LOG "$__out"
            maybe_save_log "$__out"
            ALERT "Capture complete - see log"
        fi
        ;;
esac

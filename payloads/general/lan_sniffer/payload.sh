#!/bin/bash
# Title: LAN Sniffer
# Author: florian
# Description: Live LAN traffic view (auto-detected USB-A adapter, or bridge/tap both wired ports - internet is forwarded through, not blocked, with a brief settling window after bridging) - timer or infinite duration, A pauses/resumes, B asks to stop, then offers to save the full log. HTTP/DNS/creds flagged live.
# Version: 3.6
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
# dialog, and a fixed-timer-only duration picker). v3.3 fixed the bridge
# setup's own missing progress feedback and removed the --dhcp option from
# this flow (see README.md's postmortem on why). v3.3 also tried an
# "IP -> URL, like bettercap/Wireshark" tagging improvement for the live
# watcher, but shipped it broken (an awk rewrite that measured 4x+ slower
# than plain grep on this device, so it never actually produced a live
# tag) and had to revert it the same day. v3.4 (this version) replaces
# that revert with a real, verified-live fix: sniff.sh's run_creds_watcher
# now tags live HTTP/creds hits with source IP and destination host,
# built by keeping the expensive full-file scanning on grep (the fast
# part) and only doing the per-hit IP/host lookup for the handful of
# lines grep actually flags - see its own comment for the measured
# numbers and the honest remaining limits (still not sub-5s "live" for a
# genuinely busy capture; the same real event can occasionally get tagged
# twice due to a tcpdump -A quirk). v3.5 (this version) fixes three more
# reports from a real extended, busy capture: the device could crash
# outright (sniff.sh's live watchers had no cap on how much of a growing
# capture they'd re-scan every cycle - fixed there with a MAX_LIVE_WATCH_
# BYTES cap and timeout-bounded calls, see sniff.sh's own comment);
# "Stop monitoring and exit?" and pausing with A could both have a long,
# confusing delay before actually taking effect (same root cause, plus
# this payload's own scroller queuing one LOG call per new line during a
# busy feed - now batched into one call per poll tick); and the "internet
# access stays intact" claim in the Bridge/tap confirmation dialog and
# menu wording was softened to match what was actually observed live
# (forwarded, not blocked, but with a real ~1-2 minute settling window
# right after bridging - see README.md's postmortem).
#
# v3.6 (this version) is a UX/polish pass over the on-screen flow, applying
# Hak5's own ALERT-vs-LOG convention (ALERT: full-screen, ringtone-playing,
# reserved for rare/important events like deauth floods, handshakes,
# client connections; LOG: routine on-screen line) consistently in both
# directions. A live [CREDS FOUND] hit from sniff.sh's own run_creds_watcher
# previously only ever showed up as just another line inside the live
# view's routine, LOG-batched traffic feed - meaning it could be buried
# among dozens of ordinary lines, or even silently dropped by that
# scroller's own 40-line-per-poll-tick truncation during a genuinely busy
# capture. It now fires as its own dedicated, always-shown LOG line up
# front (scanning the untruncated new lines each tick, so a hit can never
# be truncated away first) instead of only ever being buried inside the
# routine feed. (An ALERT was tried here first for maximum visibility, but
# had to be reverted - it competes with this same live view's own
# WAIT_FOR_INPUT for "waiting on a button" and can render out of order via
# the platform's own queuing; see the BUG FOUND AND FIXED comment on that
# revert, further down where the creds scan itself lives, for the full
# story.) In the other direction, three ALERTs that fired on the routine,
# expected, 100%-of-the-time path (adapter status after the operator
# explicitly asked to check it; capture-complete after both capture flows,
# immediately following three direct operator interactions in a row on
# that exact screen) were switched to a plain LOG completion marker - they
# added nothing the operator didn't already know, and diluted ALERT's
# signal value everywhere else it's used.
#
# Button behavior: A pauses/resumes the live view (pausing stops new
# lines from arriving so you can scroll back through what's already on
# screen without it moving; A again resumes). B asks "Stop monitoring and
# exit?" - answer no and it keeps running untouched; answer yes and it
# stops, shows the summary, then asks whether to save the full log.
#
# "Wireshark-like" live content: sniff.sh's own live watcher (see its
# run_creds_watcher) surfaces HTTP requests (tagged [HTTP], as
# "SRC -> HOST  request text") and credential hits (tagged [CREDS FOUND],
# matched text highlighted red over SSH) AS THEY'RE SEEN, into the same
# live-scrolling log this payload tails - not just in the end-of-capture
# summary.
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

# plog MESSAGE - INTEGRATION FIX (cross-file trace, round 2: could a user
# watching the screen get confusingly interleaved or duplicate-sounding
# messages about the same physical event from two independent scripts?).
# usb_monitor.sh runs as a fully independent background daemon (see its own
# header) that can fire its own on-screen LOG notification for the exact
# SAME physical USB-A attach/detach event this payload's own bridge session
# (via sniff.sh's watchdog) reacts to - both land on the SAME on-screen Log
# view, interleaved by whenever each happens to fire. Read both sides
# directly to confirm this is real, not assumed: usb_monitor.sh's own
# notify() calls `LOG "$1"` with the raw message and no prefix at all (e.g.
# "USB-A (eth1): detached"), while this payload's own direct on-screen
# narration (adapter status, capture start/pause/stop, bridge setup) was
# ALSO entirely unlabeled - a user has no way to tell, from either side,
# which of two independent scripts a given line came from, and the wording
# can look like a near-duplicate report of the same event (usb_monitor.sh's
# own "USB-A (eth1): detached" alongside sniff.sh watchdog's own "Bridge
# member interface(s) eth1 disappeared..." for the identical physical
# unplug - that second one at least already carries sniff.sh's own
# "[sniff.sh watchdog]" tag, via its bridge_progress()/say() helpers, so
# it's already unambiguous; this payload's OWN direct lines were the actual
# gap). usb_monitor.sh's matching half of this fix (tagging its own notify()
# LOG call) is out of this pass's edit scope - flagged separately for
# follow-up there; this wraps the half reachable from here. Deliberately
# only used for this payload's own single-purpose narration lines, never for
# the scroller's raw multi-line chunk relay (already self-tagged per-line by
# sniff.sh, or deliberately unlabeled raw packet text) or captured
# sniff.sh/tcpdump output passed through verbatim (same reason - those
# already carry their own [sniff.sh]-style tags or are self-evidently
# capture output).
plog() { LOG "[LAN Sniffer] $1"; }

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
    # HARDENING (reported live - "a prompt that says 'pick a time' shows
    # up even after Infinite was picked, I need to click it away"): an
    # exact `= "Infinite (until B)"` match is brittle against anything
    # the platform might do to the returned string (trailing whitespace,
    # a truncated/reformatted echo of a long option on a small screen) -
    # any mismatch silently fell through to the `else` and popped
    # NUMBER_PICKER right after Infinite was already chosen. Matching on
    # just the leading "Infinite" via a case pattern (and trimming
    # surrounding whitespace first) is tolerant of that without being any
    # less correct - "Timer" can never start with "Infinite". Root cause
    # not fully confirmed without a live re-test (could also be an
    # input-event timing race with the ALERT right before this call,
    # addressed separately below), so this is a defensive fix either way,
    # not a guess dressed up as a confirmed one.
    __choice="${__choice#"${__choice%%[![:space:]]*}"}"
    __choice="${__choice%"${__choice##*[![:space:]]}"}"
    case "$__choice" in
        Infinite*) echo "" ;;
        *) NUMBER_PICKER "Capture duration (seconds)" 30 || return 1 ;;
    esac
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
        # CONSISTENCY FIX: these two lines are this payload's own
        # single-purpose narration about an action IT just took (same
        # category as "Bridge is up...", "-- Capture complete --", the
        # adapter-status lines, etc. - all routed through plog() elsewhere
        # in this file) - not a raw relay of sniff.sh/tcpdump output or the
        # scroller's own multi-line chunk feed, the two cases plog()'s own
        # header comment carves out as deliberately untagged. These two
        # calls were left on bare LOG (no "[LAN Sniffer] " tag) when plog()
        # was introduced, unlike every other narration line in this file.
        plog "Saved to $dest"
    else
        plog "Not saved."
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
# BUG FOUND AND FIXED (CRITICAL, cross-fix interaction - fresh-eyes review,
# verified with a standalone repro): start_scroll()'s poller used to
# initialize `__last=0` fresh EVERY time it (re)started. That's correct for
# the very first start, but this same function is also what A's resume path
# calls (stop_scroll() kills the poller subshell outright, resume calls
# start_scroll() again, which forks a BRAND NEW subshell with its own fresh
# `local __last=0` - the whole point of the orphan-safety fix above is that
# each start/stop is a totally new process). The underlying sniff.sh capture
# is never actually paused by A - only this on-screen poller is - so
# /tmp/pager-sniff.log keeps growing the entire time the operator is
# paused. Resuming with a fresh `__last=0` then treats the WHOLE file,
# including everything already shown before the pause, as "new" again.
# Confirmed standalone: write 5 lines, start the poller, stop it, write 3
# more lines, start it again - the resumed poller re-displayed all 5
# original lines alongside the 3 genuinely new ones. Worse than just
# repetitive: it re-feeds already-seen text through the creds-hit scan
# below too, so a credential already flagged before a pause fires its
# "!! CREDENTIAL(S) CAPTURED !!" line again on every single resume for the
# rest of the session - exactly the kind of noise tonight's batching/dedup
# work elsewhere in this function was trying to eliminate. Fixed by
# persisting the last-seen line count to a small state file instead of a
# subshell-local variable (which cannot survive the subshell being killed
# and re-forked) - start_scroll() reads it back in on every (re)start, so a
# resume only ever catches up on what actually arrived during the pause.
# Reset once per session, right before the FIRST start_scroll() call (see
# run_live_capture() below) - a genuinely new capture still starts from 0,
# only the pause/resume replay is fixed.
SCROLLER_LAST_FILE="/tmp/pager-sniff-scroll-last"
start_scroll() {
    (
        local __last __new_lines __new_count __chunk __creds_hit
        __last=$(cat "$SCROLLER_LAST_FILE" 2>/dev/null); __last=${__last:-0}
        while :; do
            # BUG FOUND AND FIXED (race, low severity - verified with a
            # standalone repro): this used to take a `wc -l` snapshot of
            # the total line count, THEN separately read the new lines
            # via `tail`. If a concurrent writer (the packet feed or
            # creds watcher) appended between those two calls, `tail`
            # picked up the extra line(s) but `__last` was then set from
            # the OLDER, smaller `wc -l` snapshot - so the same line(s)
            # got re-read and re-displayed (and re-scanned for creds) on
            # the NEXT tick too. Deriving both the new-lines read AND the
            # updated `__last` from this SAME `tail` call (below) removes
            # the gap between the two reads entirely - nothing left for a
            # concurrent write to land in between. Also reads the new
            # lines ONCE per tick either way (used below both for the
            # creds scan and, possibly truncated, for the LOG chunk).
            __new_lines=$(tail -n "+$((__last + 1))" /tmp/pager-sniff.log 2>/dev/null)
            if [ -n "$__new_lines" ]; then
                __new_count=$(printf '%s\n' "$__new_lines" | wc -l)
                # BUG FOUND AND FIXED (CRITICAL, fresh-eyes review): the
                # previous version of this fired ALERT here for a live
                # [CREDS FOUND] hit. README.md's own postmortem on the
                # near-identical "Bridge is up" ALERT (see the comment on
                # that removal further down this file) confirms - from a
                # real live report - that ALERT BLOCKS until dismissed with
                # a button press, and can additionally get QUEUED by the
                # platform and rendered LATE, out of order with whatever is
                # already on screen. This poller runs as a BACKGROUND
                # subshell (started by start_scroll) CONCURRENTLY with
                # run_live_capture's own main-loop `WAIT_FOR_INPUT` call,
                # which already blocks waiting for a button press on every
                # single iteration for the entire live-view session - so
                # firing ALERT from here creates two simultaneous, competing
                # "waiting for a button" states owned by two different
                # processes at once. A real A press meant to dismiss this
                # ALERT could instead be consumed by the main loop's own
                # pause/resume handling instead (or the reverse - a press
                # meant to pause/resume dismisses the ALERT instead, leaving
                # the operator unsure which just happened), and given the
                # platform's own confirmed queuing quirk, the ALERT could
                # resurface at a confusing, unrelated later point in the
                # session rather than next to its actual trigger. It also
                # blocks THIS subshell itself until dismissed, silently
                # stalling the live view's own new-line polling for as long
                # as it sits undismissed - the exact "delayed/ignored
                # pause/stop" symptom class this file already fixed twice
                # elsewhere (see the scroller-batching and EXIT-trap fixes
                # above), just reached through a new door. Same root lesson
                # as the near-identical "Bridge is up" ALERT removed
                # elsewhere in this file for the same ordering/blocking
                # reason: swapped for a plain LOG line here too, which never
                # blocks and can never appear reordered/stuck relative to
                # WAIT_FOR_INPUT. Everything about the original fix that WAS
                # sound is kept: scanning the FULL new-lines read (before
                # the 40-line truncation below) so a creds hit can never be
                # silently truncated away, and capping to 3 lines/tick so a
                # burst of several at once can't flood the log.
                __creds_hit=$(echo "$__new_lines" | grep '^\[CREDS FOUND\]' | head -3)
                [ -n "$__creds_hit" ] && LOG "!! CREDENTIAL(S) CAPTURED - see below !!
$__creds_hit"
                # BUG FOUND AND FIXED (live-caught - reported as "button A
                # doesn't pause it" and a delayed/ignored "Stop monitoring
                # and exit?"): this used to call LOG once PER NEW LINE via
                # a `while read` loop - during a busy capture (the packet
                # feed alone ticks every 2s, plus the creds watcher's own
                # output), a single poll cycle here could queue dozens of
                # separate LOG calls back to back. The platform's own
                # on-screen log appears to drain already-queued messages
                # independently of this script's own process state (this
                # session's other finding: a queued ALERT could render
                # after the process that issued it had already moved on to
                # a later step) - so a deep backlog of individually-queued
                # LOG calls keeps visibly scrolling for a while even after
                # this scroller (or the whole capture) is stopped, which
                # looks exactly like "pause/stop doesn't work" even though
                # the script side already did what it was asked the moment
                # it was asked. Batching every new line into ONE LOG call
                # (embedded newlines - already proven to render fine, e.g.
                # sniff.sh's own multi-line success output) queues exactly
                # one message per poll tick instead of up to dozens,
                # directly shrinking that backlog. Also caps to the most
                # recent 40 lines per tick (with a "N skipped" note) so a
                # single genuinely huge burst can't itself become one
                # enormous, slow-to-render LOG call.
                if [ "$__new_count" -gt 40 ]; then
                    __chunk="-- $((__new_count - 40)) line(s) skipped, capture is very busy --
$(echo "$__new_lines" | tail -n 40)"
                else
                    __chunk="$__new_lines"
                fi
                LOG "$__chunk"
                __last=$((__last + __new_count))
                echo "$__last" > "$SCROLLER_LAST_FILE" 2>/dev/null
            fi
            # PERFORMANCE FIX (measured, not just "feels faster"): this
            # polled /tmp/pager-sniff.log every 1s for the ENTIRE live-view
            # session (which can run for the full duration of an Infinite-
            # mode capture, potentially hours) - a subprocess spawn (this
            # tick's file read, `wc -l` at the time this comment was
            # written, `tail` now that the race fix above folded the total-
            # count read and the new-lines read into one call) every single
            # second regardless of whether anything new had actually
            # arrived. The fastest thing that ever writes NEW lines into
            # that log is sniff.sh's own run_packet_feed, on a fixed 2s
            # cadence (see its own header comment there - the creds watcher
            # is slower still, at 5s) - nothing in this toolkit can ever
            # produce a fresh line faster than 2s apart, so a 1s poll here
            # was, on average, finding "nothing new" on every other tick and
            # paying a full subprocess spawn for that empty check anyway.
            # Slowing this to 2s - matching the fastest real producer
            # exactly - halves that spawn count for the life of the session
            # with no loss of responsiveness: a burst can still only ever
            # show up at most 2s after it was written, identical to today,
            # since nothing arrives sooner.
            # Button responsiveness (A/B) is unaffected either way - that's
            # WAIT_FOR_INPUT blocking in the separate main loop below, not
            # gated by this poller's interval at all.
            sleep 2
        done
    ) &
    SCROLLER_PID=$!
}
stop_scroll() {
    [ -n "$SCROLLER_PID" ] && kill "$SCROLLER_PID" 2>/dev/null
    SCROLLER_PID=""
}

# BUG FOUND AND FIXED (CRITICAL, fresh-eyes review): start_scroll()'s
# background poller (a `while :; sleep 1; done` subshell tailing
# /tmp/pager-sniff.log) was ONLY ever stopped via the explicit
# stop_scroll() calls inside run_live_capture's own pause/stop/duration-
# elapsed code paths. Bash does not kill background jobs when their
# parent script exits (that's only `huponexit`, which doesn't apply to a
# non-interactive script) - so if this script exits by ANY other route
# (the platform force-stopping the payload, a signal, an unexpected
# error) while the scroller is running, the poller subshell is orphaned
# and keeps running forever, calling LOG every second indefinitely -
# the exact "background helper survives its parent" class already
# confirmed live tonight for a bridge watchdog. This applies to BOTH menu
# paths, including Quick Capture, which had no trap coverage at all.
# Fixed with a baseline `trap 'stop_scroll' EXIT` here, active from this
# point on regardless of which mode runs; the Bridge/tap branch below
# installs its own trap that also unbridges, which folds this same
# stop_scroll call in rather than losing it.
trap 'stop_scroll' EXIT

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
        plog "Live capture on $iface (${dur}s) - A: pause/resume view, B: stop."
    else
        plog "Live capture on $iface (until stopped) - A: pause/resume view, B: stop."
    fi
    # Reset the persisted scroll position for this NEW session (see the
    # BUG FOUND AND FIXED comment on SCROLLER_LAST_FILE above) - a leftover
    # value from a previous run_live_capture() call must never leak in here
    # and make this fresh capture's own early lines look already-seen.
    rm -f "$SCROLLER_LAST_FILE"
    start_scroll
    local paused=0 __btn
    while true; do
        __btn=$(WAIT_FOR_INPUT)
        case "$__btn" in
            A)
                if [ "$paused" = "0" ]; then
                    stop_scroll
                    plog "-- Paused. Scroll up to review. Press A to resume, B to stop. --"
                    paused=1
                else
                    plog "-- Resuming live view --"
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
                    plog "-- Continuing. Press B again when ready to stop. --"
                fi
                ;;
        esac
        # BUG FOUND AND FIXED (CRITICAL, fresh-eyes review, verified with a
        # standalone repro): this grepped for "Running" (capital R), but
        # sniff.sh's own --status output (see its DO_STATUS block) is
        # `say "Capture running (PID $PID)."` - lowercase "running" - and
        # grep is case-sensitive by default, so this pattern NEVER matched
        # either of --status's two possible lines. Confirmed standalone:
        # `echo "Capture running (PID 1234)." | grep -q Running; echo $?`
        # prints 1 (no match) - same result for the "Not running." line.
        # That means `! sniff.sh --status | grep -q Running` was ALWAYS
        # true whenever `$dur` was set (Timer mode), regardless of whether
        # the background capture was actually still running - so THE VERY
        # FIRST button press in ANY Timer-duration session (A to pause, or
        # B answered "no") immediately fell into this "finished" branch,
        # telling the operator the capture was done and ending the live
        # view, even if only a few seconds of a much longer timer had
        # elapsed. The real background capture (launched via sniff.sh
        # --background, self-bounded by its own `timeout $DURATION`) kept
        # running untouched - this codepath never calls --stop - so
        # --summary then ran against a .pcap tcpdump was still actively
        # writing to, and in the Bridge/tap flow the EXIT trap tore the
        # bridge down immediately afterward, while the capture on br-sniff
        # was still supposed to be live. A naive case-insensitive fix
        # (`grep -qi running`) would be equally wrong the other way -
        # verified standalone that "Not running." also contains the
        # substring "running", so `grep -qi running` matches BOTH lines
        # unconditionally, making the condition permanently false instead
        # of permanently true. Matching the exact phrase "Capture running"
        # (only present in the true-positive line) is what --status
        # actually needs to be told apart correctly - verified standalone
        # against both real --status output lines before applying here.
        if [ -n "$dur" ] && ! /root/scripts/sniff.sh --status 2>&1 | grep -q "Capture running"; then
            stop_scroll
            plog "-- Capture finished (${dur}s elapsed). Press any button to see the summary. --"
            WAIT_FOR_INPUT >/dev/null
            break
        fi
    done
    # BUG FOUND AND FIXED (defense-in-depth): without an explicit return,
    # this function's exit status is whatever the LAST command executed
    # happened to return - `/root/scripts/sniff.sh --stop` on the
    # B-confirmed-stop path, or `WAIT_FOR_INPUT` on the duration-elapsed
    # path - neither of which is a deliberate, documented signal of "did
    # the live-capture session complete successfully." Both callers gate
    # the entire --summary/maybe_save_log/"Capture complete" flow on this
    # function's return code (`if run_live_capture ...; then ...`), so an
    # incidental non-zero from either of those commands (sniff.sh --stop
    # currently always exits 0 per its own code, but WAIT_FOR_INPUT's exit
    # contract is an external platform primitive this file never actually
    # asserts) would silently skip the summary and save-log prompt after a
    # perfectly successful capture, with no error shown at all. Every path
    # that reaches here (the only way out of `while true; do ... done` is
    # one of the two `break`s above) represents a genuine, intentional
    # completion, so make that explicit instead of leaving it to chance.
    return 0
}

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here (and in pick_duration() above) mistook LIST_PICKER's
# REQUIRED trailing default-selection argument for an accidental repeated
# menu item and deleted it. Confirmed against Hak5's own docs:
# `LIST_PICKER [title] [option] [default]` - the last argument is a
# required "which option is preselected" parameter, separate from the
# option list ("A default option must always be provided!"). Restored
# here (defaulting to "Quick capture", the original pre-regression default).
__mode=$(LIST_PICKER "LAN Sniffer" "Quick capture" "Bridge/tap both adapters (internet forwarded, brief settle time)" "Check adapter status" "Quick capture") || exit 0

case "$__mode" in
    "Check adapter status")
        __a=$(usb_a_iface)
        if iface_up eth0; then plog "USB-C (eth0): connected"; else plog "USB-C (eth0): not connected"; fi
        if [ -z "$__a" ]; then
            plog "USB-A: no external adapter detected"
        elif iface_up "$__a"; then
            plog "USB-A ($__a): connected"
        else
            plog "USB-A ($__a): detected but link down"
        fi
        # IMPROVEMENT (ALERT-vs-LOG convention pass): this fired on every
        # single use of "Check adapter status" - a menu item the operator
        # picked on purpose, with the four status lines just LOG'd right
        # above and nothing about the result unexpected (it's exactly what
        # they asked to see). That's the opposite of Hak5's own convention
        # for ALERT (a full-screen, ringtone-playing interrupt reserved for
        # rare, high-signal events like deauth floods or captured
        # handshakes) - a routine, 100%-of-the-time, user-requested status
        # readout doesn't qualify, and a ringtone interrupt right after
        # they just pressed a button to ask for exactly this only trains
        # the operator to dismiss ALERTs on reflex, diluting the signal
        # ALERT is supposed to carry elsewhere (see the live-capture ALERT
        # added above for a genuinely rare/important use of it). Switched
        # to the same "-- ... --" marker idiom already used throughout this
        # file's scroller for a plain completion note.
        plog "-- Adapter status shown above --"
        exit 0
        ;;

    "Bridge/tap both adapters (internet forwarded, brief settle time)")
        plog "Checking adapters (USB-C + USB-A)..."
        __a=$(usb_a_iface)
        if [ -z "$__a" ] || ! iface_up "$__a" || ! iface_up eth0; then
            ERROR_DIALOG "Bridge/tap needs BOTH USB-C and a connected USB-A adapter. Check 'Check adapter status' to see what's missing."
            exit 0
        fi
        plog "USB-C (eth0) and USB-A ($__a) both connected."
        # BUG FOUND AND FIXED (live-caught, twice - the original wording
        # was misleading): this used to claim the PC "keeps FULL internet
        # access... the whole time" - live-observed on two separate real
        # bridge sessions that this isn't quite true: there's a real,
        # bounded settling window (roughly 1-2 minutes, self-resolving)
        # right after the bridge comes up where new connections can fail
        # or load slowly while the client's own ARP/neighbor-discovery
        # cache catches up with the topology change - see README.md's
        # postmortem for the full detail. Already-open connections mostly
        # survive; brand-new ones are what's affected. Softened the claim
        # to match what was actually observed instead of promising
        # something that wasn't quite true.
        if ! CONFIRMATION_DIALOG "Bridge eth0 <-> $__a? The PC's internet access is forwarded through, not blocked - but expect a real settling window of roughly 1-2 minutes right after this comes up where some sites load slowly or not at all while your PC's own network cache catches up with the change. It self-resolves; no action needed. Proceed?"; then
            plog "User cancelled."
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
        plog "Bridging $__a and eth0 now - this briefly touches the network stack, so expect a real pause between steps, not a hang."
        __bridge_progress_file="/tmp/pager-sniff-bridge-progress.log"
        rm -f "$__bridge_progress_file" /tmp/pager-sniff-bridge-out.log /tmp/pager-sniff-bridge-rc
        # BUG FOUND AND FIXED (defense-in-depth, CRITICAL): sniff.sh's own
        # `ip link` calls each carry a bounded timeout (see its `ip_link`
        # wrapper), but this outer timeout is a backstop against ANY other
        # unforeseen blocking condition inside sniff.sh --bridge (a wedged
        # sysfs read in check_adapters, etc.).
        #
        # BUG FOUND AND FIXED (cross-file integration trace - the "~10
        # calls = 50s" margin claim above went stale as sniff.sh's own
        # --bridge handler grew): recounted every ip_link()/`ip addr flush`
        # call sniff.sh's CURRENT --bridge block actually makes, in order:
        # 2 existence checks (BR_IFACE1, BR_IFACE2) + 1 "does $BRIDGE_NAME
        # already exist" check + (if it does - a real, reachable case, e.g.
        # a leftover bridge from a previous incomplete teardown; see
        # reset.sh's own "br-sniff still exists" path for why that's not
        # hypothetical) 2 more for tearing it down first + 1 add + 1 attach
        # BR_IFACE1 + 1 attach BR_IFACE2 + 2 address-flush calls + 3 "up"
        # calls (BR_IFACE1, BR_IFACE2, $BRIDGE_NAME) = 13 calls in that
        # realistic worst case, not ~10. At sniff.sh's own default
        # IP_LINK_TIMEOUT (5s, PAGER_IP_LINK_TIMEOUT), 13 calls each taking
        # the full timeout before succeeding is 65s - already past the old
        # 60s outer timeout here, meaning this backstop could fire and abort
        # a --bridge attempt that was genuinely still making progress
        # (never dying, just slow) rather than one that was actually stuck.
        # Widened to 90s for real margin above the recounted 65s worst case;
        # this is still just a backstop against something ELSE hanging
        # (every ip_link call already fails cleanly on its own 5s timeout
        # long before 90s), not the expected/typical duration of a healthy
        # --bridge run.
        ( timeout 90 /root/scripts/sniff.sh --bridge eth0 "$__a" -y >/tmp/pager-sniff-bridge-out.log 2>&1
          echo $? >/tmp/pager-sniff-bridge-rc ) &
        __bridge_pid=$!
        # BUG FOUND AND FIXED (CRITICAL, fresh-eyes review): the unbridge
        # trap used to be installed much further below, only AFTER
        # --bridge had already been confirmed to succeed. That left this
        # entire background-launch + progress-polling window (from here
        # down to where the exit code is read) with NO trap installed at
        # all - if the payload process is killed (platform force-quit, a
        # fatal error - anything short of SIGKILL/power-loss, see the
        # honest limitation noted further down) WHILE this loop is still
        # polling, the bridge is left up with nothing to tear it down:
        # the exact orphan class confirmed live tonight against sniff.sh's
        # own bridge watchdog, just triggered from inside the payload
        # instead of a raw SSH command. Installed here instead so the
        # ENTIRE window - setup polling included, not just what comes
        # after - is covered. Combines unbridge with stop_scroll (a no-op
        # via its own `[ -n "$SCROLLER_PID" ]` guard until the live view
        # actually starts) into one trap, replacing the baseline
        # `trap 'stop_scroll' EXIT` set near the top of the script, so
        # both cleanups are covered no matter when in this flow things
        # stop.
        trap 'stop_scroll; timeout 30 /root/scripts/sniff.sh --unbridge -y >/dev/null 2>&1' EXIT
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
        # BUG FOUND AND FIXED, TWICE (reported live both times - the exact
        # wording changed but the report was the same: a "pick a
        # time"-ish dialog appearing AFTER the Duration picker had already
        # been answered, dismissible with a single A press). The original
        # concern this ALERT solved was real (sniff.sh's own multi-line
        # success output filled the screen, then pick_duration() calling
        # LIST_PICKER right after looked exactly like a hang with nothing
        # distinguishing "still working" from "waiting on you"). The FIRST
        # fix attempt (a 1s settle pause before pick_duration(), removed
        # below) assumed the problem was a stray button press leaking from
        # the ALERT into the following LIST_PICKER - reported live as
        # unfixed, still happening. Re-diagnosed: the report ("appears
        # AFTER Infinite was already chosen, needs A to dismiss") matches
        # ALERT's own single-dismiss behavior exactly, not NUMBER_PICKER -
        # meaning the platform most likely QUEUES this ALERT and doesn't
        # actually render it until AFTER the very next LIST_PICKER's own
        # interaction finishes, regardless of any pause added beforehand -
        # an ordering problem no amount of sleep() between the two calls
        # can fix, since the ALERT was already queued before the sleep
        # even started. Original justification for needing a hard,
        # button-press-gated ALERT here is also weaker now than when it
        # was added: the bridge setup already ends with a live progress
        # bar reaching 100% and its own "Bridge is up" line (see the
        # progress-bar fix above), which already makes "something just
        # happened, look here" obvious without a second blocking modal
        # that can be reordered. Removed the ALERT entirely rather than
        # attempt a third guess at its timing; a plain LOG line (which
        # doesn't need dismissing, so it can never appear stuck) keeps the
        # log the same "bridge is up" wording either way.
        plog "Bridge is up - pick a capture duration next."
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
        #
        # NOTE: the actual `trap ... EXIT` call that does this now lives
        # further up, right after the background --bridge command is
        # launched - see the comment there for why (it needs to cover the
        # progress-polling loop too, not just what happens after it).
        #
        # HONEST LIMITATION (not fixable from inside this script): bash
        # EXIT traps run on normal exit and on ordinary catchable signals
        # (SIGTERM/SIGINT/etc.), but NEVER on SIGKILL - the kernel
        # delivers SIGKILL directly and terminates the process without
        # running any userspace code, trap included, and the same is true
        # if the device simply loses power. So a SIGKILL (or a power
        # loss) during the bridge-setup window still orphans the bridge
        # with no way for this script to prevent it - only an external
        # watchdog outside this process (like the one sniff.sh itself now
        # has, per tonight's fix there) can catch that specific case.
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
            # IMPROVEMENT (ALERT-vs-LOG convention pass): this ALERT fired
            # unconditionally at the end of EVERY completed capture - not a
            # rare event, and not one the operator could plausibly miss:
            # by this point they've already pressed B, answered "Stop
            # monitoring and exit?", read the summary just LOG'd above, and
            # answered maybe_save_log's own save-or-not prompt - three
            # direct interactions in a row on this exact screen. A full-
            # screen, ringtone-playing interrupt immediately after all that
            # tells them nothing new; it only trains them to reflex-dismiss
            # ALERTs, which is exactly what the platform's own convention
            # (deauth floods, handshakes, client connections - rare and
            # important) argues against, and dilutes the signal value of
            # the genuinely-important ALERT added above for a live
            # [CREDS FOUND] hit. (The Timer-elapsed path has the same
            # property from the other direction: run_live_capture already
            # gates on a button press - "Press any button to see the
            # summary" - before ever reaching here, so an away operator
            # already had to come back regardless of this ALERT.) Switched
            # to the same "-- ... --" completion-marker idiom already used
            # throughout this file's scroller output.
            plog "-- Capture complete --"
        fi
        ;;

    *)
        __a=$(usb_a_iface)
        if [ -n "$__a" ] && iface_up "$__a"; then
            __iface="$__a"
        elif iface_up eth0; then
            __iface="eth0"
            plog "No USB-A adapter - using eth0 (built-in port, may include your own SSH session)."
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
            # IMPROVEMENT: same reasoning as the Bridge/tap path above -
            # this is the routine end of every completed capture, not a
            # rare/important event, and fires after three direct operator
            # interactions in a row (B, the stop confirmation, the save
            # prompt) that already had their attention on this screen.
            plog "-- Capture complete --"
        fi
        ;;
esac

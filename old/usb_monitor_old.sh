#!/bin/bash
# usb_monitor.sh - Notifies every time a device attaches or detaches on
# USB-C (eth0, the built-in port) or USB-A (whatever's plugged into the
# external port). Not a payload on purpose - this is a plain background
# watcher, not something meant to be started/stopped or configured
# through a picker.
#
# BUG FOUND AND FIXED (reported live - tested with a real Netgear A8000
# USB WiFi adapter, no message ever appeared): the ORIGINAL USB-A
# detection only used detect_usb_a_iface() (lib/common.sh), which finds
# USB ETHERNET adapters specifically - correct for pc_link.sh's actual
# job (wired LAN capture), but it deliberately skips anything wlan*-
# prefixed, and a USB WiFi adapter never creates an ethN interface at
# all - it's invisible to that check by design, not by bug. Confirmed
# live via dmesg: the A8000 is an mt7921u device (the SAME chipset family
# as the Pager's own internal radio) - it enumerated on the USB bus fine,
# just never as a network interface detect_usb_a_iface() would recognize.
#
# Fixed by adding a SECOND, lower-level detector alongside the existing
# one: real USB bus attach/disconnect events straight from dmesg, which
# catches ANY peripheral (WiFi adapter, Ethernet adapter, storage,
# anything) regardless of whether it ever gets a driver/interface at all.
# The one thing that needs excluding: the Pager's OWN internal WiFi radio
# is *also* a USB device internally (confirmed live: also an mt7921u,
# identified via `product` = "Wireless_Device" at a FIXED bus path) - if
# its driver ever reinitializes, that would look identical to an external
# device being plugged in without this exclusion. get_internal_radio_usb_path
# below finds that path dynamically at startup (not hardcoded - the exact
# path can differ between individual units/firmware), so it can be told
# apart from a genuinely external USB-A device every time.
#
# Detects three distinct things now:
#   - USB-C (eth0) is a fixed platform device that always exists - only
#     its CARRIER (cable plugged in / link up) can change.
#   - USB-A Ethernet adapters: interface-level detail (which ethN to use)
#     via detect_usb_a_iface(), same as before - still useful when it IS
#     an Ethernet adapter, since it tells you the interface name.
#   - USB-A ANY device: real USB bus attach/disconnect events via dmesg,
#     catching non-Ethernet peripherals too (like the A8000).
# Reuses iface_has_carrier/detect_usb_a_iface from lib/common.sh for the
# Ethernet-specific case - no new mechanism there, same helpers pc_link.sh
# /sniff.sh already trust.
#
# Usage:
#   usb_monitor.sh --watch          foreground, prints on every change, Ctrl+C to stop
#   usb_monitor.sh --background        same, detached - use --stop to end it
#   usb_monitor.sh --status               is it running?
#   usb_monitor.sh --stop                    stop a background run
#
# Options:
#   --watch          Run in the foreground.
#   --background        Run detached; use --stop to end it.
#   --status               Is a background watcher currently running?
#   --stop                    Stop a background watcher.
#   -h, --help                  This help.

set -u
TOOL_NAME="usb_monitor.sh"
PIDFILE="/tmp/pager-usbmon.pid"
LOGFILE="/tmp/pager-usbmon.log"
# USB_A_STATEFILE - JUDGMENT CALL (integration question, see run_monitor's
# publish site below for the full reasoning): this script already re-derives
# USB-A's interface-presence state every 2s as a side effect of its own
# carrier polling - a plain "attached"/"detached" text file, written only on
# a real transition, costs almost nothing extra and gives ANY other script a
# cheaper/faster way to notice a USB-A interface disappearing than running
# its own `ip link show`/dmesg check. sniff.sh's own bridge watchdog (fixed
# earlier tonight, in sniff.sh, not here) already polls `ip link show` on
# its bridge members every 5s (plus up to 2 more retry-seconds before it
# acts) - this script's 2s loop can, at best, notice the same physical
# detach ~3-5s sooner. That's a real but modest win, not a correctness fix:
# sniff.sh's own poll is already a complete, self-contained safety net on
# its own. This file is published unconditionally, whether or not anything
# is currently reading it - usb_monitor.sh does not know or care who (if
# anyone) consumes it, and never touches bridges/captures itself. A
# consumer should treat it as an early advisory hint to check sooner, NOT
# as an authoritative replacement for its own check - it goes stale the
# moment usb_monitor.sh isn't running, with nothing here to signal that.
USB_A_STATEFILE="/tmp/pager-usb-a-state"
# How long an attach/detach ALERT stays on screen before notify() auto-
# dismisses it via lib/dismiss_alert.py - see notify()'s own comment for
# the full story. User-requested value from live testing.
ALERT_AUTODISMISS_SECS=2
# BUG FOUND AND FIXED (live-reported follow-up, round 5 - different shape
# of fix): live evidence this round proved ALERT's own client-side
# success (rc=0) does NOT mean the alert has actually rendered on screen
# yet - a detach's ALERT call and its dismiss both reported success, with
# the dismiss completing within the debug log's own timestamps, and the
# user still saw nothing until the matching reattach happened seconds
# later, at which point both messages appeared together. The platform
# queues/delays the actual on-screen render on its own schedule that this
# script has no way to observe or wait for - no amount of tuning the
# dismiss delay/timeout/retry count can fix a timing problem when there's
# no signal for "is it actually showing yet." Different fix: stop trying
# to win a race the platform doesn't expose enough information to win.
# REVERTED (explicit user request, after live-confirming it worked
# exactly as designed): a DEBOUNCE_SECS window used to hold back a fresh
# detach and combine it with a quick reattach into one message, instead
# of firing two separate alerts. The user wants an instant message on
# every single transition, no combining, even at the cost of two alerts
# landing close together again - so this was removed. Extensive live
# testing that night (isolated ALERT calls via SSH, nested-subshell
# replicas, an exact --background-launch-pattern replica, all with
# various delays) never reproduced the platform-side render delay
# outside of the real daemon's own detected events - the leading
# remaining theory is that the on-device UI app is genuinely busier
# specifically WHILE the real interface carrier-down transition is in
# flight (kernel/br-lan reconfiguration observed in dmesg at that exact
# moment), not a queuing/ordering problem this script's own call
# sequencing can control. Not yet proven either way - flagged honestly
# as unresolved rather than claimed fixed.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_WATCH=0; BACKGROUND=0; DO_STOP=0; DO_STATUS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --watch) DO_WATCH=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BUG FOUND AND FIXED (fresh bug-hunt pass, dead-code/consistency check):
# DO_WATCH was set by --watch but never actually READ anywhere else in this
# file - --status/--stop/--background each gate their own block on their
# own DO_* flag, but nothing gated on DO_WATCH; the script just fell
# through to the unconditional `run_monitor` call at the very end
# regardless of whether --watch, no flags at all, or (if it somehow fell
# through, e.g. a future edit reordering these blocks) some other
# unhandled combination got there. In practice every real caller
# (setup.py, reset.sh) always passes an explicit --background/--status/
# --stop, so this never actually misbehaved live - but it meant a bare
# `usb_monitor.sh` with NO arguments silently started an undocumented
# foreground daemon (never mentioned in the Usage/Options block above)
# instead of printing usage like every other unrecognized invocation does,
# and --watch itself was pure documentation with no code actually checking
# it. Fixed by requiring at least one of the four documented actions
# up front - makes DO_WATCH a real, checked flag and turns the previously-
# silent no-args case into the same usage() every other invalid
# invocation already gets.
if [ "$DO_WATCH" != "1" ] && [ "$BACKGROUND" != "1" ] && [ "$DO_STOP" != "1" ] && [ "$DO_STATUS" != "1" ]; then
    usage
fi

# BIG CHANGE (adopting common.sh's shared primitive): backed by the one
# canonical pid_running() in lib/common.sh instead of yet another copy.
# pid_running's optional NAME_PATTERN (see lib/common.sh) guards against a
# stale PIDFILE whose PID got reused by an unrelated process - the
# backgrounded run_monitor loop is a subshell of THIS script, so its real
# /proc/PID/cmdline still shows "usb_monitor.sh".
is_running() { pid_running "$PIDFILE" "usb_monitor.sh"; }

# LOCKDIR/acquire_lock/release_lock - BUG FOUND AND FIXED (CRITICAL - a real
# TOCTOU race, verified with a standalone repro before touching this file:
# 8 racers hitting the old bare "if is_running; then die; fi ... echo $! >
# PIDFILE" pattern concurrently produced 2 distinct processes that both
# believed they'd started successfully - the loser's PID-file write clobbers
# the winner's, leaving the winner's run_monitor loop alive but permanently
# UNTRACKED (no future --stop can ever find it again, and it keeps
# notifying/appending to $LOGFILE - doubled - until the device reboots).
# This isn't hypothetical for this exact script: setup.py restarts
# usb_monitor.sh whenever its content changed since the last deploy (see
# setup.py's usb_monitor_changed check - exactly what an active dev/bug-hunt
# session does repeatedly), and reset.sh's ensure_usb_monitor() independently
# restarts it whenever --status doesn't report Running for any reason - two
# entirely separate processes (a deploy from a dev machine over SSH, and
# reset.sh run directly on the device) that can genuinely both decide "it's
# not running, start it" in the same instant, e.g. right after a crash.
# Fixed with a plain mkdir-based lock (mkdir is atomic per POSIX, and unlike
# `flock` it needs nothing extra installed - flock isn't guaranteed present
# on this device's busybox build) serializing --background/--stop/--status
# against each other. Re-verified with the same repro: 8 racers against the
# locked version produced exactly 1 winner, every run.
#
# This one lock also closes two smaller variants of the same class found
# during this pass rather than needing a separate patch each: --stop used to
# re-read $PIDFILE a second time (once inside is_running's own check, again
# for the `kill` itself) - a --background racing in between those two reads
# could make --stop act on a DIFFERENT process than the one is_running just
# validated; --status had the same second read purely for its printed
# message, so it could show a stale/wrong PID during the same window.
# Serializing all three on one lock removes all three at once.
#
# Stale-lock recovery: the lock is only ever held for the few fast, local,
# non-blocking operations inside these three blocks - never across
# run_monitor's own long-running loop - so the only way it outlives its
# holder is that holder getting SIGKILLed in that narrow window. A waiter
# that finds the lock held checks whether the PID that created it
# ($LOCKDIR/pid) is still alive - same "does the recorded PID still actually
# belong to something" check as pid_running() above - and clears the lock
# itself if not, so a rare dead holder can't wedge every future
# --background/--stop/--status behind a lock nobody will ever release.
# Verified with a second standalone repro, including a bug this repro caught
# in an earlier draft: `rmdir` fails on a non-empty directory, so the pid
# marker file MUST be removed before the rmdir, not after - an earlier
# version of this fix removed only the directory and looped forever
# re-detecting the same "dead holder" without ever clearing it. Also
# confirmed a genuinely live holder is never mistaken for stale, and a
# waiter that can't get the lock within the timeout fails cleanly (a clear
# die() message naming $LOCKDIR) instead of hanging indefinitely.
# BUG FOUND AND FIXED (bug-hunt pass, CRITICAL - verified with a standalone
# repro before touching this file): the stale-holder check only fires when
# $LOCKDIR/pid has CONTENT naming a dead PID. There's a real TOCTOU gap
# between `mkdir "$LOCKDIR"` succeeding and the `echo $$ > "$LOCKDIR/pid"`
# a few lines below it actually landing - if the holder is killed (SIGKILL,
# OOM, a crash) in exactly that window, $LOCKDIR exists forever with NO pid
# file ever written. Every future waiter then computes `holder=""`, so
# `[ -n "$holder" ]` is false and the cleanup branch never runs - the lock
# is permanently unrecoverable, not just temporarily stuck. Repro (see
# lock_repro.sh style test): created $LOCKDIR with no pid file (simulating
# a holder killed in the gap), then ran acquire_lock() against it - it hit
# the 30-try timeout and gave up with the lock dir STILL orphaned and no
# pid file, confirmed by checking `[ -d "$LOCKDIR" ] && [ ! -f
# "$LOCKDIR/pid" ]` afterward: true. For acquire_lock this means every
# subsequent --background/--stop/--status dies with "Timed out..." forever;
# for acquire_alert_lock (below) it means every future notify() alert
# silently gives up forever - until something manually rmdir's the lock or
# the device reboots. Fixed by adding a second staleness signal alongside
# the existing dead-PID one: if the lock dir has no pid file yet AND is
# already older than a couple seconds (the real gap between mkdir and the
# pid write is a single fast local write, near-instant - never legitimately
# multiple seconds), treat it as orphaned too. `date -r DIR +%s` for the
# dir's mtime is the same portable-mtime idiom sniff.sh's own USB_A hint
# staleness check already uses in this codebase.
#
# BUG FOUND AND FIXED (bug-hunt pass, same root cause pid_running() in
# lib/common.sh was already hardened against): a bare `kill -0 "$holder"`
# only proves SOME process currently has that PID, not that it's still the
# SAME process that wrote the lock. If a holder dies without releasing
# (SIGKILL mid-cycle) and its PID gets reused by an unrelated process
# before a waiter's kill -0 check runs, the lock would be wrongly treated
# as still legitimately held forever - exactly the scenario pid_running()'s
# own header comment documents and guards against via a NAME_PATTERN check
# against /proc/PID/cmdline. These two lock functions had the bare, older
# version of that same check. Fixed the same way: when the holder PID is
# alive, also confirm /proc/$holder/cmdline still mentions usb_monitor.sh
# before trusting it - a live-but-unrelated process reusing the old PID no
# longer passes, and gets cleaned up as stale instead. Fails open (skips
# the extra check, keeps old kill-0-only behavior) if /proc/PID/cmdline
# isn't readable, same as pid_running() does.
LOCKDIR="/tmp/pager-usbmon.lock"
_lock_holder_stale() {
    # $1 = lock dir, $2 = holder pid (may be empty)
    local dir="$1" holder="$2" mtime now
    if [ -z "$holder" ]; then
        mtime=$(date -r "$dir" +%s 2>/dev/null)
        case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
        now=$(date +%s)
        [ "$now" -ge "$mtime" ] && [ $((now - mtime)) -ge 2 ] && return 0
        return 1
    fi
    if ! kill -0 "$holder" 2>/dev/null; then
        return 0
    fi
    if [ -r "/proc/$holder/cmdline" ] && ! tr '\0' ' ' < "/proc/$holder/cmdline" 2>/dev/null | grep -qF "usb_monitor.sh"; then
        return 0
    fi
    return 1
}
acquire_lock() {
    local tries=0 holder
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -ge 30 ] && die "Timed out waiting for another usb_monitor.sh --background/--stop/--status to finish (lock: $LOCKDIR)."
        holder=$(cat "$LOCKDIR/pid" 2>/dev/null)
        if _lock_holder_stale "$LOCKDIR" "$holder"; then
            rm -f "$LOCKDIR/pid" 2>/dev/null
            rmdir "$LOCKDIR" 2>/dev/null
            continue
        fi
        sleep 0.1
    done
    echo $$ > "$LOCKDIR/pid" 2>/dev/null
}
release_lock() { rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null; }

# A second, independent lock (same mkdir-atomic, stale-holder-self-healing
# shape as the one just above) serializing notify()'s alert cycles - see
# notify()'s own comment for why. Deliberately NOT the same $LOCKDIR: that
# one guards --background/--stop/--status against each other, a completely
# different critical section - sharing it would make an attach/detach
# alert wait behind an unrelated --status call, and vice versa, for no
# reason. Non-fatal timeout (unlike acquire_lock's die()): this runs from
# inside a background notify() subshell, not a one-shot CLI invocation -
# giving up on showing ONE alert if the lock is somehow stuck is fine,
# killing the whole daemon over it is not.
ALERT_LOCKDIR="/tmp/pager-usbmon-alert.lock"
# BUG FOUND AND FIXED (bug-hunt pass, CRITICAL) - see the matching fix on
# acquire_lock() above for the full trace/repro: the same mkdir-then-
# pid-write TOCTOU gap and the same bare-kill-0 PID-reuse blind spot exist
# here too, and share the same _lock_holder_stale() fix. Consequence here
# is quieter than acquire_lock's (no die(), just a non-fatal `return 1`),
# but worse in effect: once $ALERT_LOCKDIR wedges this way, EVERY future
# attach/detach ALERT silently gives up forever with no error surfaced
# anywhere an operator would see it - exactly the kind of silent-regression
# this file's own long history of "still don't see a message" reports has
# already been burned by more than once.
acquire_alert_lock() {
    local tries=0 holder
    while ! mkdir "$ALERT_LOCKDIR" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -ge 30 ] && return 1
        holder=$(cat "$ALERT_LOCKDIR/pid" 2>/dev/null)
        if _lock_holder_stale "$ALERT_LOCKDIR" "$holder"; then
            rm -f "$ALERT_LOCKDIR/pid" 2>/dev/null
            rmdir "$ALERT_LOCKDIR" 2>/dev/null
            continue
        fi
        sleep 0.1
    done
    # Uses $BASHPID, not $$: this is always called from inside a
    # `( ... ) &` subshell (notify()'s alert-cycle block) - bash's $$
    # does NOT update inside a plain subshell, it still reports the
    # PARENT script's PID (verified live: `bash -c '( echo $$ $BASHPID
    # ) &'` prints two different numbers). Recording $$ here would make
    # every alert cycle's lock claim to be held by the long-lived main
    # daemon process, which is always alive - permanently defeating the
    # stale-holder self-healing above, since a genuinely-dead subshell
    # would never be detected as dead.
    echo "$BASHPID" > "$ALERT_LOCKDIR/pid" 2>/dev/null
    return 0
}
release_alert_lock() { rm -f "$ALERT_LOCKDIR/pid" 2>/dev/null; rmdir "$ALERT_LOCKDIR" 2>/dev/null; }

if [ "$DO_STATUS" = "1" ]; then
    acquire_lock
    trap release_lock EXIT
    if is_running; then
        say "Running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
    fi
    exit 0
fi

# BUG FOUND AND FIXED (fresh bug-hunt pass, CRITICAL - traced against a real
# caller, not a hypothetical): this used to send the kill signal and
# IMMEDIATELY declare "Stopped." / remove $PIDFILE / release the lock -
# with nothing checking that the old process had actually exited yet.
# SIGTERM only gets acted on between iterations of run_monitor's own loop
# (see notify()'s and this file's own comments on how long a single
# iteration's synchronous work - say()+LOG's timeout, describe_usb_device's
# retries, multiple notify() calls stacking - can take), so the real process
# can still be alive and mid-iteration for several seconds after --stop
# returns. That window matters because it isn't hypothetical: setup.py's
# own redeploy flow (see BACKGROUND block's header comment below) does
# EXACTLY "--stop" immediately followed by "--background" with nothing
# waiting in between whenever this script's own content changed - precisely
# the kind of back-to-back invocation an active bug-hunt/redeploy session
# does all night. If the old process is still alive when the new
# --background launches, the new PIDFILE write clobbers the old one -
# recreating the exact "permanently UNTRACKED duplicate daemon, doubled
# notifications/log lines until reboot" failure mode this file's own
# LOCKDIR comment already documents as CRITICAL, just reached via --stop's
# own false confirmation instead of a --background/--background race.
# Fixed by actually waiting (bounded, ~5s via kill -0 polling - the same
# primitive pid_running()/the lock's stale-holder check already use) for
# the PID to disappear before believing the stop worked, escalating to
# SIGKILL as a last resort if it still hasn't exited - so "Stopped." (and
# the PIDFILE removal/lock release that follow it) is only ever said once
# the old process is actually, verifiably gone, not just asked to be.
if [ "$DO_STOP" = "1" ]; then
    acquire_lock
    trap release_lock EXIT
    if is_running; then
        _stop_pid="$(cat "$PIDFILE")"
        kill "$_stop_pid" 2>/dev/null
        _stop_tries=0
        while kill -0 "$_stop_pid" 2>/dev/null && [ "$_stop_tries" -lt 20 ]; do
            _stop_tries=$((_stop_tries + 1))
            sleep 0.25
        done
        if kill -0 "$_stop_pid" 2>/dev/null; then
            err "PID $_stop_pid didn't exit within 5s of SIGTERM - sending SIGKILL."
            kill -9 "$_stop_pid" 2>/dev/null
            sleep 0.25
        fi
        rm -f "$PIDFILE"
        say "Stopped."
    else
        say "Nothing running."
    fi
    exit 0
fi

STOPPING=0
_on_stop() { STOPPING=1; }
trap _on_stop INT TERM

# notify MESSAGE - BUG FOUND AND FIXED THREE TIMES now (reported live
# each round). First: this only ever called say() (a plain `echo` into
# this script's own hidden log file) - never anything the device's
# actual on-screen UI would show. LOG turned out to be a REAL,
# independently callable binary (confirmed live via plain SSH, same as
# PINEAPPLE_DEAUTH_CLIENT and friends - a hak5cmd symlink, not payload-
# runner-only), so that got wired in - but LOG only appends to the on-
# device log VIEW, not an actual pop-up, which still didn't match what
# was asked for ("a display box like on GUI on device"). ALERT LOOKED
# like the right fix for that (confirmed live it's ALSO independently
# callable and genuinely produces a full-screen alert - Hak5's own docs:
# "displays a full-screen alert message and plays the alert ringtone").
#
# THIRD BUG (reported live - "the messages still don't go away after a
# while"): confirmed against Hak5's own ALERT docs - its syntax is JUST
# `ALERT [message]`, no duration/timeout/dismiss parameter of any kind.
# There is also no separate lightweight "toast" primitive documented
# anywhere in Hak5's API - ALERT is the only on-screen popup command that
# exists, and its own docs frame it for events that "require the user's
# attention" (one-off, deliberate things like a finished scan), not a
# background watcher that can fire repeatedly for ordinary USB plug/
# unplug activity. Using ALERT here meant every attach/detach queued a
# full-screen, ringtone-playing interruption with no way to make it auto-
# clear - exactly the "message doesn't go away" symptom, and it's a
# genuine API limitation, not something this script can configure around.
# Fix: drop ALERT here entirely. LOG already gives a real, persistent,
# non-blocking on-screen record of every event (visible in the Pager's
# own log view) without ever needing to be dismissed - the right tool for
# a frequent ambient notification. ALERT is still the right choice
# elsewhere in this toolkit for genuinely one-off, attention-worthy
# events (an attack finishing, a scan completing) - just not for this.
#
# BUG FOUND AND FIXED (bug-hunt pass, long-running-daemon robustness):
# the LOG call had no timeout, unlike every other external/IPC-touching
# call this toolkit makes (ip_link()/is_wifi_connected()/connected_bssid()
# in lib/common.sh, tcpdump in sniff.sh - all wrapped in `timeout` because
# this device has a documented, live-reproduced history of exactly this
# class of call wedging). LOG is a hak5cmd binary that talks to the
# device's own UI/log-view service - the same kind of userspace IPC call
# that's already proven capable of wedging elsewhere on this hardware.
# Verified live with a standalone repro (a foreground external command
# simulating a hang, SIGTERM sent to the parent 1s in): bash defers
# running any trap until the CURRENT foreground command completes - so if
# LOG ever hung, notify() would block run_monitor's whole loop
# indefinitely, and --stop's `kill "$PID"` would sit there having no
# effect at all (STOPPING never gets set, the loop never gets back to
# checking it) until something else killed the wedged LOG call - for a
# script meant to run unattended for days/weeks, an unkillable-except-via-
# kill/-9 daemon with --stop silently lying that it worked is a real
# problem. Bounding it with the same `timeout` pattern this codebase
# already trusts turns "however long LOG happens to hang for" into a
# small, bounded worst-case delay before --stop's signal actually takes
# effect, same as everywhere else this class of risk is already guarded.
notify() {
    say "$1"
    # BUG FOUND AND FIXED (integration re-audit): the on-screen LOG call had
    # no subsystem tag, unlike say()'s own console output just above (which
    # already prefixes every line with "[$TOOL_NAME]" via lib/common.sh).
    # lan_sniffer/payload.sh's own on-screen narration got the matching
    # "[LAN Sniffer] " tag this same session specifically so an operator
    # watching the screen during a bridge session (where both scripts can
    # legitimately report on the same physical USB-A event) can tell which
    # independent script a line came from. This was the untagged half of
    # that fix.
    #
    # BUG FOUND AND FIXED (bug-hunt pass, run_monitor detection-latency:
    # verified with a standalone repro): notify() is called SYNCHRONOUSLY
    # from inside run_monitor's own detection loop (for USB-C/USB-A state
    # changes) before that same loop iteration goes on to do its dmesg-diff
    # work and the next-iteration sleep. This `timeout 5 LOG ...` call ran
    # in the foreground right here - bounded by `timeout`, but "bounded"
    # still means up to 5 REAL seconds of the loop doing nothing else if LOG
    # is ever slow/wedged (the same class of on-device IPC hang this file's
    # own comment two paragraphs up already documents LOG as capable of).
    # Repro: a fake LOG() that never returns on its own, called the exact
    # same way (`timeout N LOG ...`) - the calling script was measurably
    # blocked for the full timeout duration (2s in the repro, 5s for real)
    # before the next statement ran. Since a single loop iteration can call
    # notify() more than once (e.g. USB-C AND USB-A both changed in the same
    # 2s tick), those delays stack, directly postponing this SAME script's
    # own dmesg-diff check and its own next carrier poll - a real, code-
    # level source of detection latency independent of the platform's own
    # ALERT-queue behavior. Fixed by backgrounding this call too (same
    # `( ... ) & disown` shape already used for the ALERT cycle below) so a
    # slow/wedged LOG can no longer delay this process's own detection loop
    # - it was already non-essential to serialize (each LOG call writes an
    # independent, self-contained line to the on-device log view; unlike
    # ALERT there's no shared on-screen state to protect between calls, so
    # no lock is needed here, just non-blocking dispatch).
    if command -v LOG >/dev/null 2>&1; then
        ( timeout 5 LOG "[usb_monitor.sh] $1" >/dev/null 2>&1 ) &
        disown 2>/dev/null
    fi

    # BUG FOUND AND FIXED (CRITICAL, live-reported - "unplugged/replugged
    # both ports, no message shown on screen"): LOG never had a real
    # destination for a standalone background daemon. Per Hak5's own docs,
    # LOG's output "appears in the payload console when a DuckyScript
    # payload is executing" - this script is deliberately NOT a payload
    # (see the file header), so it never has an active payload console to
    # write into. Confirmed live: a bare `LOG "..."` over SSH with no
    # payload running produced no visible effect on the physical device at
    # all. This means every notify() call this whole file has ever made
    # was silently going nowhere in this script's actual, permanent
    # runtime context - not a regression from tonight, a gap present since
    # this script was first written.
    #
    # First attempt at a fix used VIBRATE instead (also confirmed live to
    # work standalone, unlike LOG) - correctly rejected: the ask was
    # specifically an on-screen MESSAGE, not a physical buzz. Re-tested
    # ALERT the same way LOG and VIBRATE were tested (bare SSH, zero
    # payload running) and confirmed live it DOES render as real on-screen
    # text in that exact context, unlike LOG. The difference: per Hak5's
    # own docs LOG is scoped to a payload's own console view, while ALERT
    # is a system-level interrupt that can take over the screen from
    # anywhere (the same mechanism their own "alert payloads" category
    # uses, itself triggered by a background service with no foreground
    # payload running either) - so it was never actually true that NO
    # on-screen text works standalone, only that LOG specifically doesn't.
    #
    # BUG FOUND AND FIXED (live-reported follow-up, round 2): the first
    # version of this fix fired ALERT synchronously and relied on ALERT's
    # own confirmed-nonexistent duration parameter - fixed by backgrounding
    # the whole "show, wait, dismiss" sequence and building a real dismiss
    # (lib/dismiss_alert.py). That fix alone still wasn't enough for two
    # events close together (e.g. a quick unplug/replug) - live-reproduced
    # with two ALERT calls fired 1.2s apart with nothing else running: the
    # SECOND one rendered FIRST, then the first rendered after, and neither
    # auto-dismissed - the platform's own alert queue does not preserve
    # firing order, and two independently-timed "wait N seconds after MY
    # OWN alert, then send one dismiss" subshells have no way to know which
    # physical alert is actually on screen when the platform itself
    # reorders them. A per-call timer literally cannot fix this - the fix
    # has to stop TWO alert cycles from ever being in flight at once.
    #
    # Fixed by serializing every alert cycle behind ALERT_LOCKDIR (same
    # mkdir-is-atomic, stale-holder-self-healing lock shape already proven
    # for this file's own --background/--stop/--status lock above, just a
    # second, independent lock for a different critical section - reusing
    # the SAME lock would make an attach event wait behind an unrelated
    # --status call and vice versa). A second event fired while the first
    # is still mid-cycle now genuinely waits for the first's full show-then-
    # dismiss to finish before showing its own - guaranteeing at most one
    # alert on screen at a time, in the order notify() was actually called,
    # with every single one actually getting dismissed.
    case "$1" in
        *"attached"*|*"detached"*)
            if command -v ALERT >/dev/null 2>&1; then
                (
                    acquire_alert_lock || exit 0
                    trap release_alert_lock EXIT
                    # REVERTED (live-reported regression): a theory that the
                    # physical screen might be asleep led to adding an
                    # ENABLE_DISPLAY call here - live testing showed this
                    # instead triggered a full "Initializing system" splash/
                    # re-init sequence, a real new problem, not a fix. Pulled
                    # back out. The out-of-order/delayed display issue is
                    # still open - see the next fix attempt below/in later
                    # commits for what actually addressed it, or if none yet,
                    # treat this as the last known-good state to build from.
                    #
                    # BUG FOUND AND FIXED (live-reported follow-up, round 3 -
                    # ROOT CAUSE FOUND, not another guess this time): even
                    # with this lock guaranteeing only one ALERT cycle runs
                    # at a time, a detach fired well before a replug still
                    # showed nothing until the replug's own attach event
                    # fired, then both appeared together, reversed. The
                    # diagnostic timestamps this round added (kept below,
                    # they're cheap and still useful) caught the real cause
                    # directly from a live log, not a new theory: a single
                    # detach event's FULL lock-held cycle (fire, wait
                    # ALERT_AUTODISMISS_SECS, send 3 dismiss attempts 0.4s
                    # apart) took a measured 20 SECONDS start to finish -
                    # `lock-acquired` at :48, `lock-releasing` at :08 the
                    # next minute. Timed the actual cost directly on-device:
                    # a single LD_LIBRARY_PATH=/mmc/usr/lib
                    # /mmc/usr/bin/python3.11 invocation of dismiss_alert.py
                    # took 1.78s in isolation (measured with `time`), almost
                    # certainly worse under the real contention of a genuine
                    # topology-change event (br-lan reconfiguring, this
                    # script's own poll loop also running) - three of those
                    # per event, added specifically to defend against the
                    # platform maybe queuing/reordering alerts, multiplied
                    # that into the ~20s that made the lock block a second
                    # real event for far longer than any reasonable gap
                    # between two physical actions. The "platform reorders
                    # alerts" theory wasn't wrong on its own (confirmed
                    # separately, firing two raw ALERT calls 1.2s apart with
                    # no lock at all also reordered) - but the fix for it
                    # (three dismiss attempts) cost far more than the
                    # problem it was guarding against, and that cost is what
                    # actually produced this exact symptom. No unix-socket-
                    # capable nc/socat exists on this device (checked) to
                    # avoid the python3 startup cost entirely, so cut the
                    # burst back to a single dismiss attempt instead -
                    # matches the original single-dismiss design that was
                    # confirmed working live before this file ever added the
                    # burst, at roughly 1/3 the lock-held time.
                    # BUG FOUND AND FIXED (live-reported follow-up, round 4 -
                    # CONFIRMED with real evidence this time, from the debug
                    # log this round added exit-code capture for): a detach
                    # event's dismiss call logged `dismiss-sent rc=124` -
                    # `timeout 5` genuinely KILLED it before it finished, so
                    # the Enter keypress was never actually sent and that
                    # alert stayed on screen undismissed. The SAME event's
                    # attach half, firing seconds later once the interface
                    # had settled, dismissed cleanly in ~2s. The asymmetry
                    # makes sense: a detach fires WHILE the interface is
                    # actively going down (br-lan port-state transitions,
                    # kernel reconfig in flight per this file's own earlier
                    # dmesg evidence) - the local UI app this talks to over
                    # /tmp/api.sock is plausibly busy/slow to respond at
                    # that exact moment, in a way it isn't a few seconds
                    # later once things have settled. 5s wasn't enough
                    # margin for that. Widened to 15s, and - since a timed-
                    # out dismiss means the alert is STILL sitting there
                    # needing to be cleared, not just "try again later" -
                    # added up to 2 retries on failure instead of accepting
                    # one failed attempt as final.
                    _dbg="/tmp/pager-usbmon-alert-debug.log"
                    echo "$(date '+%H:%M:%S.%N') lock-acquired msg=[$1]" >>"$_dbg" 2>/dev/null
                    timeout 10 ALERT "[usb_monitor.sh] $1" >/dev/null 2>&1
                    _alert_rc=$?
                    echo "$(date '+%H:%M:%S.%N') alert-call-returned rc=$_alert_rc" >>"$_dbg" 2>/dev/null
                    sleep "$ALERT_AUTODISMISS_SECS"
                    _py=$(resolve_python3 2>/dev/null)
                    if [ -n "$_py" ]; then
                        _dismiss_rc=1
                        for _try in 1 2 3; do
                            echo "$(date '+%H:%M:%S.%N') dismiss-starting attempt=$_try" >>"$_dbg" 2>/dev/null
                            timeout 15 $_py "$SCRIPT_DIR/lib/dismiss_alert.py" Enter >/dev/null 2>&1
                            _dismiss_rc=$?
                            echo "$(date '+%H:%M:%S.%N') dismiss-sent attempt=$_try rc=$_dismiss_rc" >>"$_dbg" 2>/dev/null
                            [ "$_dismiss_rc" -eq 0 ] && break
                        done
                    else
                        echo "$(date '+%H:%M:%S.%N') dismiss-skipped-no-python3" >>"$_dbg" 2>/dev/null
                    fi
                    echo "$(date '+%H:%M:%S.%N') lock-releasing" >>"$_dbg" 2>/dev/null
                ) &
                disown 2>/dev/null
            fi
            ;;
    esac
}

# get_internal_radio_usb_path - THE ACTUAL ROOT CAUSE of "USB-A never
# shows anything", found live: this used to match on the internal
# radio's `product` sysfs string ("Wireless_Device") to identify and
# exclude it - but that string is generic to the WHOLE mt7921u chipset
# family, not unique to the internal radio. Confirmed live: with the
# Netgear A8000 (also mt7921u-based) plugged into USB-A, BOTH devices
# report "Wireless_Device" - the search loop returned on the FIRST
# match in glob order, which was the EXTERNAL device (1-1.1 sorts before
# 1-1.2) - meaning the external adapter was being misidentified AS the
# internal radio and silently excluded from every detection, every time.
#
# Fixed properly: resolve the REAL USB device backing wlan1mon (the
# Pager's own internal monitor interface, confirmed this session to be
# the internal radio) directly via its /sys/class/net/*/device symlink -
# unambiguous, no string-matching collision possible, confirmed live:
# `readlink -f /sys/class/net/wlan1mon/device` resolves through
# ".../1-1/1-1.2/1-1.2:1.3" - the bus-path component is the "N-N.N"
# segment right before the ":" interface suffix.
get_internal_radio_usb_path() {
    local real
    real=$(readlink -f /sys/class/net/wlan1mon/device 2>/dev/null)
    [ -z "$real" ] && return
    echo "$real" | grep -oE '[0-9]+-[0-9.]+(:[0-9.]+)?$' | head -1 | sed -E 's/:[0-9.]+$//'
}

# usb_vendor_name ID - a SMALL, honestly-scoped table of USB-IF registered
# vendor IDs (the real, standardized 4-hex-digit identifiers every USB
# device reports - these are public, documented assignments, not guessed)
# for the handful of brands common enough to be worth naming directly.
# Anything not in this short list just shows its raw idVendor:idProduct
# instead of a guessed name - deliberately not trying to be a full USB ID
# database (that would need real data this project doesn't have/maintain).
usb_vendor_name() {
    case "$1" in
        0846) echo "NETGEAR" ;;
        0bda) echo "Realtek" ;;
        2357) echo "TP-Link" ;;
        13b1) echo "Linksys" ;;
        0b95) echo "ASIX" ;;
        0424) echo "Microchip/SMSC" ;;
        05ac) echo "Apple" ;;
        046d) echo "Logitech" ;;
        *) echo "" ;;
    esac
}

# describe_usb_device PATH - BUG FOUND AND FIXED (reported live - "show
# in () the device type and the device name"): the earlier attempt read
# `product` once, immediately after the attach line appeared - too early;
# a real test showed it can still be empty at that exact instant (sysfs
# populates as enumeration completes, not all at once). Retries briefly
# (up to 5 tries, 0.3s apart - enumeration is fast, this is not a long
# wait) instead of a single try. Also: `product`/`manufacturer` turned
# out to be generic CHIPSET reference-design strings ("Wireless_Device" /
# "MediaTek Inc.", confirmed live on a real Netgear A8000) - the actual
# make is only identifiable via idVendor (0846 for this exact device,
# genuinely NETGEAR's real registered USB-IF vendor ID, confirmed - not
# guessed), so this reports BOTH: the resolved brand (or the raw
# vendor:product hex ID if not in the small table above) as the device
# name, and the chipset manufacturer/product string as the type in
# parens, e.g. "NETGEAR (0846:9060) (MediaTek Inc. Wireless_Device)".
# BUG FOUND AND FIXED (fresh bug-hunt pass, "device disappears mid-lookup"
# edge case - verified with a standalone repro before touching this file):
# each retry iteration reassigned vid/pid/mfr/prod straight from `cat`
# with NO guard against a read that comes back empty - so a device that
# disappears (or has a transient sysfs read glitch) partway through the
# retry window didn't just fail to make PROGRESS, it actively ERASED
# already-good data from an earlier iteration. Concretely: try 1 reads a
# perfectly valid idVendor (e.g. "0846") but `product` is still empty
# (sysfs hasn't finished populating yet, the exact case these retries
# exist for) - the loop correctly continues: `[ -n "$vid" ] && [ -n
# "$prod" ]` is false. But if the device is gone (or that one file glitches)
# on try 2, `vid=$(cat .../idVendor)` returns "" and OVERWRITES the good
# "0846" from try 1 with an empty string - by try 5 `vid` is empty even
# though it was successfully read moments earlier, so `[ -z "$vid" ] &&
# return 1` fires and this reports total failure (falling back to the
# generic "USB-A: device attached" message) despite having had enough
# data for a real one. Repro: simulated try 1 returning a valid
# vid/pid/mfr with the (real, common) "product still empty" case, then
# every subsequent try returning nothing (device vanished) - the
# unguarded version's `vid` ends up empty and returns 1, discarding the
# good try-1 read entirely. Fixed by only ever overwriting a field when
# the fresh read actually returned something, so a later empty/failed
# read can no longer blank out data a prior, successful read already
# captured - each field independently keeps the last non-empty value seen
# across the whole retry window.
describe_usb_device() {
    local path="$1" tries=0 vid="" pid="" mfr="" prod="" _v _p _m _pr
    while [ "$tries" -lt 5 ]; do
        _v=$(cat "/sys/bus/usb/devices/$path/idVendor" 2>/dev/null)
        _p=$(cat "/sys/bus/usb/devices/$path/idProduct" 2>/dev/null)
        _m=$(cat "/sys/bus/usb/devices/$path/manufacturer" 2>/dev/null)
        _pr=$(cat "/sys/bus/usb/devices/$path/product" 2>/dev/null)
        [ -n "$_v" ] && vid="$_v"
        [ -n "$_p" ] && pid="$_p"
        [ -n "$_m" ] && mfr="$_m"
        [ -n "$_pr" ] && prod="$_pr"
        [ -n "$vid" ] && [ -n "$prod" ] && break
        tries=$((tries + 1))
        sleep 0.3
    done
    [ -z "$vid" ] && return 1
    local name
    name=$(usb_vendor_name "$vid")
    [ -z "$name" ] && name="${vid}:${pid}"
    local type_str="${mfr:-unknown chip} ${prod:-device}"
    echo "$name ($type_str)"
    return 0
}

# process_usb_dmesg_lines - reads candidate USB attach/disconnect dmesg
# lines from stdin (already grep-filtered by the caller) and notifies for
# each one not belonging to the internal radio. Pulled out into its own
# function so the two callers inside run_monitor below (the normal
# incremental-tail path, and the ring-buffer-wrap full-rescan path) share
# one implementation instead of duplicating this block.
process_usb_dmesg_lines() {
    local _line _path _desc
    while IFS= read -r _line; do
        _path=$(echo "$_line" | grep -oE 'usb [0-9]+-[0-9.]+' | awk '{print $2}')
        [ -n "$internal_radio_path" ] && [ "$_path" = "$internal_radio_path" ] && continue
        if echo "$_line" | grep -qi "disconnect"; then
            notify "USB-A: device detached (bus $_path)"
        else
            _desc=$(describe_usb_device "$_path")
            if [ -n "$_desc" ]; then
                notify "USB-A: $_desc attached (bus $_path)"
            else
                notify "USB-A: device attached (bus $_path)"
            fi
        fi
    done
}

# run_monitor - polls every 2s (USB hotplug/link-up doesn't settle
# instantly anyway - no value in polling faster than that) and prints
# exactly one line per actual state CHANGE, never on the first read (that
# would just announce whatever's already plugged in at startup as if it
# just happened).
run_monitor() {
    say "Watching USB-C/USB-A for attach/detach - Ctrl+C to stop."
    local internal_radio_path
    internal_radio_path=$(get_internal_radio_usb_path)
    # IMPROVEMENT (defensive, startup-race): the above is normally resolved
    # once and trusted for this process's entire run (which can be days -
    # see run_monitor's own header). It depends on /sys/class/net/wlan1mon
    # already existing at the moment usb_monitor.sh starts - true in every
    # live test this session, but not guaranteed: --background can be
    # launched very early (e.g. by an init/startup path, or a fast setup.py/
    # reset.sh restart cycle) before the internal radio's own interface has
    # come up yet. describe_usb_device() above already treats sysfs
    # enumeration timing as something worth retrying for exactly this
    # reason (see its own comment) - this call site never got the same
    # treatment. If it fails to resolve here, internal_radio_path stays ""
    # for the rest of THIS run with nothing to ever revisit it, meaning
    # every subsequent internal-radio reinit for that whole run would be
    # misidentified as an external USB-A device (the original bug this
    # whole exclusion exists to prevent - see get_internal_radio_usb_path's
    # own header). Retrying a few times here (short, bounded, same shape as
    # describe_usb_device's own retry) covers a slow-to-appear wlan1mon at
    # startup cheaply; a periodic best-effort retry further down (only
    # while still unresolved, never re-guessing a path already found) covers
    # a wlan1mon that simply isn't there yet for longer than that.
    if [ -z "$internal_radio_path" ]; then
        local _radio_tries=0
        while [ "$_radio_tries" -lt 5 ] && [ -z "$internal_radio_path" ]; do
            sleep 0.5
            internal_radio_path=$(get_internal_radio_usb_path)
            _radio_tries=$((_radio_tries + 1))
        done
    fi
    # Baseline dmesg content - only lines APPENDED after this point count as
    # "new" (matches the same count-diff pattern already proven in sniff.sh's
    # live watchers). Deliberately never clears/consumes the kernel log
    # buffer (no `dmesg -c`) - something else on the device (klogd/syslog)
    # may also be reading it, and destructively clearing it could steal
    # messages meant for that.
    #
    # BUG FOUND AND FIXED (long-running-daemon pass, verified with a
    # standalone repro): tracking progress via a LINE-COUNT diff (`dmesg |
    # wc -l` growing over time, as this used to do) silently assumes the
    # count only ever grows, or drops on a wrap - but a kernel ring buffer
    # is a fixed-BYTE-size buffer, not a fixed-line-count one. Once it has
    # actually filled up (unlikely to matter in one short test session,
    # near-certain eventually on the days/weeks uptime this script is built
    # for), each new kernel message evicts roughly one old one from the
    # front to make room, so the TOTAL line count can plateau at a roughly
    # constant value for the rest of the device's uptime even while
    # genuinely new USB attach/disconnect lines keep landing at the end.
    # Repro: simulated a 5-line ring buffer already at capacity, evicting
    # the oldest and appending one new line per tick (half of them real
    # "usb ... new high-speed USB device" lines) - the old `total -gt seen`
    # / `total -lt seen` logic fired NEITHER branch on any tick (total
    # stayed at 5 throughout): 4 real attach events injected, 0 detected,
    # with --status still happily reporting "Running" the whole time and no
    # indication detection had gone silently blind. Fixed by tracking the
    # actual last-seen LINE (a content watermark) instead of a count:
    # locate it by exact text match in the new dump and treat everything
    # after it as "new" - this depends on whether the CONTENT changed, not
    # whether the total count happens to, so a plateaued-but-turning-over
    # buffer is detected correctly. If the watermark line itself has been
    # evicted (a genuine wrap, or no watermark resolved yet), that's the
    # same "can't find my place, re-scan the whole current buffer" fallback
    # the old `-lt` branch used - at worst re-notifying about an event from
    # just before the wrap once, same accepted tradeoff as before, just no
    # longer blind to the far more likely plateau case. Trade-off: keeping
    # $dmesg_prev around across iterations (instead of a plain integer)
    # costs one extra copy of the dmesg buffer's content in memory - bounded
    # by the same fixed kernel ring buffer size $dmesg_now was already
    # bounded by, so no new unbounded-growth risk, just a small constant
    # increase in this loop's own footprint.
    local dmesg_prev dmesg_last_line
    dmesg_prev=$(dmesg 2>/dev/null)
    dmesg_last_line=$(printf '%s\n' "$dmesg_prev" | tail -n 1)

    local prev_c="" prev_a_if="" prev_a_state="" prev_usb_a_pub="" _loop_iter=0
    while [ "$STOPPING" != "1" ]; do
        local c_state a_if a_state
        if iface_has_carrier eth0; then c_state="attached"; else c_state="detached"; fi
        a_if=$(detect_usb_a_iface)
        if [ -n "$a_if" ] && iface_has_carrier "$a_if"; then
            a_state="attached"
        elif [ -n "$a_if" ]; then
            # CONSISTENCY FIX: this used to be the raw internal token
            # "detected-link-down" (a compact string chosen only for the
            # `!=` state-change comparisons below), printed to the operator
            # verbatim via notify() - a literal, hyphenated state-machine
            # name, not a written sentence. sniff.sh's check_adapters() and
            # lan_sniffer/payload.sh's own "Check adapter status" case both
            # describe this exact same condition (adapter present, no
            # carrier) as "detected but link down" - matching that wording
            # here too, since $a_state is compared only by quoted string
            # equality (never pattern-matched), a value containing spaces
            # works identically for that purpose.
            a_state="detected but link down"
        else
            a_state="none"
        fi

        # IMPROVEMENT (defensive, same startup-race as the one-shot retry
        # above): if internal_radio_path never resolved at startup (e.g.
        # wlan1mon genuinely wasn't there yet, longer than the bounded
        # startup retry covered), keep giving it a cheap chance to resolve
        # every ~60 iterations (~2 minutes at this loop's 2s cadence)
        # instead of giving up on it silently for this process's entire
        # remaining run (which can be days). Deliberately one-directional:
        # only retried while still EMPTY - a path that already resolved
        # successfully is never re-checked or second-guessed here, so a
        # transient readlink hiccup later in a long run can't wrongly blank
        # out a previously-good exclusion.
        _loop_iter=$((_loop_iter + 1))
        if [ -z "$internal_radio_path" ] && [ $((_loop_iter % 60)) -eq 0 ]; then
            internal_radio_path=$(get_internal_radio_usb_path)
        fi

        # IMPROVEMENT (integration question - see USB_A_STATEFILE's own
        # comment near the top of this file for the full judgment call):
        # publish USB-A's interface-presence state (does detect_usb_a_iface
        # currently find an interface at all - the same fact a consumer
        # like sniff.sh's bridge watchdog cares about, since it also just
        # checks `ip link show <iface>` existence, not carrier/link state)
        # to a small file, but only on an actual transition - every other
        # iteration this is a single cheap string comparison, nothing
        # written. Atomic (write-to-temp then rename) so a concurrent
        # reader can never observe a half-written file. Uses this process's
        # own $$ for the temp name (unique per usb_monitor.sh instance,
        # same convention as this file's own LOGFILE trim and lib/common.sh's
        # topology_log()) - not a new race even if two instances somehow
        # ran at once (already guarded against elsewhere; not re-litigated
        # here). First iteration always counts as a "transition" (prev_usb_a_pub
        # starts empty) specifically so a fresh reader gets a real baseline
        # immediately instead of waiting for the first genuine plug/unplug.
        local usb_a_pub
        if [ -n "$a_if" ]; then usb_a_pub="attached"; else usb_a_pub="detached"; fi
        if [ "$usb_a_pub" != "$prev_usb_a_pub" ]; then
            printf '%s\n' "$usb_a_pub" >"${USB_A_STATEFILE}.tmp.$$" 2>/dev/null && mv -f "${USB_A_STATEFILE}.tmp.$$" "$USB_A_STATEFILE" 2>/dev/null
            rm -f "${USB_A_STATEFILE}.tmp.$$" 2>/dev/null
            prev_usb_a_pub="$usb_a_pub"
        fi

        # REVERTED (explicit user request): debounce combined a quick
        # unplug/replug into one delayed message instead of two instant
        # ones. Confirmed working exactly as designed (one combined
        # message, correctly silent during the brief gap) - but the user
        # wants an instant message on every single attach/detach, no
        # combining, even at the cost of two alerts landing close together
        # again. Back to firing immediately on every transition.
        if [ -n "$prev_c" ] && [ "$c_state" != "$prev_c" ]; then
            notify "USB-C: $c_state"
        fi
        if [ -n "$prev_a_state" ] && { [ "$a_state" != "$prev_a_state" ] || [ "$a_if" != "$prev_a_if" ]; }; then
            # BUG FOUND AND FIXED (bug-hunt pass): this used to hardcode
            # "attached" whenever the interface first appeared (prev was
            # "none"), even if its real state was "detected-link-down"
            # (interface enumerated, cable/carrier not actually up yet) -
            # a real Ethernet adapter plugged in without a cable attached
            # would have been wrongly reported as "attached". Just report
            # the real $a_state either way - no need for the special case.
            if [ -z "$a_if" ]; then
                notify "USB-A ($prev_a_if): detached"
            else
                notify "USB-A ($a_if): $a_state"
            fi
        fi

        # Generic USB-A bus-level attach/detach - catches ANY device
        # (WiFi adapters, storage, anything), not just ones that show up
        # as an Ethernet interface. See get_internal_radio_usb_path above
        # for why the internal radio's own path is excluded.
        #
        # IMPROVEMENT (performance, run continuously every 2s): this used
        # to call the `dmesg` binary TWICE per iteration whenever new lines
        # showed up - once just to get the line count (`wc -l`), then again
        # moments later to actually read the new lines (`tail`). dmesg on
        # this device reads straight from the kernel ring buffer - a fork+
        # exec+kernel-read that's pure waste to pay twice for the same
        # snapshot when it's trivial to capture the buffer ONCE into a
        # variable. Verified equivalent with a standalone repro (fake
        # dmesg() with a call counter): identical output, dmesg invocations
        # per "new lines" iteration dropped from 2 to 1. The no-change path
        # (the common case, most iterations) was already just 1 call and
        # stays that way. (The "line count" half of the original wording
        # here is now stale - see below: this later moved from a count diff
        # to a content-watermark diff. The single-dmesg-call-per-iteration
        # property this paragraph documents is still exactly what happens.)
        # Content-watermark based change detection - see the baseline
        # comment above (where $dmesg_prev/$dmesg_last_line are first set)
        # for why this replaced a plain line-count diff. `dmesg_now !=
        # dmesg_prev` is a cheap whole-string comparison, no more expensive
        # than the `wc -l`/`grep -c .` this used to compute every cycle -
        # the no-change path (the common case, most iterations) still costs
        # exactly one `dmesg` call and one comparison, nothing more.
        local dmesg_now
        dmesg_now=$(dmesg 2>/dev/null)
        local _usb_grep='^\[.*\] usb [0-9]+-[0-9.]+: (new .* USB device|USB disconnect)'
        if [ "$dmesg_now" != "$dmesg_prev" ]; then
            local _wm_line=""
            if [ -n "$dmesg_last_line" ]; then
                _wm_line=$(printf '%s\n' "$dmesg_now" | grep -F -x -n -- "$dmesg_last_line" 2>/dev/null | tail -1 | cut -d: -f1)
            fi
            if [ -n "$_wm_line" ]; then
                # Watermark found - only the genuinely new tail after it
                # needs scanning, same incremental cost as the old -gt path.
                printf '%s\n' "$dmesg_now" | tail -n "+$((_wm_line + 1))" | grep -E "$_usb_grep" | process_usb_dmesg_lines
            else
                # Watermark not found (wrap/rotation, or nothing resolved
                # yet) - can't tell where "new" starts, so re-scan the whole
                # current buffer instead of assuming nothing changed. At
                # worst this re-notifies about an event from just before the
                # wrap once, same accepted tradeoff the old -lt branch used.
                printf '%s\n' "$dmesg_now" | grep -E "$_usb_grep" | process_usb_dmesg_lines
            fi
            dmesg_prev="$dmesg_now"
            dmesg_last_line=$(printf '%s\n' "$dmesg_now" | tail -n 1)
        fi

        prev_c="$c_state"; prev_a_if="$a_if"; prev_a_state="$a_state"
        sleep 2 &
        wait $!
    done
    say "Stopped."
}

# BUG FOUND AND FIXED (CRITICAL - root-caused live tonight): a real detach
# event ("USB-A (eth1): detached" / "USB-A: device detached (bus 1-1.1)")
# was confirmed on the device's own persistent on-screen Log view (fired by
# notify()'s LOG() call below) but was completely missing from THIS
# script's own $LOGFILE - which had only the startup banner, nothing else.
# Traced notify() itself first: it always calls say() (writes to this
# process's stdout, redirected into $LOGFILE) and LOG() together, back to
# back, with no branch that could fire one and skip the other - so the gap
# isn't in notify(). The actual root cause is one line down from here:
# `>"$LOGFILE"` TRUNCATES the file on every single --background launch,
# and --background gets re-invoked against an already-healthy, already-
# running instance by TWO entirely normal parts of this toolkit's own
# workflow, not just a crash: setup.py restarts usb_monitor.sh whenever
# this script's own content changed since the last deploy (see setup.py's
# usb_monitor_changed check) - exactly what an active bug-hunt/dev session
# does all night, redeploying fixes repeatedly - and reset.sh's
# ensure_usb_monitor() restarts it whenever --status doesn't report
# Running for any reason. Either path wipes out everything the PREVIOUS
# instance had already logged (including a real detach from minutes
# earlier) the moment the new instance's redirection opens, while LOG()'s
# target - the device's own persistent on-screen Log view, a store this
# script doesn't own and never touches - is completely unaffected and
# keeps the full history. Fixed by appending (`>>`) instead of truncating,
# so a restart's own startup banner is ADDED to prior history instead of
# replacing it. Bounded the same way lib/common.sh's own topology_log()
# already bounds itself (trim to the most recent 500 lines once the file
# passes 1000) so this can't grow without limit across a device's whole
# uptime through many redeploys/restarts either - done here at launch time
# only (not periodically mid-run): this process's own stdout fd stays
# pinned to $LOGFILE's inode for its entire run via the shell redirection
# below, so a rename-based trim done BY THIS SAME PROCESS while that fd is
# still open would silently keep writing to the old, now-unlinked inode
# instead of the replacement file - safe to do here, before the fd for
# THIS run is ever opened, not safe to repeat once it is.
if [ "$BACKGROUND" = "1" ]; then
    acquire_lock
    trap release_lock EXIT
    if is_running; then die "Already running (PID $(cat "$PIDFILE")). Use --stop first."; fi
    if [ -f "$LOGFILE" ]; then
        _usbmon_log_lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
        if [ "${_usbmon_log_lines:-0}" -gt 1000 ] 2>/dev/null; then
            tail -n 500 "$LOGFILE" >"${LOGFILE}.tmp.$$" 2>/dev/null && mv "${LOGFILE}.tmp.$$" "$LOGFILE" 2>/dev/null
            rm -f "${LOGFILE}.tmp.$$" 2>/dev/null
        fi
    fi
    # `trap - EXIT` INSIDE these parens is not optional - BUG FOUND AND
    # FIXED during this same pass (caught before it ever shipped, by
    # tracing what a forked child inherits rather than by a live symptom):
    # the child forked by the trailing `&` below inherits the parent's
    # traps at fork time, including the "trap release_lock EXIT" just set
    # two lines up. Without clearing it here, the child would ALSO run
    # release_lock whenever IT eventually exits - which for a daemon
    # meant to run for days is arbitrarily far in the future, e.g. whenever
    # --stop finally reaches it - and by then $LOCKDIR could easily belong
    # to a completely unrelated, currently in-progress --background/--stop/
    # --status call, which the child's stale trap would then rmdir out from
    # under it. The parent already releases the lock itself, immediately
    # below, right after the fork - the lock was only ever meant to guard
    # this launch sequence, not run_monitor's entire lifetime.
    ( trap '' HUP; trap - EXIT; run_monitor ) >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    release_lock
    trap - EXIT
    say "Started (PID $(cat "$PIDFILE")). Log: $LOGFILE"
    exit 0
fi

run_monitor

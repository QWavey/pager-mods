#!/bin/bash
# usb_monitor.sh - background watcher that shows an on-screen message every
# time a device attaches or detaches on USB-C (eth0, the built-in port) or
# USB-A (whatever's plugged into the external adapter port). Deliberately a
# plain background daemon, NOT a Hak5 payload - it is not meant to be driven
# through the on-screen payload picker.
#
# This is a clean rewrite (the previous version, kept at
# old/usb_monitor_old.sh, had accumulated many rounds of live-debugging
# patches - locks-for-alerts, an auto-dismiss WebSocket helper, a debounce
# state machine, diagnostic logging - most of which turned out to be
# chasing a problem that isn't in this script at all). What survives here
# is only the parts that were actually proven correct: the detection logic,
# the process-lifecycle lock, and the PID-reuse-safe start/stop handling.
#
# KNOWN PLATFORM LIMITATION (exhaustively confirmed live - see
# Dev/POSTMORTEMS.md for the full investigation): an ALERT fired in direct
# reaction to a real USB-C (eth0) carrier change does not render on the
# physical screen until some later UI activity happens - so a quick
# unplug/replug tends to show both messages together, after the replug,
# rather than the detach showing the instant it happens. This was proven
# with a 10-line bare watcher that has NONE of this script's machinery -
# same behaviour - so it is a limitation of Hak5's own closed UI process,
# not something this script can fix. eth0 is this SoC's own USB gadget
# controller, so physically unplugging it triggers real USB re-enumeration
# that briefly stalls that UI process. Attach events, USB-A events, and
# manual ALERT calls all render instantly; only the USB-C-detach case
# is affected. This script fires the message instantly on every event
# regardless; there is nothing more it can do about the render timing.
#
# How detection works (all three proven correct in prior bug-hunts):
#   - USB-C (eth0): a fixed platform device that always exists - only its
#     CARRIER (cable in / link up) changes. Polled via iface_has_carrier.
#   - USB-A Ethernet adapters: detect_usb_a_iface() gives the interface
#     name (e.g. eth1) and iface_has_carrier its link state.
#   - USB-A ANY device: real USB bus attach/disconnect events from dmesg,
#     catching non-Ethernet peripherals (WiFi adapters, storage, etc.)
#     that never create an ethN interface at all. The Pager's own internal
#     radio is also a USB device, so its bus path is resolved and excluded.
#
# Usage:
#   usb_monitor.sh --watch          foreground, prints on every change, Ctrl+C to stop
#   usb_monitor.sh --background      same, detached - use --stop to end it
#   usb_monitor.sh --status         is a background watcher running?
#   usb_monitor.sh --stop           stop a background watcher
#   -h, --help                      this help

set -u
TOOL_NAME="usb_monitor.sh"
PIDFILE="/tmp/pager-usbmon.pid"
LOGFILE="/tmp/pager-usbmon.log"
# Published (attached/detached) on every USB-A transition for any other
# script that wants a cheap early hint - sniff.sh's bridge watchdog reads
# it. Advisory only: goes stale the moment this daemon isn't running.
USB_A_STATEFILE="/tmp/pager-usb-a-state"
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

# -- process lifecycle -------------------------------------------------------
#
# is_running trusts the PIDFILE only after pid_running() confirms the PID's
# /proc/PID/cmdline still names this script (guards against PID reuse).
is_running() { pid_running "$PIDFILE" "usb_monitor.sh"; }

# A single mkdir-based lock serializes --background/--stop/--status against
# each other. mkdir is atomic per POSIX and needs nothing installed (flock
# isn't guaranteed on this busybox). This matters because setup.py (on every
# redeploy) and reset.sh's ensure_usb_monitor() can both independently decide
# to (re)start this daemon at the same instant - without the lock, two
# racers could each write $PIDFILE and leave one instance permanently
# untracked. Held only across the fast local work in those three blocks,
# never across run_monitor's loop.
#
# _lock_holder_stale recovers a lock whose holder died without releasing it:
# a recorded PID that is gone (or was reused by an unrelated process, checked
# via cmdline), or - covering the tiny window between mkdir and the pid-file
# write - a lock dir with no pid file that's already older than a couple
# seconds.
LOCKDIR="/tmp/pager-usbmon.lock"
_lock_holder_stale() {
    local dir="$1" holder="$2" mtime now
    if [ -z "$holder" ]; then
        mtime=$(date -r "$dir" +%s 2>/dev/null)
        case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
        now=$(date +%s)
        [ "$now" -ge "$mtime" ] && [ $((now - mtime)) -ge 2 ] && return 0
        return 1
    fi
    kill -0 "$holder" 2>/dev/null || return 0
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
            rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null; continue
        fi
        sleep 0.1
    done
    echo $$ > "$LOCKDIR/pid" 2>/dev/null
}
release_lock() { rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null; }

if [ "$DO_STATUS" = "1" ]; then
    acquire_lock; trap release_lock EXIT
    if is_running; then say "Running (PID $(cat "$PIDFILE"))."; else say "Not running."; fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    acquire_lock; trap release_lock EXIT
    if is_running; then
        # Wait for the process to actually exit before declaring success:
        # SIGTERM is only acted on between loop iterations, and setup.py's
        # redeploy does --stop immediately followed by --background - a
        # false "Stopped." there would let the restart clobber a still-live
        # instance into an untracked duplicate.
        _stop_pid="$(cat "$PIDFILE")"
        kill "$_stop_pid" 2>/dev/null
        _stop_tries=0
        while kill -0 "$_stop_pid" 2>/dev/null && [ "$_stop_tries" -lt 20 ]; do
            _stop_tries=$((_stop_tries + 1)); sleep 0.25
        done
        if kill -0 "$_stop_pid" 2>/dev/null; then
            err "PID $_stop_pid didn't exit within 5s of SIGTERM - sending SIGKILL."
            kill -9 "$_stop_pid" 2>/dev/null; sleep 0.25
        fi
        rm -f "$PIDFILE"; say "Stopped."
    else
        say "Nothing running."
    fi
    exit 0
fi

STOPPING=0
_on_stop() { STOPPING=1; }
trap _on_stop INT TERM

# -- notification ------------------------------------------------------------
#
# Show a USB event to the operator via three best-effort, fire-and-forget
# channels:
#   say()  - into $LOGFILE / SSH stdout (always).
#   LOG    - the device's persistent on-screen Log view (mostly history for
#            a bare daemon; only truly renders inside a payload console).
#   ALERT  - the full-screen on-screen popup - the one channel that puts
#            real text on the physical screen from a background daemon.
#
# LOG and ALERT are backgrounded (and timeout-bounded) so a slow/blocked UI
# call can never delay the detection loop. NO auto-dismiss: there is no
# clean API for it, and the homegrown one the old version used was chasing
# the USB-C-detach render lag documented in the header, which it never
# fixed. Dismiss an on-screen alert with the physical A button.
notify() {
    say "$1"
    command -v LOG   >/dev/null 2>&1 && ( timeout 10 LOG   "[usb_monitor.sh] $1" >/dev/null 2>&1 ) &
    command -v ALERT >/dev/null 2>&1 && ( timeout 10 ALERT "[usb_monitor.sh] $1" >/dev/null 2>&1 ) &
}

# -- detection helpers (carried forward verbatim - proven correct) -----------

# The Pager's own internal radio is a USB device too; resolve its bus path
# so it can be told apart from a genuinely external USB-A device. Uses the
# wlan1mon interface's own /sys symlink - unambiguous, no string-matching.
get_internal_radio_usb_path() {
    local real
    real=$(readlink -f /sys/class/net/wlan1mon/device 2>/dev/null)
    [ -z "$real" ] && return
    echo "$real" | grep -oE '[0-9]+-[0-9.]+(:[0-9.]+)?$' | head -1 | sed -E 's/:[0-9.]+$//'
}

# A small table of real USB-IF registered vendor IDs for common brands.
# Anything not listed shows its raw idVendor:idProduct instead.
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

# describe_usb_device PATH - resolve a bus path to "NAME (chip type)".
# Retries briefly because sysfs populates as enumeration completes, and
# only ever overwrites a field with a NON-empty read, so a device that
# vanishes mid-lookup can't erase data an earlier read already captured.
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
        tries=$((tries + 1)); sleep 0.3
    done
    [ -z "$vid" ] && return 1
    local name; name=$(usb_vendor_name "$vid")
    [ -z "$name" ] && name="${vid}:${pid}"
    local type_str="${mfr:-unknown chip} ${prod:-device}"
    echo "$name ($type_str)"
    return 0
}

# Read grep-filtered USB dmesg lines from stdin and notify for each one
# that isn't the internal radio. ($internal_radio_path is set by run_monitor.)
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

# -- main watch loop ---------------------------------------------------------
#
# Polls every 2s, notifies exactly once per real state change, never on the
# first read (that would just announce whatever's already plugged in).
run_monitor() {
    say "Watching USB-C/USB-A for attach/detach - Ctrl+C to stop."

    local internal_radio_path
    internal_radio_path=$(get_internal_radio_usb_path)
    # wlan1mon may not exist yet at an early-boot start - retry briefly so
    # the internal-radio exclusion works for this whole run.
    if [ -z "$internal_radio_path" ]; then
        local _radio_tries=0
        while [ "$_radio_tries" -lt 5 ] && [ -z "$internal_radio_path" ]; do
            sleep 0.5
            internal_radio_path=$(get_internal_radio_usb_path)
            _radio_tries=$((_radio_tries + 1))
        done
    fi

    # dmesg change detection by content watermark (not line count - a full
    # kernel ring buffer turns over without the count changing). Track the
    # last-seen line; everything after it in a new dump is new. If the
    # watermark line was evicted (wrap), re-scan the whole buffer.
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
            a_state="detected but link down"
        else
            a_state="none"
        fi

        # Best-effort periodic retry of the internal-radio path, only while
        # still unresolved (never re-guesses a path already found).
        _loop_iter=$((_loop_iter + 1))
        if [ -z "$internal_radio_path" ] && [ $((_loop_iter % 60)) -eq 0 ]; then
            internal_radio_path=$(get_internal_radio_usb_path)
        fi

        # Publish USB-A interface presence on transition (advisory hint file).
        local usb_a_pub
        if [ -n "$a_if" ]; then usb_a_pub="attached"; else usb_a_pub="detached"; fi
        if [ "$usb_a_pub" != "$prev_usb_a_pub" ]; then
            printf '%s\n' "$usb_a_pub" >"${USB_A_STATEFILE}.tmp.$$" 2>/dev/null && mv -f "${USB_A_STATEFILE}.tmp.$$" "$USB_A_STATEFILE" 2>/dev/null
            rm -f "${USB_A_STATEFILE}.tmp.$$" 2>/dev/null
            prev_usb_a_pub="$usb_a_pub"
        fi

        # Notify instantly on each real transition.
        if [ -n "$prev_c" ] && [ "$c_state" != "$prev_c" ]; then
            notify "USB-C: $c_state"
        fi
        if [ -n "$prev_a_state" ] && { [ "$a_state" != "$prev_a_state" ] || [ "$a_if" != "$prev_a_if" ]; }; then
            if [ -z "$a_if" ]; then
                notify "USB-A ($prev_a_if): detached"
            else
                notify "USB-A ($a_if): $a_state"
            fi
        fi

        # Generic USB-A bus-level attach/detach (catches non-Ethernet devices).
        local dmesg_now
        dmesg_now=$(dmesg 2>/dev/null)
        local _usb_grep='^\[.*\] usb [0-9]+-[0-9.]+: (new .* USB device|USB disconnect)'
        if [ "$dmesg_now" != "$dmesg_prev" ]; then
            local _wm_line=""
            if [ -n "$dmesg_last_line" ]; then
                _wm_line=$(printf '%s\n' "$dmesg_now" | grep -F -x -n -- "$dmesg_last_line" 2>/dev/null | tail -1 | cut -d: -f1)
            fi
            if [ -n "$_wm_line" ]; then
                printf '%s\n' "$dmesg_now" | tail -n "+$((_wm_line + 1))" | grep -E "$_usb_grep" | process_usb_dmesg_lines
            else
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

# -- launch ------------------------------------------------------------------

if [ "$BACKGROUND" = "1" ]; then
    acquire_lock; trap release_lock EXIT
    if is_running; then die "Already running (PID $(cat "$PIDFILE")). Use --stop first."; fi
    # Trim the log at launch (append across restarts, never truncate, so a
    # restart doesn't wipe a real event logged by the previous instance).
    if [ -f "$LOGFILE" ]; then
        _usbmon_log_lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
        if [ "${_usbmon_log_lines:-0}" -gt 1000 ] 2>/dev/null; then
            tail -n 500 "$LOGFILE" >"${LOGFILE}.tmp.$$" 2>/dev/null && mv "${LOGFILE}.tmp.$$" "$LOGFILE" 2>/dev/null
            rm -f "${LOGFILE}.tmp.$$" 2>/dev/null
        fi
    fi
    # `trap - EXIT` inside the subshell: the forked child inherits the
    # parent's release_lock EXIT trap; without clearing it the daemon would
    # release an unrelated future lock whenever it eventually exits. The
    # parent releases the launch lock itself right after the fork.
    ( trap '' HUP; trap - EXIT; run_monitor ) >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    release_lock; trap - EXIT
    say "Started (PID $(cat "$PIDFILE")). Log: $LOGFILE"
    exit 0
fi

run_monitor

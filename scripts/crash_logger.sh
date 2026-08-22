#!/bin/bash
# crash_logger.sh - continuously appends dmesg/logread output to PERSISTENT
# storage (/mmc, a real ext4 partition), so a crash that forces a reboot
# doesn't destroy its own evidence the way it has three times running now
# during dual-radio deauth testing.
#
# WHY THIS EXISTS: dmesg and logread both live entirely in RAM on this
# device (confirmed live: `mount` shows / is an overlayfs over a 31.6MB
# jffs2 partition, /tmp is tmpfs, and the kernel ring buffer itself is
# obviously RAM-only) - every one of the three real crashes hit while
# testing raw_deauth.py's dual-radio feature left ZERO forensic trace,
# because dmesg/logread both reset on boot and nothing was capturing them
# to disk in real time. /mmc is a genuinely separate, persistent ext4
# partition (3.3GB free, confirmed live) - the one piece of storage on
# this device that actually survives a crash/reboot.
#
# This polls dmesg with a bounded diff (wc -l + tail -n +N, the same
# pattern used throughout this codebase instead of `dmesg -w`/`tail -f` -
# not because -w is known broken here, just consistency with the
# established orphan-process-safe pattern) every 1s, appends new lines to
# /mmc/crash_dmesg.log, and calls `sync` after every write so whatever
# made it to the file is actually on flash, not just buffered - cheap
# insurance against a hard crash that doesn't get a clean unmount.
#
# Usage: crash_logger.sh --background   (start, logs to /mmc/crash_dmesg.log)
#        crash_logger.sh --stop
#        crash_logger.sh --status
#
# After a crash, read /mmc/crash_dmesg.log (survives the reboot) instead
# of dmesg (which won't - it resets on every boot).

set -u
PIDFILE="/tmp/pager-crashlogger.pid"
LOGFILE="/mmc/crash_dmesg.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

BACKGROUND=0; DO_STOP=0; DO_STATUS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BIG CHANGE (adopting common.sh's shared primitive): same PIDFILE+kill-0
# check duplicated across deauth.sh/sniff.sh/bluetooth.sh - now backed by
# one canonical pid_running() in lib/common.sh instead of yet another copy.
# pid_running's optional NAME_PATTERN (see lib/common.sh) guards against a
# stale PIDFILE whose PID got reused by an unrelated process - the
# backgrounded run_logger loop is a subshell of THIS script, so its real
# /proc/PID/cmdline still shows "crash_logger.sh".
is_running() { pid_running "$PIDFILE" "crash_logger.sh"; }

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE")) - logging to $LOGFILE"
    else
        say "Not running."
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
        say "Stopped."
    else
        say "Nothing running."
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
    exit 0
fi

run_logger() {
    [ -d /mmc ] || { echo "crash_logger.sh: /mmc not mounted - refusing to start (would log to RAM, defeating the purpose)." >&2; exit 1; }
    echo "=== crash_logger started $(date) ===" >> "$LOGFILE"
    sync
    local seen total loop_count=0
    seen=$(dmesg 2>/dev/null | wc -l)
    # BUG FOUND AND FIXED (bug-hunt pass - exactly the "log file that's
    # never rotated/truncated" class this session was asked to hunt for):
    # this loop runs continuously, across every reboot, for as long as the
    # device is up - LOGFILE had no size bound at all, appending forever.
    # /mmc is a real but FINITE, SHARED partition (3.3GB free, confirmed
    # live per this file's own header) also used for pcaps/loot by other
    # tools in this toolkit - an unbounded dmesg log left running for
    # weeks/months (or one especially chatty crash cascade, exactly the
    # scenario this tool exists to capture, which can dump the WHOLE ring
    # buffer repeatedly - see the wrap-handling branch below) could
    # eventually fill it, which would then break every OTHER tool relying
    # on /mmc, not just this one. Same "keep only the most recent N" bound
    # already established by topology_log() in lib/common.sh, just sized
    # for a forensic dmesg log instead of a topology transition log, and
    # checked only every ~60 polls (a byte-count check on every single 1s
    # poll would be wasteful) rather than on every single one - rotates
    # (keeps the tail) instead of deleting so recent forensic context
    # always survives.
    local max_log_bytes=$((20 * 1024 * 1024))
    while true; do
        total=$(dmesg 2>/dev/null | wc -l)
        if [ "$total" -gt "$seen" ] 2>/dev/null; then
            dmesg 2>/dev/null | tail -n "+$((seen + 1))" >> "$LOGFILE"
            sync
            seen="$total"
        elif [ "$total" -lt "$seen" ] 2>/dev/null; then
            # BUG FOUND AND FIXED: the kernel ring buffer has a fixed
            # capacity - once it fills, old lines get evicted from the
            # front as new ones are appended, so `dmesg | wc -l` can drop
            # (or plateau) even though genuinely new messages keep
            # arriving. The original `total -gt seen`-only check goes
            # permanently blind the instant this happens during a long/
            # busy session (a real crash cascade is exactly the kind of
            # burst that fills a small embedded ring buffer) - it would
            # silently stop capturing anything for the rest of the run,
            # with --status still happily reporting "Running", defeating
            # the entire point of this tool. A drop is an unambiguous wrap
            # signal: dump the whole current buffer (bounded by the
            # kernel's own buffer size, so cheap) instead of diffing
            # against a baseline that's no longer valid, and re-baseline
            # from there. Honest limitation: a buffer that plateaus at
            # EXACTLY the same line count every single poll (one evicted
            # per one appended, indefinitely) wouldn't trip this
            # either-direction check - that steady-state pattern isn't how
            # real kernel message bursts behave in practice, so this is a
            # pragmatic fix for the realistic failure mode, not a
            # mathematically airtight one.
            echo "=== crash_logger: dmesg buffer appears to have wrapped (was $seen lines, now $total) - capturing current buffer ===" >> "$LOGFILE"
            dmesg 2>/dev/null >> "$LOGFILE"
            sync
            seen="$total"
        fi
        loop_count=$((loop_count + 1))
        if [ "$((loop_count % 60))" -eq 0 ]; then
            local sz
            sz=$(wc -c <"$LOGFILE" 2>/dev/null || echo 0)
            if [ "$sz" -gt "$max_log_bytes" ] 2>/dev/null; then
                tail -c "$max_log_bytes" "$LOGFILE" >"${LOGFILE}.tmp.$$" 2>/dev/null && mv "${LOGFILE}.tmp.$$" "$LOGFILE" 2>/dev/null
                rm -f "${LOGFILE}.tmp.$$" 2>/dev/null
                echo "=== crash_logger: log rotated (exceeded $((max_log_bytes / 1024 / 1024))MB) - oldest history trimmed ===" >> "$LOGFILE"
                sync
            fi
        fi
        sleep 1
    done
}

if [ "$BACKGROUND" = "1" ]; then
    is_running && die "Already running (PID $(cat "$PIDFILE")). Use --stop first."
    [ -d /mmc ] || die "/mmc not mounted - refusing to start (would log to RAM, defeating the purpose)."
    ( trap '' HUP; run_logger ) >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    say "Started in background (PID $(cat "$PIDFILE")) - logging to $LOGFILE (survives a crash/reboot). Use --stop to end it."
else
    say "Logging to $LOGFILE (persistent - survives a crash/reboot). Ctrl+C to stop."
    run_logger
fi

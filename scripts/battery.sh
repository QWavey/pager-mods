#!/bin/bash
# battery.sh - Show the Pager's battery level. Wraps the official
# BATTERY_PERCENT and BATTERY_CHARGING DuckyScript commands.
#
# Usage:
#   battery.sh              print "72% (charging)" style summary
#   battery.sh --percent     print just the number, e.g. "72"
#   battery.sh --watch        refresh every 5s until Ctrl+C
#
# Options:
#   --percent       Print only the raw percentage number
#   --watch          Keep printing, refreshing every --interval seconds
#   --interval SECS   Refresh interval for --watch (default: 5)
#   --alert-below PCT  With --watch: fire an on-screen ALERT the moment the
#                        battery first drops below PCT (not charging), once
#                        per dip - not every cycle. Useful for an unattended
#                        field engagement where nobody's watching the SSH
#                        output but the physical screen is still visible.
#   -h, --help         This help

set -u
TOOL_NAME="battery.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

PERCENT_ONLY=0
WATCH=0
INTERVAL=5
ALERT_BELOW=""

while [ $# -gt 0 ]; do
    case "$1" in
        --percent) PERCENT_ONLY=1; shift ;;
        --watch) WATCH=1; shift ;;
        --interval) need_arg "--interval" "$#"; INTERVAL="$2"; shift 2 ;;
        --alert-below) need_arg "--alert-below" "$#"; ALERT_BELOW="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

if [ -n "$ALERT_BELOW" ]; then
    case "$ALERT_BELOW" in ''|*[!0-9]*) die "'--alert-below' needs a whole-number percentage (got '$ALERT_BELOW')." ;; esac
    if [ "$ALERT_BELOW" -lt 1 ] || [ "$ALERT_BELOW" -gt 99 ]; then
        die "'--alert-below' must be between 1 and 99 (got '$ALERT_BELOW')."
    fi
fi

# BUG FOUND AND FIXED (same class as a bug fixed in deauth.sh's --interval):
# --interval was never validated before being handed to `sleep "$INTERVAL"`
# inside the --watch loop. A non-numeric or negative value makes sleep fail
# instantly instead of actually delaying, turning --watch into a tight
# busy-loop calling BATTERY_PERCENT/BATTERY_CHARGING as fast as the shell
# can, with no rate limit.
case "$INTERVAL" in ''|*[!0-9.]*|.|*.*.*) die "'--interval' needs a non-negative number of seconds (got '$INTERVAL')." ;; esac

print_battery() {
    local pct charging
    pct=$(BATTERY_PERCENT 2>/dev/null)
    charging=$(BATTERY_CHARGING 2>/dev/null)

    if [ "$PERCENT_ONLY" = "1" ]; then
        echo "$pct"
        return
    fi

    case "$charging" in
        1|true|yes|charging) echo "${pct}% (charging)" ;;
        *) echo "${pct}%" ;;
    esac
}

if [ "$WATCH" = "1" ]; then
    # BIG CHANGE: --watch used to be pure polling - print, sleep, repeat,
    # forever, with no way to notice a real problem short of someone
    # actively reading the SSH output at the exact moment it happens. This
    # is specifically the mode meant for an unattended engagement (that's
    # the whole reason to --watch instead of just checking once), which is
    # exactly when nobody IS watching the terminal. --alert-below closes
    # that gap: fire ALERT (physical on-screen, so it's visible even with
    # no SSH session open) the moment the battery first crosses below the
    # threshold - "already_alerted" gives it hysteresis (fires once per
    # dip, not once per --interval tick for as long as it stays low), and
    # resets once the level recovers above the threshold (a charger got
    # plugged in) so a second real dip alerts again instead of staying
    # silently "already handled" for the rest of the session.
    already_alerted=0
    while true; do
        print_battery
        if [ -n "$ALERT_BELOW" ]; then
            _pct=$(BATTERY_PERCENT 2>/dev/null)
            _charging=$(BATTERY_CHARGING 2>/dev/null)
            case "$_pct" in
                ''|*[!0-9]*) : ;;  # unreadable this cycle - skip, don't misfire on garbage
                *)
                    case "$_charging" in
                        1|true|yes|charging) already_alerted=0 ;;  # charging - never alert, and rearm
                        *)
                            if [ "$_pct" -lt "$ALERT_BELOW" ]; then
                                if [ "$already_alerted" = "0" ]; then
                                    ALERT "Battery low: ${_pct}% (below ${ALERT_BELOW}%)" 2>/dev/null
                                    already_alerted=1
                                fi
                            else
                                already_alerted=0
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
        sleep "$INTERVAL"
    done
else
    print_battery
fi

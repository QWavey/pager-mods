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
#   -h, --help         This help

set -u
TOOL_NAME="battery.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

PERCENT_ONLY=0
WATCH=0
INTERVAL=5

while [ $# -gt 0 ]; do
    case "$1" in
        --percent) PERCENT_ONLY=1; shift ;;
        --watch) WATCH=1; shift ;;
        --interval) need_arg "--interval" "$#"; INTERVAL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

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
    while true; do
        print_battery
        sleep "$INTERVAL"
    done
else
    print_battery
fi

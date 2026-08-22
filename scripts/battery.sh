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

# battery_sysfs_dir - autodetects the Linux power_supply sysfs directory
# for the battery. Not hardcoded to a specific name - the directory under
# /sys/class/power_supply/ is driver-dependent (could be "battery",
# "BAT0", "axp20x-battery", etc., varies by device/kernel) - so this
# checks each candidate's own "type" file for the literal value "Battery"
# instead, the standard Linux power_supply class convention, and is
# robust to whatever this specific device's driver happens to call it.
battery_sysfs_dir() {
    local d
    for d in /sys/class/power_supply/*/; do
        [ -r "${d}type" ] || continue
        [ "$(cat "${d}type" 2>/dev/null)" = "Battery" ] && { echo "${d%/}"; return 0; }
    done
    return 1
}

# battery_extra_info DIR - INVENTED FEATURE (asked for directly - "on the
# charging also (the volts or w currently), (guessed time till full)"):
# best-effort extra detail, read straight from the kernel's own
# power_supply sysfs - there is no official BATTERY_* DuckyScript command
# for voltage/current/time-remaining, only BATTERY_PERCENT/BATTERY_
# CHARGING (see this file's own header), so this can't use the same
# always-reliable path those do. Different battery drivers expose
# different file sets - some give voltage_now/current_now (a real-time
# coulomb-counter reading in microvolts/microamps), others only
# charge_now/charge_full (microamp-hours) or energy_now/energy_full/
# power_now (microwatt-hours/microwatts) - this tries whichever
# combination is actually present and silently prints nothing usable if
# none of them are, rather than guessing at a specific file that might
# not exist on this exact device (this has NOT been live-verified against
# real hardware - if it never shows extra detail, that most likely means
# this device's battery driver doesn't expose these files at all, not
# that something is broken; BATTERY_PERCENT/BATTERY_CHARGING above remain
# the primary, always-used source and are completely unaffected either
# way).
battery_extra_info() {
    local dir="$1"
    local voltage_uv="" current_ua="" power_uw="" charge_now="" charge_full="" energy_now="" energy_full=""
    local volts watts mins out=""

    [ -r "$dir/voltage_now" ] && voltage_uv=$(cat "$dir/voltage_now" 2>/dev/null)
    [ -r "$dir/current_now" ] && current_ua=$(cat "$dir/current_now" 2>/dev/null)
    [ -r "$dir/power_now" ] && power_uw=$(cat "$dir/power_now" 2>/dev/null)

    if [ -n "$voltage_uv" ] && [ "$voltage_uv" -gt 0 ] 2>/dev/null; then
        volts=$(awk -v v="$voltage_uv" 'BEGIN { printf "%.1f", v / 1000000 }')
        out="${volts}V"
    fi

    # Prefer a direct power_now reading; fall back to volts*amps if only
    # those two are available. current_now can be reported negative while
    # discharging on some drivers - take the magnitude, direction is
    # already conveyed separately by BATTERY_CHARGING.
    if [ -z "$power_uw" ] && [ -n "$voltage_uv" ] && [ -n "$current_ua" ]; then
        power_uw=$(awk -v v="$voltage_uv" -v c="$current_ua" 'BEGIN { if (c < 0) c = -c; printf "%d", (v / 1000000) * (c / 1000000) * 1000000 }' 2>/dev/null)
    fi
    if [ -n "$power_uw" ] && [ "$power_uw" -gt 0 ] 2>/dev/null; then
        watts=$(awk -v p="$power_uw" 'BEGIN { printf "%.1f", p / 1000000 }')
        [ -n "$out" ] && out="$out, "
        out="${out}${watts}W"
    fi

    # Time-to-full estimate: needs both "how much is left to fill"
    # (charge_full - charge_now, or energy_full - energy_now) and a rate
    # (current_now, or power_now) - only attempted if a matching pair is
    # present. Whole minutes, rounded down; only shown if it comes out
    # positive (a rate of 0 or a full/near-full battery correctly shows
    # nothing here rather than a bogus "0min" or a divide-by-zero).
    [ -r "$dir/charge_now" ] && charge_now=$(cat "$dir/charge_now" 2>/dev/null)
    [ -r "$dir/charge_full" ] && charge_full=$(cat "$dir/charge_full" 2>/dev/null)
    [ -r "$dir/energy_now" ] && energy_now=$(cat "$dir/energy_now" 2>/dev/null)
    [ -r "$dir/energy_full" ] && energy_full=$(cat "$dir/energy_full" 2>/dev/null)

    if [ -n "$charge_now" ] && [ -n "$charge_full" ] && [ -n "$current_ua" ] && [ "$current_ua" -gt 0 ] 2>/dev/null; then
        mins=$(awk -v full="$charge_full" -v now="$charge_now" -v rate="$current_ua" 'BEGIN { printf "%d", ((full - now) / rate) * 60 }' 2>/dev/null)
    elif [ -n "$energy_now" ] && [ -n "$energy_full" ] && [ -n "$power_uw" ] && [ "$power_uw" -gt 0 ] 2>/dev/null; then
        mins=$(awk -v full="$energy_full" -v now="$energy_now" -v rate="$power_uw" 'BEGIN { printf "%d", ((full - now) / rate) * 60 }' 2>/dev/null)
    fi
    if [ -n "${mins:-}" ] && [ "$mins" -gt 0 ] 2>/dev/null; then
        [ -n "$out" ] && out="$out, "
        out="${out}~${mins}min to full"
    fi

    echo "$out"
}

print_battery() {
    local pct charging
    pct=$(BATTERY_PERCENT 2>/dev/null)
    charging=$(BATTERY_CHARGING 2>/dev/null)

    if [ "$PERCENT_ONLY" = "1" ]; then
        echo "$pct"
        return
    fi

    # IMPROVEMENT (asked for directly - "100% (charging) or 100%
    # (discharging)"): the discharging case used to just print the bare
    # percentage with no state label at all, unlike charging (which
    # already said so). Only claims "(discharging)" on a recognized
    # explicit false value from BATTERY_CHARGING, same conservative
    # convention as the existing charging match just below - an
    # unreadable/unrecognized value falls through to the bare percentage
    # rather than asserting a state that isn't actually confirmed.
    case "$charging" in
        1|true|yes|charging)
            local dir extra
            dir=$(battery_sysfs_dir 2>/dev/null)
            extra=""
            [ -n "$dir" ] && extra=$(battery_extra_info "$dir")
            if [ -n "$extra" ]; then
                echo "${pct}% (charging, $extra)"
            else
                echo "${pct}% (charging)"
            fi
            ;;
        0|false|no|discharging)
            echo "${pct}% (discharging)"
            ;;
        *)
            echo "${pct}%"
            ;;
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

#!/bin/bash
# filters.sh - Manage PineAP device (MAC) and network (SSID) filters.
# Wraps PINEAPPLE_DEVICE_FILTER_* and PINEAPPLE_NETWORK_FILTER_*.
#
# Usage:
#   filters.sh device mode allow|deny
#   filters.sh device add allow|deny AA:BB:CC:DD:EE:FF [MAC2 ...]
#   filters.sh device delete allow|deny AA:BB:CC:DD:EE:FF [MAC2 ...]
#   filters.sh device clear allow|deny
#   filters.sh device list allow|deny
#   filters.sh network mode allow|deny
#   filters.sh network add allow|deny "SSID" ["SSID2" ...]
#   filters.sh network delete allow|deny "SSID" ["SSID2" ...]
#   filters.sh network clear allow|deny
#   filters.sh network list allow|deny
#   filters.sh                interactive mode
#
# Note: PINEAPPLE_MIMIC is automatically paused while filters change and
# re-enabled after, matching Hak5's own documented example - filter
# changes should not be made live while mimic mode is actively answering
# probes.

set -u
TOOL_NAME="filters.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

TYPE="${1:-}"
ACTION="${2:-}"
shift 2 2>/dev/null

with_mimic_paused() {
    PINEAPPLE_MIMIC_DISABLE 2>/dev/null
    "$@"
    local rc=$?
    PINEAPPLE_MIMIC_ENABLE 2>/dev/null
    return $rc
}

# need_list ACTION - BUG FOUND AND FIXED: mode/clear/list below dereference
# "$1" directly (the allow/deny list name) with no check that anything was
# actually passed - unlike every other script in this toolkit, which uses
# need_arg for exactly this. Missing it: `filters.sh device list` (no
# allow/deny) hit `shift 2` consuming both given words, leaving zero
# positional params, then "$1" under `set -u` aborted with a raw
# "1: unbound variable" instead of a clean error. Confirmed live in
# isolation with the same TYPE/ACTION+shift 2 skeleton.
need_list() {
    # Deliberately uses $ACTION (already known in the outer scope), not
    # "$1" - when this guard is actually needed, $# is 0, so referencing
    # "$1" here would itself be the exact same unbound-variable crash
    # this function exists to prevent.
    [ "$#" -ge 1 ] || die "'$ACTION' needs a list name (allow or deny), e.g. filters.sh device $ACTION allow"
}

# BIG CHANGE: run_device()/run_network() used to be two hand-maintained,
# 95%-identical copies of the same five-action dispatch (mode/add/delete/
# clear/list), differing only in the PINEAPPLE_{DEVICE,NETWORK}_FILTER_*
# command name and the item noun (MAC vs SSID) in the error messages - a fix
# to one (like need_list's own history shows already happened once, and the
# add/delete argument-count check almost happened again) could easily land
# in one copy and be forgotten in the other. TYPE is always exactly "device"
# or "network", and Hak5's own command naming already mirrors that 1:1, so
# this builds the real command name from TYPE instead of maintaining two
# copies of the same dispatch logic.
run_filter() {
    local type_upper noun cmd_prefix
    # BUG FOUND AND FIXED (found via code review, while unifying this
    # dispatch): the interactive picker below never actually validated its
    # free-typed "device/network" answer - the OLD code's `if [ "$t" =
    # "device" ]; then run_device; else run_network; fi` silently treated
    # ANY typo as "network" (wrong, but at least ran a real command). This
    # unified version needs its own explicit check instead of inheriting
    # that same silent-wrong-fallback behavior, or a typo'd TYPE would
    # instead build a broken "PINEAPPLE__FILTER_*" command name.
    case "$TYPE" in
        device) type_upper="DEVICE"; noun="MAC" ;;
        network) type_upper="NETWORK"; noun="SSID" ;;
        *) die "Unknown filter type '$TYPE' (expected device or network)" ;;
    esac
    cmd_prefix="PINEAPPLE_${type_upper}_FILTER"
    case "$ACTION" in
        mode) need_list "$@"; with_mimic_paused "${cmd_prefix}_MODE" "$1" ;;
        add) [ "$#" -ge 2 ] || die "'add' needs a list name (allow/deny) and at least one $noun, e.g. filters.sh $TYPE add allow ..."; with_mimic_paused "${cmd_prefix}_ADD" "$@" ;;
        delete) [ "$#" -ge 2 ] || die "'delete' needs a list name (allow/deny) and at least one $noun, e.g. filters.sh $TYPE delete allow ..."; with_mimic_paused "${cmd_prefix}_DELETE" "$@" ;;
        clear) need_list "$@"; with_mimic_paused "${cmd_prefix}_CLEAR" "$1" ;;
        list) need_list "$@"; "${cmd_prefix}_LIST" "$1" ;;
        *) err "Unknown $TYPE action '$ACTION'"; usage ;;
    esac
}

case "$TYPE" in
    device|network) run_filter "$@" ;;
    -h|--help) usage ;;
    "")
        echo "== filters.sh interactive =="
        t=$(ask "Filter type (device/network)" "device")
        a=$(ask "Action (mode/add/delete/clear/list)" "list")
        list=$(ask "List (allow/deny)" "allow")
        case "$a" in
            add|delete)
                TYPE="$t"; ACTION="$a"
                if [ "$t" = "device" ]; then
                    val=$(ask "MAC(s) to $a (space-separated - MACs never contain spaces, safe to split)" "")
                    run_filter "$list" $val
                else
                    # SSIDs can legitimately contain spaces, so a single
                    # free-text line can't safely be split on whitespace
                    # into multiple SSIDs (unlike MACs above) - one SSID
                    # per interactive entry; use the CLI form
                    # (filters.sh network add allow "SSID1" "SSID2") for
                    # multiple SSIDs in one call.
                    val=$(ask "SSID to $a (one at a time - use the CLI form for multiple)" "")
                    run_filter "$list" "$val"
                fi
                ;;
            *)
                TYPE="$t"; ACTION="$a"
                run_filter "$list"
                ;;
        esac
        ;;
    *) err "Unknown filter type '$TYPE' (expected device or network)"; usage ;;
esac

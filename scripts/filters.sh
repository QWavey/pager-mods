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

run_device() {
    case "$ACTION" in
        mode) need_list "$@"; with_mimic_paused PINEAPPLE_DEVICE_FILTER_MODE "$1" ;;
        # BUG FOUND AND FIXED (found via code review - same class need_list
        # itself already documents fixing for mode/clear/list, missed here):
        # add/delete had no argument check at all, unlike every other
        # action in this file - `filters.sh device add` with nothing
        # further would splat an EMPTY "$@" straight into
        # PINEAPPLE_DEVICE_FILTER_ADD, sending an incomplete command to the
        # Hak5 API instead of failing here with a clear reason. Needs at
        # least the list name AND one MAC to add/delete - a plain
        # need_list "$@" (>=1) isn't quite enough on its own here since
        # add/delete take a SECOND required piece (the actual value(s)),
        # so check for that too.
        add) [ "$#" -ge 2 ] || die "'add' needs a list name (allow/deny) and at least one MAC, e.g. filters.sh device add allow AA:BB:CC:DD:EE:FF"; with_mimic_paused PINEAPPLE_DEVICE_FILTER_ADD "$@" ;;
        delete) [ "$#" -ge 2 ] || die "'delete' needs a list name (allow/deny) and at least one MAC, e.g. filters.sh device delete allow AA:BB:CC:DD:EE:FF"; with_mimic_paused PINEAPPLE_DEVICE_FILTER_DELETE "$@" ;;
        clear) need_list "$@"; with_mimic_paused PINEAPPLE_DEVICE_FILTER_CLEAR "$1" ;;
        list) need_list "$@"; PINEAPPLE_DEVICE_FILTER_LIST "$1" ;;
        *) err "Unknown device action '$ACTION'"; usage ;;
    esac
}

run_network() {
    case "$ACTION" in
        mode) need_list "$@"; with_mimic_paused PINEAPPLE_NETWORK_FILTER_MODE "$1" ;;
        # Same fix as run_device's add/delete above, same reasoning.
        add) [ "$#" -ge 2 ] || die "'add' needs a list name (allow/deny) and at least one SSID, e.g. filters.sh network add allow \"My WiFi\""; with_mimic_paused PINEAPPLE_NETWORK_FILTER_ADD "$@" ;;
        delete) [ "$#" -ge 2 ] || die "'delete' needs a list name (allow/deny) and at least one SSID, e.g. filters.sh network delete allow \"My WiFi\""; with_mimic_paused PINEAPPLE_NETWORK_FILTER_DELETE "$@" ;;
        clear) need_list "$@"; with_mimic_paused PINEAPPLE_NETWORK_FILTER_CLEAR "$1" ;;
        list) need_list "$@"; PINEAPPLE_NETWORK_FILTER_LIST "$1" ;;
        *) err "Unknown network action '$ACTION'"; usage ;;
    esac
}

case "$TYPE" in
    device) run_device "$@" ;;
    network) run_network "$@" ;;
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
                    run_device "$list" $val
                else
                    # SSIDs can legitimately contain spaces, so a single
                    # free-text line can't safely be split on whitespace
                    # into multiple SSIDs (unlike MACs above) - one SSID
                    # per interactive entry; use the CLI form
                    # (filters.sh network add allow "SSID1" "SSID2") for
                    # multiple SSIDs in one call.
                    val=$(ask "SSID to $a (one at a time - use the CLI form for multiple)" "")
                    run_network "$list" "$val"
                fi
                ;;
            *)
                TYPE="$t"; ACTION="$a"
                if [ "$t" = "device" ]; then run_device "$list"; else run_network "$list"; fi
                ;;
        esac
        ;;
    *) err "Unknown filter type '$TYPE' (expected device or network)"; usage ;;
esac

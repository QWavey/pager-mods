#!/bin/bash
# clientip.sh - Find the IP address of a client connected to a Pineapple
# AP, by MAC. Wraps FIND_CLIENT_IP.
#
# Usage:
#   clientip.sh --mac AA:BB:CC:DD:EE:FF [--timeout SECONDS]
#   clientip.sh                interactive mode

set -u
TOOL_NAME="clientip.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

MAC=""; TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mac) need_arg "--mac" "$#"; MAC="$2"; shift 2 ;;
        --timeout) need_arg "--timeout" "$#"; TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

[ -z "$MAC" ] && MAC=$(ask "Client MAC address" "")
[ -z "$MAC" ] && die "A MAC address is required."
# BUG FOUND AND FIXED (found via code review): the raw MAC was passed
# straight to FIND_CLIENT_IP with no format check - a typo'd MAC would
# just silently return no IP, indistinguishable from "not connected". Use
# the same is_valid_mac check the rest of the toolkit already relies on
# for exactly this.
is_valid_mac "$MAC" || die "'$MAC' doesn't look like a valid MAC address (expected AA:BB:CC:DD:EE:FF)."

if [ -n "$TIMEOUT" ]; then
    ip=$(FIND_CLIENT_IP "$MAC" "$TIMEOUT")
else
    ip=$(FIND_CLIENT_IP "$MAC")
fi

if [ -n "$ip" ]; then
    say "$MAC -> $ip"
else
    die "No IP found for $MAC (client may not be connected, or hasn't gotten a lease yet)."
fi

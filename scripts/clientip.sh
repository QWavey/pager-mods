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

# BUG FOUND AND FIXED (found via code review - the same gap fixed in
# connect.sh's --timeout, which wraps a sibling command with the identical
# unvalidated pattern; matches the established convention elsewhere in this
# codebase, e.g. sniff.sh's "[ -n "$DURATION" ] && case ... *[!0-9]*"
# guard for an optional numeric flag). --timeout here is optional (empty
# means "let FIND_CLIENT_IP use its own default"), so only validate it when
# actually given. Verified with a standalone snippet: "abc"/"-5"/"12abc"
# are rejected while a bare number passes. Without this, a typo'd
# `--timeout 3o` was handed straight to FIND_CLIENT_IP; whatever it does
# with a garbage value (fail fast, misinterpret it, or silently fall back)
# would look identical to "client not connected yet" - the exact
# "indistinguishable failure" class this toolkit's numeric-arg convention
# exists to prevent.
[ -n "$TIMEOUT" ] && case "$TIMEOUT" in
    *[!0-9]*) die "'--timeout' needs a whole number of seconds (got '$TIMEOUT')." ;;
esac

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

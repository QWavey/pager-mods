#!/bin/bash
# dnsspoof.sh - Manipulate DNS given to clients of the Pineapple APs. Wraps
# DNSSPOOF_ENABLE/_DISABLE/_ADD_HOST/_DEL_HOST/_CLEAR.
#
# Usage:
#   dnsspoof.sh --on
#   dnsspoof.sh --off
#   dnsspoof.sh --add example.com 10.0.0.5
#   dnsspoof.sh --del example.com
#   dnsspoof.sh --clear [-y]
#   dnsspoof.sh                interactive mode

set -u
TOOL_NAME="dnsspoof.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class as loot.sh/
# ssidpool.sh/autossh.sh): this file never defined a -y/--yes flag despite
# --clear being gated behind confirm() - could never be scripted. Filtered
# OUT of "$@" entirely (not just detected) so it can never accidentally
# land as a positional HOST/IP argument to --add/--del.
# IMPROVEMENT (DRY): this scan used to be a locally hand-maintained copy;
# now shared via lib/common.sh's filter_yes_args() - see its comment there.
filter_yes_args "$@"
set -- "${FILTERED_ARGS[@]}"

# BUG FOUND AND FIXED (same class as dns.sh's own fix): every CLI branch
# ran its DNSSPOOF_* command and then printed a success message
# unconditionally, regardless of whether the command actually succeeded.
# Check the real exit code instead of assuming it.
#
# BUG FOUND AND FIXED (bug-hunt pass, verified with a standalone repro of
# this exact confirm()/&&/{} shape): both --clear here and interactive
# choice 5 below were `confirm "..." && { CMD && say ... || die/err ...; }`
# with NO fallback for the case where confirm() itself returns nonzero -
# i.e. the user answers anything but y/Y/yes/YES, OR (more importantly for
# a script meant to be automatable, per this file's own -y flag) a
# non-interactive caller invokes --clear without -y: `read` on a closed/
# non-tty stdin fails immediately, confirm() returns 1 the same as an
# explicit "no", and the whole `confirm && {...}` expression short-circuits
# with ZERO output - no say, no err/die, nothing - while still exiting
# nonzero. Reproduced standalone (same confirm()/say()/die() bodies as
# this file, invoked with stdin redirected from /dev/null exactly like a
# cron/automation caller that forgot -y would see): the statement produced
# no output at all and only its own bare exit code revealed anything went
# differently than expected. filters.sh's own "clear" and ssidpool.sh's
# CLI "clear" already end their confirm chain in an explicit `|| die
# "Aborted."`; this file's --clear (and its interactive twin) were missing
# that same fallback, silently swallowing exactly the failure class this
# codebase has been fixing everywhere else in this pass.
case "${1:-}" in
    --on) DNSSPOOF_ENABLE && say "DNS spoofing on." || die "Failed to enable DNS spoofing." ;;
    --off) DNSSPOOF_DISABLE && say "DNS spoofing off." || die "Failed to disable DNS spoofing." ;;
    --add) shift; [ $# -lt 2 ] && die "--add needs HOST and IP"; DNSSPOOF_ADD_HOST "$1" "$2" && say "Added $1 -> $2" || die "Failed to add $1 -> $2" ;;
    --del) shift; [ $# -lt 1 ] && die "--del needs a HOST"; DNSSPOOF_DEL_HOST "$1" && say "Removed $1" || die "Failed to remove $1" ;;
    --clear) confirm "Clear all DNS spoof entries?" && { DNSSPOOF_CLEAR && say "Cleared." || die "Failed to clear DNS spoof entries."; } || die "Aborted." ;;
    -h|--help) usage ;;
    "")
        echo "== dnsspoof.sh =="
        echo "1) Turn on  2) Turn off  3) Add host  4) Remove host  5) Clear all"
        c=$(ask "Choose" "1")
        case "$c" in
            1) DNSSPOOF_ENABLE && say "DNS spoofing on." || err "Failed to enable DNS spoofing." ;;
            2) DNSSPOOF_DISABLE && say "DNS spoofing off." || err "Failed to disable DNS spoofing." ;;
            3) h=$(ask "Hostname" ""); i=$(ask "IP to resolve it to" ""); DNSSPOOF_ADD_HOST "$h" "$i" && say "Added $h -> $i" || err "Failed to add $h -> $i" ;;
            4) h=$(ask "Hostname to remove" ""); DNSSPOOF_DEL_HOST "$h" && say "Removed $h" || err "Failed to remove $h" ;;
            5) confirm "Clear all entries?" && { DNSSPOOF_CLEAR && say "Cleared." || err "Failed to clear DNS spoof entries."; } || err "Aborted." ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

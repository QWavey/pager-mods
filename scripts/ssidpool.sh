#!/bin/bash
# ssidpool.sh - Manage the PineAP SSID impersonation pool. Wraps
# PINEAPPLE_SSID_POOL_ADD / LIST / DELETE / CLEAR / START / STOP /
# COLLECT_START / COLLECT_STOP.
#
# Usage:
#   ssidpool.sh add "SSID" ["SSID2" ...]
#   ssidpool.sh delete "SSID" ["SSID2" ...]
#   ssidpool.sh list
#   ssidpool.sh clear [-y]
#   ssidpool.sh --on [random]      start advertising the pool (optional random BSSID)
#   ssidpool.sh --off                stop advertising
#   ssidpool.sh --collect on|off       auto-collect probed SSIDs into the pool
#   ssidpool.sh                          interactive mode

set -u
TOOL_NAME="ssidpool.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review): this file never defined a
# -y/--yes flag, unlike every other script with a confirm() gate on a CLI
# action - `ssidpool.sh clear` could never be automated/scripted, always
# blocking on an interactive prompt with no bypass. confirm() already
# respects ASSUME_YES (lib/common.sh) - filtered OUT of "$@" entirely
# (not just detected) so it can never accidentally become a literal SSID
# argument to add/delete (which take a variable-length "$@" of their own
# and never needed -y to begin with).
# IMPROVEMENT (DRY): this scan used to be a locally hand-maintained copy;
# now shared via lib/common.sh's filter_yes_args() - see its comment there.
filter_yes_args "$@"
set -- "${FILTERED_ARGS[@]}"

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh):
# --on/--off/--collect printed a success message unconditionally
# regardless of the underlying PINEAPPLE_SSID_POOL_* command's real exit
# code.
# BIG CHANGE (found via code review while looking at this file): despite
# this file's own header comment claiming the "unconditional success"
# class was already fixed throughout, these three CLI-flag-less cases
# (add/delete/clear) were actually MISSED - the exact same gap the comment
# claims doesn't exist here anymore, still present in the three actions
# that don't start with "--". Brought in line with --on/--off/--collect
# and the interactive block's own choices 2-4, which all already check.
case "${1:-}" in
    add) shift; [ $# -eq 0 ] && die "add needs at least one SSID"; PINEAPPLE_SSID_POOL_ADD "$@" && say "Added." || die "Failed to add: $*" ;;
    delete) shift; [ $# -eq 0 ] && die "delete needs at least one SSID"; PINEAPPLE_SSID_POOL_DELETE "$@" && say "Deleted." || die "Failed to delete: $*" ;;
    list) PINEAPPLE_SSID_POOL_LIST ;;
    clear) if confirm "Clear the entire SSID pool?"; then PINEAPPLE_SSID_POOL_CLEAR && say "Cleared." || die "Failed to clear the pool."; else die "Aborted."; fi ;;
    --on)
        { if [ "${2:-}" = "random" ]; then PINEAPPLE_SSID_POOL_START random; else PINEAPPLE_SSID_POOL_START; fi; } \
            && say "Advertising started." || die "Failed to start advertising."
        ;;
    --off) PINEAPPLE_SSID_POOL_STOP && say "Advertising stopped." || die "Failed to stop advertising." ;;
    --collect)
        case "${2:-}" in
            on) PINEAPPLE_SSID_POOL_COLLECT_START && say "Probe collection on." || die "Failed to start probe collection." ;;
            off) PINEAPPLE_SSID_POOL_COLLECT_STOP && say "Probe collection off." || die "Failed to stop probe collection." ;;
            *) die "--collect expects on/off" ;;
        esac
        ;;
    -h|--help) usage ;;
    "")
        # CONSISTENCY FIX (found via code review - same gap already fixed
        # for --on/--off/--collect above, missed throughout this entire
        # interactive block: none of choices 2-7 checked success/failure
        # at all).
        echo "== ssidpool.sh interactive =="
        echo "1) List pool  2) Add SSID  3) Delete SSID  4) Clear pool"
        echo "5) Start advertising  6) Stop advertising  7) Toggle probe collection"
        c=$(ask "Choose" "1")
        case "$c" in
            1) PINEAPPLE_SSID_POOL_LIST ;;
            # BUG FOUND AND FIXED (bug-hunt pass): choices 2/3 called
            # PINEAPPLE_SSID_POOL_ADD/DELETE with whatever ask() returned,
            # including an empty string if the user just hit Enter with no
            # input - unlike this same file's own CLI `add`/`delete` cases
            # above, which explicitly `die` on `[ $# -eq 0 ]` before ever
            # calling the underlying command. Interactive mode had no
            # equivalent guard, so a blank prompt response would silently
            # attempt to add/delete an empty-string SSID instead of telling
            # the user to actually type one - same class of gap as
            # config.sh's own `[ -z "$SET_KEY" ] && die ...` guards on its
            # ask()'d input. Verified by reading ask(): with a blank
            # `default` argument (both calls here pass ""), pressing Enter
            # returns an empty string, not a re-prompt.
            2) s=$(ask "SSID to add" ""); [ -z "$s" ] && err "SSID cannot be empty." || { PINEAPPLE_SSID_POOL_ADD "$s" && say "Added." || err "Failed to add '$s'."; } ;;
            3) s=$(ask "SSID to delete" ""); [ -z "$s" ] && err "SSID cannot be empty." || { PINEAPPLE_SSID_POOL_DELETE "$s" && say "Deleted." || err "Failed to delete '$s'."; } ;;
            # BUG FOUND AND FIXED (bug-hunt pass, verified with a standalone
            # repro of this exact `confirm && {...}` shape piped "n"): unlike
            # this file's own CLI `clear` case above (an explicit if/else)
            # and dnsspoof.sh's already-fixed --clear/choice-5 (both end
            # their confirm chain in `|| err/die "Aborted."`), this
            # interactive choice 4 had no fallback for confirm() returning
            # nonzero - answering anything but y/Y/yes/YES to "Clear the
            # entire pool?" made the whole `confirm && {...}` expression
            # short-circuit with ZERO output: no "Cleared.", no "Aborted.",
            # nothing, leaving the user unsure whether their "no" even
            # registered. Repro: piping "n" into the exact same
            # confirm()/say()/err() shape printed nothing but a nonzero exit
            # code. Added the same `|| err "Aborted."` fallback dnsspoof.sh
            # already uses for the identical pattern.
            4) confirm "Clear the entire pool?" && { PINEAPPLE_SSID_POOL_CLEAR && say "Cleared." || err "Failed to clear the pool."; } || err "Aborted." ;;
            5) r=$(ask "Random BSSID per SSID? (y/N)" "N"); case "$r" in
                   y|Y) PINEAPPLE_SSID_POOL_START random && say "Advertising started." || err "Failed to start advertising." ;;
                   *) PINEAPPLE_SSID_POOL_START && say "Advertising started." || err "Failed to start advertising." ;;
               esac ;;
            6) PINEAPPLE_SSID_POOL_STOP && say "Advertising stopped." || err "Failed to stop advertising." ;;
            7) c2=$(ask "Collection on/off" "on"); case "$c2" in
                   on) PINEAPPLE_SSID_POOL_COLLECT_START && say "Probe collection on." || err "Failed to start probe collection." ;;
                   *) PINEAPPLE_SSID_POOL_COLLECT_STOP && say "Probe collection off." || err "Failed to stop probe collection." ;;
               esac ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

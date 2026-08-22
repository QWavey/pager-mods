#!/bin/bash
# reconsession.sh - Start a fresh recon session, and pause/resume channel
# hopping. Wraps PINEAPPLE_RECON_NEW / PINEAPPLE_HOPPING_START/STOP.
#
# Usage:
#   reconsession.sh --new [NAME]
#   reconsession.sh --pause
#   reconsession.sh --resume
#   reconsession.sh                interactive mode

set -u
TOOL_NAME="reconsession.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh): every branch here
# printed a success message unconditionally regardless of the underlying
# PINEAPPLE_* command's real exit code.
# BIG CHANGE (found via code review): --new starts a fresh recon session -
# by its own name, that means whatever recon data was accumulating under
# the OLD session stops being what's live/current. None of --new/--pause/
# --resume had any confirmation at all, but --new is the one of the three
# that's actually consequential (--pause/--resume are trivially reversible
# by just running the other one again) - added a confirm gate to --new
# specifically, matching how this toolkit treats other "starts a fresh
# thing, implicitly moves on from whatever was accumulating before" actions
# elsewhere (e.g. loot.sh's --archive).
case "${1:-}" in
    --new)
        shift
        if [ "$ASSUME_YES" != "1" ]; then
            confirm "Start a fresh recon session? Whatever was accumulating under the current one keeps existing in the database, but a new session becomes the active one." || die "Aborted."
        fi
        { if [ -n "${1:-}" ]; then PINEAPPLE_RECON_NEW "$1"; else PINEAPPLE_RECON_NEW; fi; } && say "New recon session started." || die "Failed to start a new recon session." ;;
    --pause) PINEAPPLE_HOPPING_STOP && say "Channel hopping paused." || die "Failed to pause channel hopping." ;;
    --resume) PINEAPPLE_HOPPING_START && say "Channel hopping resumed." || die "Failed to resume channel hopping." ;;
    -h|--help) usage ;;
    "")
        # CONSISTENCY FIX (found via code review - same gap already fixed
        # for --new/--pause/--resume above, missed here).
        echo "== reconsession.sh =="
        echo "1) Start a new recon session  2) Pause hopping  3) Resume hopping"
        c=$(ask "Choose" "3")
        case "$c" in
            1)
                if confirm "Start a fresh recon session? Whatever was accumulating under the current one keeps existing in the database, but a new session becomes the active one."; then
                    n=$(ask "Session name (blank for default)" "")
                    { if [ -n "$n" ]; then PINEAPPLE_RECON_NEW "$n"; else PINEAPPLE_RECON_NEW; fi; } \
                        && say "New recon session started." || err "Failed to start a new recon session."
                else
                    say "Aborted."
                fi
                ;;
            2) PINEAPPLE_HOPPING_STOP && say "Channel hopping paused." || err "Failed to pause channel hopping." ;;
            *) PINEAPPLE_HOPPING_START && say "Channel hopping resumed." || err "Failed to resume channel hopping." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

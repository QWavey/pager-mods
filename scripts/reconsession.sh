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
case "${1:-}" in
    --new) shift; { if [ -n "${1:-}" ]; then PINEAPPLE_RECON_NEW "$1"; else PINEAPPLE_RECON_NEW; fi; } && say "New recon session started." || die "Failed to start a new recon session." ;;
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
                n=$(ask "Session name (blank for default)" "")
                { if [ -n "$n" ]; then PINEAPPLE_RECON_NEW "$n"; else PINEAPPLE_RECON_NEW; fi; } \
                    && say "New recon session started." || err "Failed to start a new recon session."
                ;;
            2) PINEAPPLE_HOPPING_STOP && say "Channel hopping paused." || err "Failed to pause channel hopping." ;;
            *) PINEAPPLE_HOPPING_START && say "Channel hopping resumed." || err "Failed to resume channel hopping." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

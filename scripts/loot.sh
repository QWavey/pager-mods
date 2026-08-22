#!/bin/bash
# loot.sh - List and archive collected loot (handshakes, pcap, wigle logs).
# Wraps PINEAPPLE_LOOT_ARCHIVE; listing/download itself is just standard
# file access under /root/loot/ (also reachable via scp/sftp or the
# Virtual Pager's Download Loot button).
#
# Usage:
#   loot.sh --list          summarize what's in /root/loot
#   loot.sh --archive         archive current loot to a timestamped folder
#   loot.sh                     interactive mode

set -u
TOOL_NAME="loot.sh"
LOOT_ROOT="/root/loot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

do_list() {
    say "Loot summary ($LOOT_ROOT):"
    # BUG FOUND AND FIXED: this list was missing real loot directories
    # that other scripts in the toolkit actually write to (confirmed via
    # `grep -n "LOOT_DIR="` across scripts/*.sh) - sniff (sniff.sh/
    # pc_link.sh), bluetooth (bluetooth.sh), deadnet (deadnet.sh), and
    # reports (report.sh --save) were all silently absent from this
    # summary even when full of real captures.
    for d in handshakes pcap wigle lanscan payload-runs archive sniff bluetooth deadnet reports; do
        if [ -d "$LOOT_ROOT/$d" ]; then
            n=$(find "$LOOT_ROOT/$d" -type f 2>/dev/null | wc -l)
            echo "  $d: $n file(s)"
        fi
    done
}

# BUG FOUND AND FIXED (found via code review - same "silent on failure"
# class already fixed throughout this codebase, e.g. mimic.sh): both
# archive call sites below chained confirm && PINEAPPLE_LOOT_ARCHIVE &&
# say "Archived." with no `||` at all - if the user confirmed but
# PINEAPPLE_LOOT_ARCHIVE itself then failed, nothing was reported, same
# silent-failure gap. Restructured as an if/then so a declined confirm
# stays a silent no-op (that's a normal, expected outcome) while a real
# command failure after confirming now gets a clear error.
case "${1:-}" in
    --list) do_list ;;
    --archive)
        if confirm "Archive all current loot to a timestamped folder under $LOOT_ROOT/archive/?"; then
            PINEAPPLE_LOOT_ARCHIVE && say "Archived." || die "Failed to archive loot."
        fi
        ;;
    -h|--help) usage ;;
    "")
        echo "== loot.sh =="
        do_list
        echo
        if confirm "Archive current loot now?"; then
            PINEAPPLE_LOOT_ARCHIVE && say "Archived." || err "Failed to archive loot."
        fi
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

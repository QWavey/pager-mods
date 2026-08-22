#!/bin/bash
# ringtone.sh - Play a ringtone (with optional vibration) or vibrate alone.
# Wraps the RINGTONE and VIBRATE DuckyScript commands.
#
# Confirmed syntax from the Hak5 docs:
#   RINGTONE {--vibrate} [rtttl-or-filename]
#   VIBRATE [rtttl-or-filename]
# Ringtone files are looked up in /root/ringtones/.
#
# Usage:
#   ringtone.sh --play NAME_OR_FILE [--vibrate]
#   ringtone.sh --vibrate-only NAME_OR_FILE
#   ringtone.sh --list          list ringtone files available under /root/ringtones/
#   ringtone.sh                interactive mode

set -u
TOOL_NAME="ringtone.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review - same "silent on failure"
# class already fixed throughout this codebase, e.g. mimic.sh/alert.sh):
# every branch called RINGTONE/VIBRATE with no success/failure check at
# all - a bad name/file (a typo, a ringtone that doesn't exist under
# /root/ringtones/) would fail silently with no indication anything went
# wrong, same gap as alert.sh's own fix: someone triggering this over SSH
# (an explicitly supported use here, not just standing next to the
# device) has no other way to know whether it actually played.
# BIG CHANGE (found via code review): this had --play/--vibrate-only but
# no way to discover what's actually available to play - a typo would just
# fail with "check the name/file exists", with no easy way to see what
# names actually do. `ls` straight against /root/ringtones/ instead of a
# platform command - there's no RINGTONE_LIST/similar in Hak5's docs, and
# this is just a normal directory listing, nothing fabricated.
RINGTONE_DIR="/root/ringtones"
case "${1:-}" in
    --list)
        if [ -d "$RINGTONE_DIR" ]; then
            say "Ringtones available in $RINGTONE_DIR:"
            ls -1 "$RINGTONE_DIR" 2>/dev/null
        else
            say "$RINGTONE_DIR doesn't exist yet - no ringtone files found."
        fi
        ;;
    --play)
        shift; [ $# -eq 0 ] && die "Give a ringtone name/file."
        name="$1"; shift
        if [ "${1:-}" = "--vibrate" ]; then RINGTONE --vibrate "$name" && say "Played." || die "Failed to play '$name' - check the name/file exists under /root/ringtones/."
        else RINGTONE "$name" && say "Played." || die "Failed to play '$name' - check the name/file exists under /root/ringtones/."
        fi
        ;;
    --vibrate-only) shift; [ $# -eq 0 ] && die "Give a ringtone name/file."; VIBRATE "$1" && say "Vibrated." || die "Failed to vibrate '$1' - check the name/file exists under /root/ringtones/." ;;
    -h|--help) usage ;;
    "")
        echo "== ringtone.sh =="
        if [ -d "$RINGTONE_DIR" ] && [ -n "$(ls -A "$RINGTONE_DIR" 2>/dev/null)" ]; then
            say "Available in $RINGTONE_DIR:"
            ls -1 "$RINGTONE_DIR" 2>/dev/null | sed 's/^/  /'
        fi
        n=$(ask "Ringtone name/file (looked up in /root/ringtones/)" "")
        v=$(ask "Vibrate too? (y/N)" "N")
        case "$v" in
            y|Y) RINGTONE --vibrate "$n" && say "Played." || err "Failed to play '$n' - check the name/file exists under /root/ringtones/." ;;
            *) RINGTONE "$n" && say "Played." || err "Failed to play '$n' - check the name/file exists under /root/ringtones/." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

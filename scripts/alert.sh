#!/bin/bash
# alert.sh - Send a message to the Pager's physical screen from SSH.
# Wraps ALERT / PROMPT / CONFIRMATION_DIALOG / ERROR_DIALOG (confirmed
# syntax from the Hak5 docs - each just takes a message string). These
# take over the screen and (for PROMPT/CONFIRMATION_DIALOG) block until
# the user responds on the device.
#
# NOTE: CONFIRMATION_DIALOG returns its yes/no answer via EXIT CODE (0 =
# yes, non-zero = no), not via printed output - the docs' own example is
# `CONFIRMATION_DIALOG "..." || { ... }`, checking $?, not $(...). This
# script checks the exit code accordingly.
#
# Usage:
#   alert.sh --alert "message"                full-screen alert + ringtone
#   alert.sh --prompt "message"                 modal, waits for dismissal
#   alert.sh --confirm "question"                 yes/no on-screen, prints the answer
#   alert.sh --error "message"                      error dialog
#   alert.sh                                          interactive mode

set -u
TOOL_NAME="alert.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

do_confirm() {
    local m="$1"
    if CONFIRMATION_DIALOG "$m"; then
        say "User answered: yes"
        return 0
    else
        say "User answered: no"
        return 1
    fi
}

# BUG FOUND AND FIXED (found via code review - same "silent on failure"
# class already fixed throughout this codebase, e.g. mimic.sh/wigle.sh):
# every branch here called ALERT/PROMPT/ERROR_DIALOG then printed
# "Sent."/"Dismissed." unconditionally, regardless of whether the command
# actually succeeded. This matters MORE here than in most of this
# toolkit's other scripts: this script's whole purpose is relaying a
# message to the physical screen FOR SOMEONE ON SSH WHO ISN'T STANDING IN
# FRONT OF THE DEVICE - unlike e.g. led.sh (where a failed LED change is
# immediately, physically obvious to whoever's looking at it), a remote
# operator here has NO other way to know whether the message actually
# reached the screen. An unconditional "Sent." on a real failure would
# genuinely mislead them into believing it worked.
case "${1:-}" in
    --alert) shift; [ $# -eq 0 ] && die "Give a message."; ALERT "$*" && say "Sent." || die "Failed to send the alert." ;;
    --prompt) shift; [ $# -eq 0 ] && die "Give a message."; PROMPT "$*" && say "Dismissed." || die "Failed to send the prompt." ;;
    --confirm) shift; [ $# -eq 0 ] && die "Give a question."; do_confirm "$*" ;;
    --error) shift; [ $# -eq 0 ] && die "Give a message."; ERROR_DIALOG "$*" && say "Sent." || die "Failed to send the error dialog." ;;
    -h|--help) usage ;;
    "")
        echo "== alert.sh =="
        echo "1) Alert  2) Prompt  3) Confirm  4) Error"
        c=$(ask "Choose" "1")
        m=$(ask "Message" "")
        case "$c" in
            1) ALERT "$m" && say "Sent." || err "Failed to send the alert." ;;
            2) PROMPT "$m" && say "Dismissed." || err "Failed to send the prompt." ;;
            3) do_confirm "$m" ;;
            4) ERROR_DIALOG "$m" && say "Sent." || err "Failed to send the error dialog." ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

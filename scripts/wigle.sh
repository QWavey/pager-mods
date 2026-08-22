#!/bin/bash
# wigle.sh - Wardriving log control + Wigle.net upload. Wraps WIGLE_LOGIN /
# WIGLE_LOGOUT / WIGLE_START / WIGLE_STOP / WIGLE_UPLOAD.
#
# Needs a GPS lock to produce non-empty logs, and an internet connection
# for login/upload. Hak5 is not affiliated with Wigle - see wigle.net/eula.html.
#
# Usage:
#   wigle.sh --login [user] [pass]     (blank = interactive Wigle login prompt)
#   wigle.sh --logout
#   wigle.sh --start
#   wigle.sh --stop
#   wigle.sh --upload [--archive] [--remove] FILE [FILE2 ...]
#   wigle.sh                             interactive mode

set -u
TOOL_NAME="wigle.sh"
LOOT_DIR="/root/loot/wigle"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh/
# ssidpool.sh/screen.sh/vpn.sh): --logout/--start/--stop printed a success
# message unconditionally regardless of the underlying WIGLE_* command's
# real exit code.
case "${1:-}" in
    # BUG FOUND AND FIXED (found via code review): this CLI path had NO
    # success/failure check at all, unlike its own interactive-menu
    # counterpart below (choice 1) which already checks WIGLE_LOGIN's exit
    # code - the CLI form (the one actually meant to be scripted) was the
    # one silently swallowing a failed login.
    --login) shift; if [ $# -ge 2 ]; then WIGLE_LOGIN "$1" "$2"; else WIGLE_LOGIN; fi || die "Wigle login failed." ;;
    --logout) WIGLE_LOGOUT && say "Logged out of Wigle." || die "Failed to log out of Wigle." ;;
    --start) f=$(WIGLE_START) && say "Wigle log started: ${f:-see $LOOT_DIR}" || die "Failed to start the Wigle log." ;;
    # BUG FOUND AND FIXED (same class found and fixed across reset.sh/
    # deauth.sh/bluetooth.sh/EvilTwin.sh this session): WIGLE_STOP had no
    # timeout - `timeout 10` preserves the existing &&/|| exit-code check
    # (a timeout's own nonzero exit correctly falls through to `die`)
    # while guaranteeing --stop itself can never hang.
    --stop) timeout 10 WIGLE_STOP && say "Wigle log stopped." || die "Failed to stop the Wigle log." ;;
    --upload)
        shift
        ARGS=""
        while [ "${1:-}" = "--archive" ] || [ "${1:-}" = "--remove" ]; do ARGS="$ARGS $1"; shift; done
        [ $# -eq 0 ] && die "Give at least one file to upload, e.g. $LOOT_DIR/*"
        # IMPROVEMENT (round 1, genuine improvement pass - not a bug hunt):
        # a typo'd/nonexistent file path used to sail straight through to
        # WIGLE_UPLOAD, and the only failure message available afterwards
        # was the generic "check network connectivity and Wigle login" -
        # actively misleading for what's actually just a bad local path
        # (nothing wrong with the network or the login at all). Checking
        # locally first costs nothing (no network round-trip needed to
        # discover a typo) and turns a misdiagnosed network/auth problem
        # into an immediate, specific "which file(s) don't exist" answer.
        # This also covers the unquoted-glob-with-no-match case (e.g.
        # `wigle.sh --upload $LOOT_DIR/*` when the directory is empty) -
        # the shell passes the literal unexpanded glob string through, and
        # that's exactly the kind of path this check reports as not found.
        _missing=""
        for _f in "$@"; do
            [ -e "$_f" ] || _missing="$_missing '$_f'"
        done
        [ -n "$_missing" ] && die "File(s) not found, nothing uploaded:$_missing"
        # shellcheck disable=SC2086
        WIGLE_UPLOAD $ARGS "$@" && say "Upload finished." || die "Upload failed - check network connectivity and Wigle login (wigle.sh --login)."
        ;;
    -h|--help) usage ;;
    "")
        echo "== wigle.sh =="
        echo "1) Login  2) Logout  3) Start log  4) Stop log  5) Upload all logs"
        c=$(ask "Choose" "3")
        case "$c" in
            # CONSISTENCY FIX (found via code review - same "unconditional
            # success" bug class this file's own header already documents
            # fixing for the CLI --logout/--start/--stop, missed here in
            # the interactive menu's Login/Logout choices, which gave NO
            # feedback either way - not even the bare command's own exit
            # code was checked). WIGLE_LOGIN prompts interactively when
            # called with no args (per its own --login usage above), so it
            # doesn't need a success message on top of that, but a real
            # failure (bad credentials, no network) deserves a clear err()
            # like every other choice in this same menu gets.
            1) WIGLE_LOGIN || err "Wigle login failed." ;;
            2) WIGLE_LOGOUT && say "Logged out of Wigle." || err "Failed to log out of Wigle." ;;
            3) f=$(WIGLE_START) && say "Started: ${f:-see $LOOT_DIR}" || err "Failed to start the Wigle log." ;;
            # BIG CHANGE (found via code review): this was the one choice
            # in this whole menu still missing BOTH the timeout (WIGLE_STOP
            # has no timeout of its own - same hang risk already fixed for
            # the CLI --stop path right above) and any success/failure
            # feedback at all - a silent no-op either way.
            4) timeout 10 WIGLE_STOP && say "Wigle log stopped." || err "Failed to stop the Wigle log." ;;
            5)
                # BUG FOUND AND FIXED (found via code review): if $LOOT_DIR
                # doesn't exist yet or is empty, the "$LOOT_DIR"/* glob
                # doesn't match anything and bash passes the literal
                # unexpanded string "$LOOT_DIR/*" straight to WIGLE_UPLOAD,
                # which would try to upload a nonexistent file named "*"
                # instead of failing with a clear message.
                # BUG FOUND AND FIXED (found via code review, same
                # "unconditional/no success feedback" class this file's own
                # header already documents fixing everywhere else - missed
                # in this one interactive choice, the exact call this
                # script exists for. WIGLE_UPLOAD's real exit code was
                # silently discarded here, unlike the CLI --upload path
                # right above which already checks it.
                if ! ls "$LOOT_DIR"/* >/dev/null 2>&1; then
                    say "No files in $LOOT_DIR to upload."
                elif confirm "Upload all files in $LOOT_DIR ?"; then
                    WIGLE_UPLOAD "$LOOT_DIR"/* && say "Upload finished." || err "Upload failed - check network connectivity and Wigle login (wigle.sh --login)."
                fi
                ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

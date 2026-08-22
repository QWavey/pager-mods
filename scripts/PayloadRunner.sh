#!/bin/bash
#
# PayloadRunner.sh - Dynamic launcher for the WiFi Pineapple Pager's real
#                    payload system (bash + Hak5 DuckyScript commands).
#
# IMPORTANT: The Pager has NO keyboard-injection / HID capability - Hak5's
# own docs are explicit: "The WiFi Pineapple Pager is not a keyboard
# injection device... inject commands from the USB Rubber Ducky will not
# work." Its DuckyScript is a Pager-specific command set for the screen,
# WiFi, and PineAP - not for typing into a target computer. This script
# runs THAT system (the one that actually exists on this hardware):
# payload.sh scripts under /root/payloads/{user,alerts,recon}/.
#
# Payloads run standalone fine over SSH (confirmed by testing) - any
# on-screen commands they use (ALERT, PROMPT, LOG, etc.) will drive the
# physical Pager screen exactly as if launched from the dashboard.
#
# Usage:
#   PayloadRunner.sh                          interactive picker
#   PayloadRunner.sh --list [--category CAT]
#   PayloadRunner.sh --run CATEGORY/NAME [options]
#
# Options:
#   --list                       List available payloads (with descriptions)
#   --category user|alerts|recon   Restrict listing/picking to one category
#   --run CATEGORY/NAME            Run a specific payload non-interactively
#   --timeout SECONDS               Kill the payload if it runs longer than this
#                                    (useful for headless runs - some payloads use
#                                    WAIT_FOR_BUTTON_PRESS and need a person present)
#   --background                     Launch and detach, logging to /root/loot/payload-runs/
#   --status                          Is a backgrounded payload still running, and which one
#   --stop                             Stop the currently backgrounded payload
#   -y, --yes                        Don't prompt for confirmation
#   -h, --help                        This help

set -u
TOOL_NAME="PayloadRunner.sh"
PAYLOAD_ROOT="/root/payloads"
LOG_DIR="/root/loot/payload-runs"
CATEGORIES="user alerts recon"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

# BIG CHANGE: every other long-running thing in this toolkit (deauth.sh,
# sniff.sh, bluetooth.sh, ...) tracks its background PID and offers
# --status/--stop - this script, the actual GENERIC payload launcher, had
# neither. Backgrounding a payload here used to mean the PID printed once at
# launch was the ONLY record of it - walk away, lose that terminal output,
# and there was no way left to check whether it was still running or to
# stop it without manually grepping `ps` for the process. Same PIDFILE +
# pid_running() pattern (from common.sh) every other backgrounded thing
# here already uses, so a backgrounded payload is finally a first-class,
# manageable thing instead of a fire-and-forget PID you have to remember.
PIDFILE="/tmp/pager-payloadrunner.pid"
NAMEFILE="/tmp/pager-payloadrunner.name"
is_running() { pid_running "$PIDFILE"; }

DO_LIST=0
DO_STATUS=0
DO_STOP=0
CATEGORY=""
RUN_TARGET=""
TIMEOUT=""
BACKGROUND=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) DO_LIST=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --category) [ $# -lt 2 ] && die "--category needs a value"; CATEGORY="$2"; shift 2 ;;
        --run) [ $# -lt 2 ] && die "--run needs a value (CATEGORY/NAME)"; RUN_TARGET="$2"; shift 2 ;;
        --timeout) [ $# -lt 2 ] && die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE")): $(cat "$NAMEFILE" 2>/dev/null || echo "unknown payload")"
    else
        say "Not running."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        say "Stopped $(cat "$NAMEFILE" 2>/dev/null || echo "backgrounded payload") (PID $(cat "$PIDFILE"))."
    else
        say "Nothing running."
    fi
    rm -f "$PIDFILE" "$NAMEFILE"
    exit 0
fi

payload_meta() {
    # payload_meta payload.sh field  -> prints "# Title: xyz" style header value
    local file="$1" field="$2"
    grep -m1 -i "^#[[:space:]]*${field}:" "$file" 2>/dev/null | sed -E "s/^#[[:space:]]*${field}:[[:space:]]*//I"
}

list_payloads() {
    local cats="$CATEGORIES"
    [ -n "$CATEGORY" ] && cats="$CATEGORY"
    local i=0
    for cat in $cats; do
        [ -d "$PAYLOAD_ROOT/$cat" ] || continue
        echo
        echo "== $cat =="
        while IFS= read -r payload_sh; do
            [ -f "$payload_sh" ] || continue
            local dir name title desc
            dir=$(dirname "$payload_sh")
            name=$(basename "$dir")
            sub=$(basename "$(dirname "$dir")")
            title=$(payload_meta "$payload_sh" "Title")
            desc=$(payload_meta "$payload_sh" "Description")
            i=$((i+1))
            printf "  %2d) %-12s %-30s %s\n" "$i" "$cat" "$name" "${title:-$desc}"
        done < <(find "$PAYLOAD_ROOT/$cat" -mindepth 2 -maxdepth 6 -name payload.sh | sort)
    done
}

find_payload_dir() {
    # find_payload_dir "category/name" -> echoes full dir path, or nothing.
    # If no "category/" prefix is given, search every category by name instead.
    local target="$1" found
    case "$target" in
        */*)
            local cat="${target%%/*}"
            local name="${target#*/}"
            find "$PAYLOAD_ROOT/$cat" -mindepth 1 -maxdepth 6 -type d -iname "$name" 2>/dev/null | head -1
            ;;
        *)
            for cat in $CATEGORIES; do
                found=$(find "$PAYLOAD_ROOT/$cat" -mindepth 1 -maxdepth 6 -type d -iname "$target" 2>/dev/null | head -1)
                if [ -n "$found" ]; then echo "$found"; return 0; fi
            done
            ;;
    esac
}

run_payload() {
    local dir="$1"
    local sh="$dir/payload.sh"
    [ -f "$sh" ] || die "No payload.sh found in $dir"

    local title desc author
    title=$(payload_meta "$sh" "Title")
    desc=$(payload_meta "$sh" "Description")
    author=$(payload_meta "$sh" "Author")

    say "Payload: ${title:-$(basename "$dir")}"
    [ -n "$desc" ] && say "Description: $desc"
    [ -n "$author" ] && say "Author: $author"
    say "Path: $sh"

    confirm "Run this payload?" || { say "Aborted."; return 1; }

    mkdir -p "$LOG_DIR"
    local stamp logfile
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)
    logfile="$LOG_DIR/$(basename "$dir")-$stamp.log"

    local cmd=(env PAYLOAD_HOME="$dir" bash "$sh")
    if [ -n "$TIMEOUT" ]; then
        cmd=(timeout "$TIMEOUT" "${cmd[@]}")
    fi

    if [ "$BACKGROUND" = "1" ]; then
        # BIG CHANGE (see PIDFILE/is_running above): only one backgrounded
        # payload is tracked at a time - same single-instance convention
        # deauth.sh/sniff.sh already use, refuse a second one rather than
        # silently losing track of the first (its PIDFILE would just get
        # overwritten, and --stop/--status would only ever see the newest).
        is_running && die "A backgrounded payload is already running ($(cat "$NAMEFILE" 2>/dev/null), PID $(cat "$PIDFILE")). Use --stop first."
        say "Launching in background, logging to $logfile"
        # No `nohup` binary on this busybox build - ignore SIGHUP in a
        # subshell instead, which needs no external command at all.
        ( trap '' HUP; exec "${cmd[@]}" ) >"$logfile" 2>&1 &
        local bgpid=$!
        # BUG FOUND AND FIXED (same class as wifi_deauth/payload.sh's own
        # fix, "verify via --status before declaring success"): this used
        # to print "Started (PID ...)" unconditionally right after
        # backgrounding, with no check the launch actually survived - `&`
        # always returns a PID immediately whether or not the command
        # inside goes on to fail right away (a bad --timeout value, a
        # payload.sh with a syntax error, a bad PAYLOAD_HOME, etc. all
        # exit near-instantly). A brief liveness check tells the truth
        # instead of reporting success on a process that's already gone.
        sleep 1
        if kill -0 "$bgpid" 2>/dev/null; then
            echo "$bgpid" > "$PIDFILE"
            echo "${title:-$(basename "$dir")}" > "$NAMEFILE"
            say "Started (PID $bgpid). Use --status/--stop to check on or end it."
        else
            err "Payload exited immediately - see $logfile for why (check for a bad --timeout value or an error in payload.sh)."
            return 1
        fi
    else
        say "Running (output also saved to $logfile)..."
        "${cmd[@]}" 2>&1 | tee "$logfile"
        return "${PIPESTATUS[0]}"
    fi
}

if [ "$DO_LIST" = "1" ]; then
    list_payloads
    exit 0
fi

if [ -n "$RUN_TARGET" ]; then
    dir=$(find_payload_dir "$RUN_TARGET")
    [ -z "$dir" ] && die "Payload '$RUN_TARGET' not found (searched by name across categories if you didn't give CATEGORY/NAME). Use --list to see available payloads."
    run_payload "$dir"
    exit $?
fi

# Interactive picker
echo "== PayloadRunner.sh =="
echo "No payload specified - listing available payloads:"
declare -a PATHS
i=0
cats="$CATEGORIES"
if confirm "Restrict to one category (user/alerts/recon)? (No = show all)"; then
    CATEGORY=$(ask "Category" "user")
    cats="$CATEGORY"
fi

for cat in $cats; do
    [ -d "$PAYLOAD_ROOT/$cat" ] || continue
    echo
    echo "== $cat =="
    while IFS= read -r payload_sh; do
        [ -f "$payload_sh" ] || continue
        dir=$(dirname "$payload_sh")
        name=$(basename "$dir")
        title=$(payload_meta "$payload_sh" "Title")
        desc=$(payload_meta "$payload_sh" "Description")
        i=$((i+1))
        PATHS[$i]="$dir"
        printf "  %2d) %-30s %s\n" "$i" "$name" "${title:-$desc}"
    done < <(find "$PAYLOAD_ROOT/$cat" -mindepth 2 -maxdepth 6 -name payload.sh | sort)
done

[ "$i" -eq 0 ] && die "No payloads found."

echo
choice=$(ask "Pick a payload number (or 0 to cancel)" "0")
[ "$choice" = "0" ] && { say "Cancelled."; exit 0; }
# BUG FOUND AND FIXED (found via code review): a non-numeric answer (a
# typo, or just hitting enter past a blank prompt) went straight into
# ${PATHS[$choice]} as an array subscript. Bash evaluates a non-numeric
# subscript as an arithmetic expression, which errors out ("bad array
# subscript") instead of giving the intended clean "Invalid selection."
# Validate it's a plain positive integer first.
case "$choice" in
    ''|*[!0-9]*) die "Invalid selection." ;;
esac
[ -z "${PATHS[$choice]:-}" ] && die "Invalid selection."

if confirm "Run this in the background instead of the foreground?"; then
    BACKGROUND=1
fi
if confirm "Set a timeout in case it waits for physical button input?"; then
    TIMEOUT=$(ask "Timeout in seconds" "60")
fi

run_payload "${PATHS[$choice]}"

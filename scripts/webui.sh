#!/bin/bash
# webui.sh - Start/stop the Pager Control Panel (a local web dashboard for
# the scripts in this toolkit). Binds ONLY to br-lan (Management WiFi /
# USB-C) - never the internet-facing uplink - same access model the Hak5
# Virtual Pager itself uses.
#
# Usage:
#   webui.sh --start [--port PORT]     start the server (default port 8081)
#   webui.sh --stop                       stop it
#   webui.sh --status                       is it running?
#   webui.sh --set-token [TOKEN]              set/rotate the access token
#                                                (required before first use -
#                                                 blank = generate a random one)
#   webui.sh                                    interactive mode

set -u
TOOL_NAME="webui.sh"
CFG_NS="webui"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

PIDFILE="/tmp/pager-webui.pid"
PORT=8081
DO_START=0; DO_STOP=0; DO_STATUS=0; DO_TOKEN=0; TOKEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --start) DO_START=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        --port) need_arg "--port" "$#"; PORT="$2"; shift 2 ;;
        --set-token) DO_TOKEN=1; shift; if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then TOKEN="$1"; shift; fi ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

if [ "$DO_TOKEN" = "1" ]; then
    if [ -z "$TOKEN" ]; then
        TOKEN=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
        [ -z "$TOKEN" ] && TOKEN=$(echo "$RANDOM$(date +%s)$$" | md5sum | cut -c1-32)
    fi
    cfg_set token "$TOKEN"
    say "Token set. Use it as ?token=$TOKEN or header X-Pager-Token: $TOKEN"
    exit 0
fi

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE")) on http://172.16.52.1:$PORT"
    else
        say "Not running."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
        say "Stopped."
    else
        say "Not running."
    fi
    exit 0
fi

INTERACTIVE=0
[ "$DO_START" = "0" ] && [ "$DO_STOP" = "0" ] && [ "$DO_STATUS" = "0" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== webui.sh =="
    if is_running; then
        say "Currently running on port $PORT."
        confirm "Stop it?" && DO_STOP=1
    else
        confirm "Start the control panel now?" && DO_START=1
    fi
    if [ "$DO_STOP" = "1" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; say "Stopped."
        exit 0
    fi
fi

if [ "$DO_START" = "1" ]; then
    if [ -z "$(cfg_get token)" ]; then
        die "No access token set yet. Run: webui.sh --set-token   (then reload the page with ?token=... once)"
    fi
    if is_running; then
        die "Already running (PID $(cat "$PIDFILE")). Use --stop first."
    fi
    PY=$(resolve_python3) || die "python3 is not installed. Install it with: opkg update && opkg install -d mmc python3"
    # No `nohup` binary on this busybox build - ignore SIGHUP in a subshell
    # instead, which needs no external command at all.
    # shellcheck disable=SC2086
    ( trap '' HUP; exec $PY "$SCRIPT_DIR/guiserver/server.py" "$PORT" ) >/tmp/pager-webui.log 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if is_running; then
        say "Started (PID $(cat "$PIDFILE")) on http://172.16.52.1:$PORT"
        say "Open it from a device on Management WiFi or USB-C, with your token."
    else
        die "Failed to start - check /tmp/pager-webui.log"
    fi
fi

exit 0

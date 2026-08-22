#!/bin/bash
# tracer.sh - Live, continuously-scrolling packet trace ("wireshark-like" -
# you watch traffic go by AS IT HAPPENS, not capture-then-review). Wraps
# the standard tcpdump (not Hak5-specific, but pre-installed) in line-
# buffered live mode. Different tool than sniff.sh on purpose: sniff.sh's
# whole design is capture-to-a-file-then-summarize; this is the opposite -
# nothing saved by default, just a live firehose to the screen, for "what
# is going on right now" instead of "what happened, tell me after".
#
# Three trace targets:
#   --wifi     Your OWN WiFi connection's traffic (the wlan0cli client
#                interface - present only once actually associated to a
#                network via WIFI_CONNECT/wifi.sh). Requires being
#                connected - if you're not, this errors clearly instead of
#                silently doing nothing or capturing nothing useful.
#   --lan        Wired LAN traffic (USB-A external adapter by default, same
#                  as sniff.sh - eth0 is the USB-C management/SSH link, so
#                  tracing it live mostly just shows your own SSH session).
#   --monitor    Passive 802.11 monitoring (wlan1mon/wlan0mon) - sees
#                  nearby WiFi frames over the air, same interfaces recon
#                  uses. Does NOT require being connected to anything (this
#                  is literally what recon watches to build its device
#                  list) - it's the one mode where "not connected" is not
#                  an error condition.
#
# Usage:
#   tracer.sh --wifi [--filter EXPR]
#   tracer.sh --lan [--iface IFACE] [--filter EXPR]
#   tracer.sh --monitor [--iface wlan0mon|wlan1mon]
#   tracer.sh --background (with one of the above)   trace detached to a log
#   tracer.sh --status
#   tracer.sh --stop
#   tracer.sh                interactive mode
#
# Options:
#   --wifi                 Trace this device's own WiFi client connection
#   --lan                    Trace wired LAN traffic
#   --monitor                  Passively watch nearby 802.11 traffic (no connection needed)
#   --iface IFACE                Interface override (--lan/--monitor only)
#   --filter EXPR                  Raw tcpdump/BPF filter, e.g. "port 80 or port 443"
#   --save FILE                      Also write a .pcap alongside the live view (default: not saved)
#   --background                       Trace detached - use --status/--stop to manage it
#   --status                             Is a background trace currently running?
#   --stop                                 Stop a background trace
#   -h, --help                               This help
#
# Not connected / no target and asked for --wifi -> clear error, exits
# non-zero, no silent no-op. Same honesty as the rest of this toolkit: a
# tool that "succeeds" while doing nothing is worse than one that says so.

set -u
TOOL_NAME="tracer.sh"
PIDFILE="/tmp/pager-tracer.pid"
LOGFILE="/tmp/pager-tracer.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

MODE=""; IFACE=""; FILTER=""; SAVE=""; BACKGROUND=0; DO_STATUS=0; DO_STOP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --wifi) MODE="wifi"; shift ;;
        --lan) MODE="lan"; shift ;;
        --monitor) MODE="monitor"; shift ;;
        --iface) need_arg "--iface" "$#"; IFACE="$2"; shift 2 ;;
        --filter) need_arg "--filter" "$#"; FILTER="$2"; shift 2 ;;
        --save) need_arg "--save" "$#"; SAVE="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BIG CHANGE (adopting common.sh's shared primitive): backed by the one
# canonical pid_running() in lib/common.sh instead of yet another copy of
# the same "PIDFILE + kill -0" check duplicated across this toolkit.
is_running() { pid_running "$PIDFILE"; }

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE")). Live log: tail -f $LOGFILE"
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
        say "Nothing running."
    fi
    exit 0
fi

command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed on this device."

if [ "$BACKGROUND" = "1" ] && is_running; then
    die "A background trace is already running (PID $(cat "$PIDFILE")). Use --stop first."
fi

# monitor_iface - which monitor-mode interface to use for --monitor, picked
# from what's actually present (both are Hak5's own, confirmed live via
# `iw dev`: wlan1mon is phy#1/the secondary radio recon hops for scanning,
# wlan0mon is phy#0/the primary radio's monitor sibling to wlan0). Prefer
# wlan1mon since that's the one recon itself uses for passive scanning -
# tracing the same view recon already builds its device list from.
monitor_iface() {
    [ -e /sys/class/net/wlan1mon ] && { echo wlan1mon; return; }
    [ -e /sys/class/net/wlan0mon ] && { echo wlan0mon; return; }
}

if [ -z "$MODE" ]; then
    echo "== tracer.sh =="
    say "Pick what to trace:"
    echo "  1) --wifi     Your own WiFi connection's traffic"
    echo "  2) --lan        Wired LAN traffic"
    echo "  3) --monitor       Passively watch nearby 802.11 traffic (no connection needed)"
    sel=$(ask "Choice" "1")
    case "$sel" in
        2) MODE="lan" ;;
        3) MODE="monitor" ;;
        *) MODE="wifi" ;;
    esac
    FILTER=$(ask "tcpdump filter (blank = everything)" "$FILTER")
fi

case "$MODE" in
    wifi)
        is_wifi_connected || die "Not connected to any WiFi network as a client - nothing to trace. Connect first (wifi.sh, or WIFI_CONNECT from a payload), or use --monitor to passively watch nearby traffic without connecting."
        IFACE="wlan0cli"
        say "Tracing this device's own WiFi connection (wlan0cli)..."
        cb=$(connected_bssid)
        [ -n "$cb" ] && say "Associated to $cb."
        ;;
    lan)
        if [ -z "$IFACE" ]; then
            IFACE=$(detect_usb_a_iface)
            if [ -z "$IFACE" ]; then
                die "No external USB-A LAN adapter detected. Plug one in, or pass --iface eth0 to trace the built-in USB-C/management port instead (you'll see your own SSH session in that case)."
            fi
            if ! iface_has_carrier "$IFACE"; then
                die "USB-A adapter ($IFACE) detected but link is down - check the cable. Or pass --iface eth0 explicitly to trace the management port instead."
            fi
        fi
        ip link show "$IFACE" >/dev/null 2>&1 || die "Interface '$IFACE' does not exist."
        say "Tracing wired LAN traffic on $IFACE..."
        ;;
    monitor)
        if [ -z "$IFACE" ]; then
            IFACE=$(monitor_iface)
            [ -z "$IFACE" ] && die "No monitor-mode interface found (expected wlan0mon or wlan1mon) - is the WiFi radio up?"
        fi
        ip link show "$IFACE" >/dev/null 2>&1 || die "Interface '$IFACE' does not exist."
        say "Passively watching nearby 802.11 traffic on $IFACE (no connection required)..."
        say "Note: this interface may be actively channel-hopped by recon, so the channel you're seeing shifts constantly - that's expected, not a bug."
        ;;
    *)
        die "Internal error: unknown mode '$MODE'."
        ;;
esac

[ -n "$FILTER" ] && say "Filter: $FILTER"
[ -n "$SAVE" ] && say "Also saving to: $SAVE"

TD_ARGS=(-l -nn -i "$IFACE")
[ -n "$SAVE" ] && TD_ARGS+=(-w "$SAVE")

run_trace() {
    # shellcheck disable=SC2086 - $FILTER is a raw multi-word BPF
    # expression by design (same convention sniff.sh already uses), not a
    # single token - word-splitting it IS the intended behavior here.
    #
    # BUG FOUND AND FIXED (live-caught): a plain (non-exec'd) call here,
    # reached through a function call at the tail of a `( ... ) &`
    # background subshell, does NOT collapse into one process - the
    # subshell forks tcpdump as a child instead of becoming it, so the
    # PID tracked in $PIDFILE is the subshell wrapper, not tcpdump. --stop
    # killing that PID leaves tcpdump orphaned and silently running
    # forever (caught live: a --monitor trace from an earlier test was
    # still running well after its own --stop had reported "Stopped.").
    # `exec` here is safe in BOTH the foreground and background call
    # sites - this is the last thing this script ever does either way, so
    # there's nothing that needs the tracer.sh process to still exist
    # afterward (unlike sniff.sh, which prints a summary after a
    # foreground capture and so can't exec its equivalent call).
    exec tcpdump "${TD_ARGS[@]}" $FILTER 2>&1
}

if [ "$BACKGROUND" = "1" ]; then
    say "Launching in the background - use 'tracer.sh --stop' to end it, 'tail -f $LOGFILE' to watch it live."
    ( trap '' HUP; run_trace ) >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    # BUG FOUND AND FIXED (found via code review, same class already
    # fixed in sniff.sh/PayloadRunner.sh/webui.sh): this printed "Started
    # (PID ...)" unconditionally with no liveness check - run_trace's
    # `exec` means a bad --filter (invalid BPF syntax) or a bad --iface
    # replaces the subshell with an already-dead tcpdump within a
    # fraction of a second, invisible to a check that doesn't wait and
    # look.
    sleep 1
    if is_running; then
        say "Started (PID $(cat "$PIDFILE"))."
    else
        rm -f "$PIDFILE"
        die "Trace exited immediately - check $LOGFILE (a bad --filter or --iface is the likely cause)."
    fi
    exit 0
fi

say "Press Ctrl+C to stop."
run_trace

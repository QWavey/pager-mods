#!/bin/bash
# Title: Live Packet Tracer
# Author: florian
# Description: Wireshark-style LIVE packet trace - WiFi connection, wired LAN, or passive nearby-WiFi monitoring. Errors clearly if there's nothing to trace. Press B to stop.
# Version: 1.0
#
# Wraps tcpdump directly on an interface, which is Hak5's own documented
# way to get a complete unfiltered capture (see the WIFI_PCAP doc - that
# command is Recon's own optimized/filtered log, a different tool for a
# different job; this is the raw firehose, live, matching what was asked
# for: "spammy like wireshark where i see whats going on").
#
# Three targets:
#  - My WiFi connection: traces the Pager's own wlan0cli client interface.
#    Requires actually being connected - if not, this errors with a clear
#    message instead of silently capturing nothing.
#  - Wired LAN: traces the USB-A external adapter (same convention as the
#    LAN Sniffer tool) - errors clearly if nothing's plugged in there.
#  - Watch nearby WiFi (monitor mode): passively watches 802.11 traffic in
#    the air, same interfaces Recon itself scans with. Doesn't need any
#    connection at all - this is the one option that always works if the
#    radio is up.
#
# The trace runs in the background (writing to a log) since the physical
# screen can't show a real scrolling firehose - press B to stop, and the
# last chunk of what was captured gets logged so you can see it happened.

if [ ! -x /root/scripts/tracer.sh ]; then
    ERROR_DIALOG "tracer.sh not found - run the toolkit setup.py first."
    exit 1
fi

is_wifi_connected() { ip -4 addr show wlan0cli 2>/dev/null | grep -q "inet "; }

usb_a_iface() {
    local ifn devpath
    for ifn in /sys/class/net/*; do
        ifn="$(basename "$ifn")"
        case "$ifn" in eth0|lo|br-lan|wlan*) continue ;; esac
        devpath="$(readlink -f "/sys/class/net/$ifn/device" 2>/dev/null)"
        case "$devpath" in *usb*) echo "$ifn"; return ;; esac
    done
}

iface_up() { [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]; }

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here mistook LIST_PICKER's REQUIRED trailing default-
# selection argument for an accidental repeated menu item and deleted it.
# Confirmed against Hak5's own docs: `LIST_PICKER [title] [option] [default]`
# - the last argument is a required "which option is preselected" parameter,
# separate from the option list ("A default option must always be
# provided!"). Restored here (defaulting to "My WiFi connection", the
# original pre-regression default).
__mode=$(LIST_PICKER "Live Packet Tracer" "My WiFi connection" "Wired LAN" "Watch nearby WiFi (no connection needed)" "My WiFi connection") || exit 0

case "$__mode" in
    "My WiFi connection")
        if ! is_wifi_connected; then
            ERROR_DIALOG "Not connected to any WiFi network - nothing to trace. Connect first, or pick 'Watch nearby WiFi' instead."
            exit 0
        fi
        LOG "Tracing this device's own WiFi connection - press B to stop."
        /root/scripts/tracer.sh --wifi --background
        __rc=$?
        ;;

    "Wired LAN")
        __a=$(usb_a_iface)
        if [ -z "$__a" ] || ! iface_up "$__a"; then
            ERROR_DIALOG "No external USB-A LAN adapter detected/connected - nothing to trace. Plug one in first."
            exit 0
        fi
        LOG "Tracing wired LAN traffic on $__a - press B to stop."
        /root/scripts/tracer.sh --lan --background
        __rc=$?
        ;;

    "Watch nearby WiFi (no connection needed)")
        LOG "Passively watching nearby 802.11 traffic - press B to stop."
        /root/scripts/tracer.sh --monitor --background
        __rc=$?
        ;;

    *)
        exit 0
        ;;
esac

# BUG FOUND AND FIXED (found via code review, same class already fixed
# throughout scripts/*.sh this pass): this claimed "Tracing - press B to
# stop" and waited for a button press unconditionally, regardless of
# whether tracer.sh's --background launch actually survived (tracer.sh
# itself now correctly exits non-zero on a failed launch - a bad --filter
# or a race on the interface - this payload just needed to check it).
if [ "${__rc:-0}" -ne 0 ]; then
    ERROR_DIALOG "Trace failed to start - check /tmp/pager-tracer.log and try again."
    exit 1
fi

# BIG CHANGE: this payload's own title/description promise a
# "Wireshark-style LIVE packet trace... you watch traffic go by AS IT
# HAPPENS" - but until now it just showed one static "Tracing - press B to
# stop" message and blocked, completely blind, until you pressed B. That's
# the opposite of live - it was actually the ONE capture-type payload in
# this toolkit with no live view at all, despite promising exactly that in
# its own name. lan_sniffer/payload.sh already solved this exact problem
# (poll the log's line count, LOG only the genuinely new lines each
# second, no `tail -f` - avoiding the orphaned-process bug class that
# approach caused there before it was fixed) - same proven mechanism
# ported here instead of reinventing it, plus the same A-pause/B-stop
# button behavior for consistency with that payload.
SCROLLER_PID=""
start_scroll() {
    (
        local __last=0 __total
        while :; do
            __total=$(wc -l < /tmp/pager-tracer.log 2>/dev/null || echo 0)
            if [ "$__total" -gt "$__last" ] 2>/dev/null; then
                tail -n "+$((__last + 1))" /tmp/pager-tracer.log 2>/dev/null | while IFS= read -r __line; do LOG "$__line"; done
                __last="$__total"
            fi
            sleep 1
        done
    ) &
    SCROLLER_PID=$!
}
stop_scroll() {
    [ -n "$SCROLLER_PID" ] && kill "$SCROLLER_PID" 2>/dev/null
    SCROLLER_PID=""
}

LOG "Live trace running - A: pause/resume view, B: stop."
start_scroll
__paused=0
while true; do
    __btn=$(WAIT_FOR_INPUT)
    case "$__btn" in
        A)
            if [ "$__paused" = "0" ]; then
                stop_scroll
                LOG "-- Paused. Scroll up to review. Press A to resume, B to stop. --"
                __paused=1
            else
                LOG "-- Resuming live view --"
                start_scroll
                __paused=0
            fi
            ;;
        B)
            if CONFIRMATION_DIALOG "Stop tracing and exit?"; then
                stop_scroll
                break
            else
                LOG "-- Continuing. Press B again when ready to stop. --"
            fi
            ;;
    esac
done

/root/scripts/tracer.sh --stop

__lines=$(wc -l < /tmp/pager-tracer.log 2>/dev/null || echo 0)
LOG "Trace stopped. $__lines line(s) captured. Last few:"
LOG "$(tail -n 10 /tmp/pager-tracer.log 2>/dev/null)"
ALERT "Trace stopped - $__lines lines captured"

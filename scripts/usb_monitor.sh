#!/bin/bash
# usb_monitor.sh - Notifies every time a device attaches or detaches on
# USB-C (eth0, the built-in port) or USB-A (whatever's plugged into the
# external port). Not a payload on purpose - this is a plain background
# watcher, not something meant to be started/stopped or configured
# through a picker.
#
# BUG FOUND AND FIXED (reported live - tested with a real Netgear A8000
# USB WiFi adapter, no message ever appeared): the ORIGINAL USB-A
# detection only used detect_usb_a_iface() (lib/common.sh), which finds
# USB ETHERNET adapters specifically - correct for pc_link.sh's actual
# job (wired LAN capture), but it deliberately skips anything wlan*-
# prefixed, and a USB WiFi adapter never creates an ethN interface at
# all - it's invisible to that check by design, not by bug. Confirmed
# live via dmesg: the A8000 is an mt7921u device (the SAME chipset family
# as the Pager's own internal radio) - it enumerated on the USB bus fine,
# just never as a network interface detect_usb_a_iface() would recognize.
#
# Fixed by adding a SECOND, lower-level detector alongside the existing
# one: real USB bus attach/disconnect events straight from dmesg, which
# catches ANY peripheral (WiFi adapter, Ethernet adapter, storage,
# anything) regardless of whether it ever gets a driver/interface at all.
# The one thing that needs excluding: the Pager's OWN internal WiFi radio
# is *also* a USB device internally (confirmed live: also an mt7921u,
# identified via `product` = "Wireless_Device" at a FIXED bus path) - if
# its driver ever reinitializes, that would look identical to an external
# device being plugged in without this exclusion. get_internal_radio_usb_path
# below finds that path dynamically at startup (not hardcoded - the exact
# path can differ between individual units/firmware), so it can be told
# apart from a genuinely external USB-A device every time.
#
# Detects three distinct things now:
#   - USB-C (eth0) is a fixed platform device that always exists - only
#     its CARRIER (cable plugged in / link up) can change.
#   - USB-A Ethernet adapters: interface-level detail (which ethN to use)
#     via detect_usb_a_iface(), same as before - still useful when it IS
#     an Ethernet adapter, since it tells you the interface name.
#   - USB-A ANY device: real USB bus attach/disconnect events via dmesg,
#     catching non-Ethernet peripherals too (like the A8000).
# Reuses iface_has_carrier/detect_usb_a_iface from lib/common.sh for the
# Ethernet-specific case - no new mechanism there, same helpers pc_link.sh
# /sniff.sh already trust.
#
# Usage:
#   usb_monitor.sh --watch          foreground, prints on every change, Ctrl+C to stop
#   usb_monitor.sh --background        same, detached - use --stop to end it
#   usb_monitor.sh --status               is it running?
#   usb_monitor.sh --stop                    stop a background run
#
# Options:
#   --watch          Run in the foreground.
#   --background        Run detached; use --stop to end it.
#   --status               Is a background watcher currently running?
#   --stop                    Stop a background watcher.
#   -h, --help                  This help.

set -u
TOOL_NAME="usb_monitor.sh"
PIDFILE="/tmp/pager-usbmon.pid"
LOGFILE="/tmp/pager-usbmon.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_WATCH=0; BACKGROUND=0; DO_STOP=0; DO_STATUS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --watch) DO_WATCH=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BIG CHANGE (adopting common.sh's shared primitive): backed by the one
# canonical pid_running() in lib/common.sh instead of yet another copy.
# pid_running's optional NAME_PATTERN (see lib/common.sh) guards against a
# stale PIDFILE whose PID got reused by an unrelated process - the
# backgrounded run_monitor loop is a subshell of THIS script, so its real
# /proc/PID/cmdline still shows "usb_monitor.sh".
is_running() { pid_running "$PIDFILE" "usb_monitor.sh"; }

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE"))."
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

STOPPING=0
_on_stop() { STOPPING=1; }
trap _on_stop INT TERM

# notify MESSAGE - BUG FOUND AND FIXED THREE TIMES now (reported live
# each round). First: this only ever called say() (a plain `echo` into
# this script's own hidden log file) - never anything the device's
# actual on-screen UI would show. LOG turned out to be a REAL,
# independently callable binary (confirmed live via plain SSH, same as
# PINEAPPLE_DEAUTH_CLIENT and friends - a hak5cmd symlink, not payload-
# runner-only), so that got wired in - but LOG only appends to the on-
# device log VIEW, not an actual pop-up, which still didn't match what
# was asked for ("a display box like on GUI on device"). ALERT LOOKED
# like the right fix for that (confirmed live it's ALSO independently
# callable and genuinely produces a full-screen alert - Hak5's own docs:
# "displays a full-screen alert message and plays the alert ringtone").
#
# THIRD BUG (reported live - "the messages still don't go away after a
# while"): confirmed against Hak5's own ALERT docs - its syntax is JUST
# `ALERT [message]`, no duration/timeout/dismiss parameter of any kind.
# There is also no separate lightweight "toast" primitive documented
# anywhere in Hak5's API - ALERT is the only on-screen popup command that
# exists, and its own docs frame it for events that "require the user's
# attention" (one-off, deliberate things like a finished scan), not a
# background watcher that can fire repeatedly for ordinary USB plug/
# unplug activity. Using ALERT here meant every attach/detach queued a
# full-screen, ringtone-playing interruption with no way to make it auto-
# clear - exactly the "message doesn't go away" symptom, and it's a
# genuine API limitation, not something this script can configure around.
# Fix: drop ALERT here entirely. LOG already gives a real, persistent,
# non-blocking on-screen record of every event (visible in the Pager's
# own log view) without ever needing to be dismissed - the right tool for
# a frequent ambient notification. ALERT is still the right choice
# elsewhere in this toolkit for genuinely one-off, attention-worthy
# events (an attack finishing, a scan completing) - just not for this.
notify() {
    say "$1"
    command -v LOG >/dev/null 2>&1 && LOG "$1" >/dev/null 2>&1
}

# get_internal_radio_usb_path - THE ACTUAL ROOT CAUSE of "USB-A never
# shows anything", found live: this used to match on the internal
# radio's `product` sysfs string ("Wireless_Device") to identify and
# exclude it - but that string is generic to the WHOLE mt7921u chipset
# family, not unique to the internal radio. Confirmed live: with the
# Netgear A8000 (also mt7921u-based) plugged into USB-A, BOTH devices
# report "Wireless_Device" - the search loop returned on the FIRST
# match in glob order, which was the EXTERNAL device (1-1.1 sorts before
# 1-1.2) - meaning the external adapter was being misidentified AS the
# internal radio and silently excluded from every detection, every time.
#
# Fixed properly: resolve the REAL USB device backing wlan1mon (the
# Pager's own internal monitor interface, confirmed this session to be
# the internal radio) directly via its /sys/class/net/*/device symlink -
# unambiguous, no string-matching collision possible, confirmed live:
# `readlink -f /sys/class/net/wlan1mon/device` resolves through
# ".../1-1/1-1.2/1-1.2:1.3" - the bus-path component is the "N-N.N"
# segment right before the ":" interface suffix.
get_internal_radio_usb_path() {
    local real
    real=$(readlink -f /sys/class/net/wlan1mon/device 2>/dev/null)
    [ -z "$real" ] && return
    echo "$real" | grep -oE '[0-9]+-[0-9.]+(:[0-9.]+)?$' | head -1 | sed -E 's/:[0-9.]+$//'
}

# usb_vendor_name ID - a SMALL, honestly-scoped table of USB-IF registered
# vendor IDs (the real, standardized 4-hex-digit identifiers every USB
# device reports - these are public, documented assignments, not guessed)
# for the handful of brands common enough to be worth naming directly.
# Anything not in this short list just shows its raw idVendor:idProduct
# instead of a guessed name - deliberately not trying to be a full USB ID
# database (that would need real data this project doesn't have/maintain).
usb_vendor_name() {
    case "$1" in
        0846) echo "NETGEAR" ;;
        0bda) echo "Realtek" ;;
        2357) echo "TP-Link" ;;
        13b1) echo "Linksys" ;;
        0b95) echo "ASIX" ;;
        0424) echo "Microchip/SMSC" ;;
        05ac) echo "Apple" ;;
        046d) echo "Logitech" ;;
        *) echo "" ;;
    esac
}

# describe_usb_device PATH - BUG FOUND AND FIXED (reported live - "show
# in () the device type and the device name"): the earlier attempt read
# `product` once, immediately after the attach line appeared - too early;
# a real test showed it can still be empty at that exact instant (sysfs
# populates as enumeration completes, not all at once). Retries briefly
# (up to 5 tries, 0.3s apart - enumeration is fast, this is not a long
# wait) instead of a single try. Also: `product`/`manufacturer` turned
# out to be generic CHIPSET reference-design strings ("Wireless_Device" /
# "MediaTek Inc.", confirmed live on a real Netgear A8000) - the actual
# make is only identifiable via idVendor (0846 for this exact device,
# genuinely NETGEAR's real registered USB-IF vendor ID, confirmed - not
# guessed), so this reports BOTH: the resolved brand (or the raw
# vendor:product hex ID if not in the small table above) as the device
# name, and the chipset manufacturer/product string as the type in
# parens, e.g. "NETGEAR (0846:9060) (MediaTek Inc. Wireless_Device)".
describe_usb_device() {
    local path="$1" tries=0 vid="" pid="" mfr="" prod=""
    while [ "$tries" -lt 5 ]; do
        vid=$(cat "/sys/bus/usb/devices/$path/idVendor" 2>/dev/null)
        pid=$(cat "/sys/bus/usb/devices/$path/idProduct" 2>/dev/null)
        mfr=$(cat "/sys/bus/usb/devices/$path/manufacturer" 2>/dev/null)
        prod=$(cat "/sys/bus/usb/devices/$path/product" 2>/dev/null)
        [ -n "$vid" ] && [ -n "$prod" ] && break
        tries=$((tries + 1))
        sleep 0.3
    done
    [ -z "$vid" ] && return 1
    local name
    name=$(usb_vendor_name "$vid")
    [ -z "$name" ] && name="${vid}:${pid}"
    local type_str="${mfr:-unknown chip} ${prod:-device}"
    echo "$name ($type_str)"
    return 0
}

# process_usb_dmesg_lines - reads candidate USB attach/disconnect dmesg
# lines from stdin (already grep-filtered by the caller) and notifies for
# each one not belonging to the internal radio. Pulled out into its own
# function so the two callers inside run_monitor below (the normal
# incremental-tail path, and the ring-buffer-wrap full-rescan path) share
# one implementation instead of duplicating this block.
process_usb_dmesg_lines() {
    local _line _path _desc
    while IFS= read -r _line; do
        _path=$(echo "$_line" | grep -oE 'usb [0-9]+-[0-9.]+' | awk '{print $2}')
        [ -n "$internal_radio_path" ] && [ "$_path" = "$internal_radio_path" ] && continue
        if echo "$_line" | grep -qi "disconnect"; then
            notify "USB-A: device detached (bus $_path)"
        else
            _desc=$(describe_usb_device "$_path")
            if [ -n "$_desc" ]; then
                notify "USB-A: $_desc attached (bus $_path)"
            else
                notify "USB-A: device attached (bus $_path)"
            fi
        fi
    done
}

# run_monitor - polls every 2s (USB hotplug/link-up doesn't settle
# instantly anyway - no value in polling faster than that) and prints
# exactly one line per actual state CHANGE, never on the first read (that
# would just announce whatever's already plugged in at startup as if it
# just happened).
run_monitor() {
    say "Watching USB-C/USB-A for attach/detach - Ctrl+C to stop."
    local internal_radio_path
    internal_radio_path=$(get_internal_radio_usb_path)
    # Baseline dmesg line count - only lines APPENDED after this point
    # count as "new" (matches the same count-diff pattern already proven
    # in sniff.sh's live watchers). Deliberately never clears/consumes
    # the kernel log buffer (no `dmesg -c`) - something else on the
    # device (klogd/syslog) may also be reading it, and destructively
    # clearing it could steal messages meant for that.
    local dmesg_seen
    dmesg_seen=$(dmesg 2>/dev/null | wc -l)

    local prev_c="" prev_a_if="" prev_a_state=""
    while [ "$STOPPING" != "1" ]; do
        local c_state a_if a_state
        if iface_has_carrier eth0; then c_state="attached"; else c_state="detached"; fi
        a_if=$(detect_usb_a_iface)
        if [ -n "$a_if" ] && iface_has_carrier "$a_if"; then
            a_state="attached"
        elif [ -n "$a_if" ]; then
            a_state="detected-link-down"
        else
            a_state="none"
        fi

        if [ -n "$prev_c" ] && [ "$c_state" != "$prev_c" ]; then
            notify "USB-C: $c_state"
        fi
        if [ -n "$prev_a_state" ] && { [ "$a_state" != "$prev_a_state" ] || [ "$a_if" != "$prev_a_if" ]; }; then
            # BUG FOUND AND FIXED (bug-hunt pass): this used to hardcode
            # "attached" whenever the interface first appeared (prev was
            # "none"), even if its real state was "detected-link-down"
            # (interface enumerated, cable/carrier not actually up yet) -
            # a real Ethernet adapter plugged in without a cable attached
            # would have been wrongly reported as "attached". Just report
            # the real $a_state either way - no need for the special case.
            if [ -z "$a_if" ]; then
                notify "USB-A ($prev_a_if): detached"
            else
                notify "USB-A ($a_if): $a_state"
            fi
        fi

        # Generic USB-A bus-level attach/detach - catches ANY device
        # (WiFi adapters, storage, anything), not just ones that show up
        # as an Ethernet interface. See get_internal_radio_usb_path above
        # for why the internal radio's own path is excluded.
        #
        # IMPROVEMENT (performance, run continuously every 2s): this used
        # to call the `dmesg` binary TWICE per iteration whenever new lines
        # showed up - once just to get the line count (`wc -l`), then again
        # moments later to actually read the new lines (`tail`). dmesg on
        # this device reads straight from the kernel ring buffer - a fork+
        # exec+kernel-read that's pure waste to pay twice for the same
        # snapshot when it's trivial to capture the buffer ONCE into a
        # variable and derive both the count and the tail from that same
        # string. Verified equivalent with a standalone repro (fake dmesg()
        # with a call counter): identical output, dmesg invocations per
        # "new lines" iteration dropped from 2 to 1. The no-change path
        # (the common case, most iterations) was already just 1 call and
        # stays that way.
        local dmesg_now dmesg_total
        dmesg_now=$(dmesg 2>/dev/null)
        dmesg_total=$(printf '%s\n' "$dmesg_now" | wc -l)
        local _usb_grep='^\[.*\] usb [0-9]+-[0-9.]+: (new .* USB device|USB disconnect)'
        if [ "$dmesg_total" -gt "$dmesg_seen" ] 2>/dev/null; then
            printf '%s\n' "$dmesg_now" | tail -n "+$((dmesg_seen + 1))" | grep -E "$_usb_grep" | process_usb_dmesg_lines
            dmesg_seen="$dmesg_total"
        elif [ "$dmesg_total" -lt "$dmesg_seen" ] 2>/dev/null; then
            # BUG FOUND AND FIXED (same class as crash_logger.sh's own
            # fix, arguably even more likely to bite here - this is
            # designed to run continuously for as long as the device is
            # up, not just for one testing session): the kernel ring
            # buffer has a fixed capacity - once full, old lines get
            # evicted from the front as new ones arrive, so `dmesg | wc
            # -l` can drop (or plateau) even though genuinely new bus
            # events keep arriving. The original `total -gt seen`-only
            # check would go permanently blind to new USB attach/detach
            # events the first time this happens on a long-running
            # watcher, with --status still happily reporting "Running"
            # and no indication attach/detach detection had silently
            # stopped working (the separate eth0/USB-A-Ethernet carrier
            # checks above are unaffected - only this generic bus-event
            # path depends on dmesg). A drop is an unambiguous wrap
            # signal: re-scan the WHOLE current buffer for attach/
            # disconnect lines instead of assuming nothing changed - at
            # worst this re-notifies about a device event from just
            # before the wrap once, which is a far better failure mode
            # than going silent for the rest of the run.
            printf '%s\n' "$dmesg_now" | grep -E "$_usb_grep" | process_usb_dmesg_lines
            dmesg_seen="$dmesg_total"
        fi

        prev_c="$c_state"; prev_a_if="$a_if"; prev_a_state="$a_state"
        sleep 2 &
        wait $!
    done
    say "Stopped."
}

if [ "$BACKGROUND" = "1" ]; then
    if is_running; then die "Already running (PID $(cat "$PIDFILE")). Use --stop first."; fi
    ( trap '' HUP; run_monitor ) >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    say "Started (PID $(cat "$PIDFILE")). Log: $LOGFILE"
    exit 0
fi

run_monitor

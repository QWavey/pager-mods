#!/bin/bash
# Title: Custom LAN Scan
# Author: florian
# Description: nmap scan of the wired LAN (eth1) - pick a mode on-screen, logs to /root/loot/lanscan/
# Version: 2.0

LOG "Custom LAN Scan starting..."

if [ ! -x /root/scripts/LanScan.sh ]; then
    ERROR_DIALOG "LanScan.sh not found - run the toolkit setup.py first."
    exit 1
fi

# REGRESSION FOUND AND FIXED (found via code review): a prior "duplicate
# entry" cleanup here mistook LIST_PICKER's REQUIRED trailing default-
# selection argument for an accidental repeated menu item and deleted it.
# Confirmed against Hak5's own docs: `LIST_PICKER [title] [option] [default]`
# - the last argument is a required "which option is preselected" parameter,
# separate from the option list ("A default option must always be
# provided!"). Restored it here (defaulting to "quick", the original
# pre-regression default).
__mode=$(LIST_PICKER "Scan mode" "ping" "quick" "service" "full" "vuln" "quick") || exit 0

LOG "Running LanScan.sh --mode ${__mode}"
# BUG FOUND AND FIXED (found via code review, same class already fixed in
# wifi_deauth/payload.sh and throughout scripts/*.sh this pass): this
# reported "LAN scan finished... done" unconditionally, regardless of
# whether LanScan.sh actually succeeded (missing nmap, no interface, a
# subnet it couldn't auto-detect all `die` non-zero before ever scanning).
if /root/scripts/LanScan.sh --mode "$__mode" -y; then
    LOG "LAN scan finished, see /root/loot/lanscan/"
    ALERT "LAN scan done - check loot/lanscan"
else
    LOG "LAN scan failed - see the log above for the reason."
    ERROR_DIALOG "LAN scan failed - check the log"
fi

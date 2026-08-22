#!/bin/bash
# Title: PC Link Capture
# Author: florian
# Description: Detect whatever PC is directly wired to the Pager (USB-C tether or a USB-A adapter like UGREEN) and capture + summarize its traffic.
# Version: 2.0
#
# Plug the Pager into a PC via USB-C, or wire a PC to the Pager's USB-A
# port through an Ethernet adapter, then run this. It figures out which
# link has a PC on it and captures traffic on that exact interface, then
# runs it through sniff.sh's existing summary (top talkers, protocol
# breakdown, cleartext-credential scan) - so you get an actual look at
# what's crossing the wire, not just a port list.

if [ ! -x /root/scripts/pc_link.sh ]; then
    ERROR_DIALOG "pc_link.sh not found - run the toolkit setup.py first."
    exit 1
fi

LOG "Detecting directly-wired PC links..."
__detect=$(/root/scripts/pc_link.sh --detect 2>&1)
LOG "$__detect"

__dur=$(NUMBER_PICKER "Capture duration (seconds)" "30") || exit 0

if ! CONFIRMATION_DIALOG "Capture traffic on the detected PC link?"; then
    LOG "User cancelled."
    exit 0
fi

LOG "Capturing for ${__dur}s..."
__result=$(/root/scripts/pc_link.sh --capture --duration "$__dur" -y 2>&1)
__rc=$?
LOG "$__result"
# BUG FOUND AND FIXED (found via code review, same class already fixed
# throughout scripts/*.sh this pass): this claimed "PC link capture
# complete" unconditionally regardless of whether pc_link.sh actually
# succeeded (pc_link.sh's own --capture branch now correctly propagates
# sniff.sh's real exit code instead of a hardcoded exit 0 - this payload
# just needed to actually check it).
if [ "$__rc" -eq 0 ]; then
    ALERT "PC link capture complete"
else
    ERROR_DIALOG "PC link capture failed - see log"
fi

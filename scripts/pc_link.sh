#!/bin/bash
# pc_link.sh - The moment a PC is wired directly to the Pager, capture and
# summarize its traffic - not a one-shot port scan (that told you almost
# nothing useful about a machine that's just sitting there being your own
# PC). This finds whichever of the two point-to-point PC links is active
# and hands off to sniff.sh's existing capture+summary pipeline (top
# talkers, protocol breakdown, cleartext-credential scan) on that exact
# interface, so you get a real look at what's actually crossing the wire.
#
# The two PC links:
#   - USB-C (eth0, built-in): per Hak5's docs this is a Realtek RTL8153
#     USB-Ethernet gadget straight to a host PC/laptop, bridged into
#     br-lan (172.16.52.0/24) where the Pager itself is the DHCP server -
#     a tethered PC shows up in the Pager's own DHCP lease file.
#   - USB-A (eth1, external adapter e.g. UGREEN): configured as a DHCP
#     CLIENT on this device (confirmed via `uci show network`), so
#     whatever's on the other end - a PC doing internet connection
#     sharing, or a router - is found via the interface's gateway/
#     neighbor instead.
#
# Usage:
#   pc_link.sh --detect                     show what's connected on each wired PC-link path
#   pc_link.sh --capture [--duration SECONDS]  detect + capture/summarize that link's traffic
#   pc_link.sh --capture --iface IFACE       capture a specific interface instead of auto-detecting
#   pc_link.sh                                interactive mode
#
# Options:
#   --detect              Just report what's on each link, don't capture.
#   --capture               Detect (or use --iface) and capture+summarize traffic.
#   --iface IFACE              Capture this interface instead of auto-detecting.
#   --duration SECONDS            How long to capture (default: 30).
#   --background                    Capture detached - see sniff.sh --stop/--status.
#   -y, --yes                         Don't prompt for confirmation.
#   -h, --help                          This help.

set -u
TOOL_NAME="pc_link.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_DETECT=0; DO_CAPTURE=0; IFACE_OVERRIDE=""; DURATION="30"; BACKGROUND=0

while [ $# -gt 0 ]; do
    case "$1" in
        --detect) DO_DETECT=1; shift ;;
        --capture) DO_CAPTURE=1; shift ;;
        --iface) need_arg "--iface" "$#"; IFACE_OVERRIDE="$2"; shift 2 ;;
        --duration) need_arg "--duration" "$#"; DURATION="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# detect_usb_c_peer - most recent DHCP lease handed out on br-lan (which
# eth0/USB-C is a bridge port of). Best-effort: no `bridge fdb` tool on
# this busybox build to attribute a lease to a specific bridge port, so
# this is "most recent lease" not "definitely this port" - said plainly.
# (iface_has_carrier and detect_usb_a_iface come from lib/common.sh - used
# identically by sniff.sh, pulled out there instead of duplicated here.)
detect_usb_c_peer() {
    iface_has_carrier eth0 || { echo ""; return; }
    [ -f /tmp/dhcp.leases ] || { echo ""; return; }
    sort -rn /tmp/dhcp.leases 2>/dev/null | head -1
}

detect_usb_a_peer() {
    local ifn="$1" gw
    iface_has_carrier "$ifn" || { echo ""; return; }
    gw=$(ip route show dev "$ifn" 2>/dev/null | awk '/^default/ {print $3; exit}')
    if [ -n "$gw" ]; then echo "$gw"; return; fi
    ip neigh show dev "$ifn" 2>/dev/null | awk '{print $1; exit}'
}

report_detect() {
    say "USB-C (built-in, eth0):"
    if iface_has_carrier eth0; then
        local lease
        lease=$(detect_usb_c_peer)
        if [ -n "$lease" ]; then
            echo "  Connected. Most recent DHCP lease: $(echo "$lease" | awk '{printf "%s (%s) - \"%s\"", $3, $2, $4}')"
            echo "  (best-effort - if a WiFi Management client is also connected, this can't tell them apart by port)"
        else
            echo "  Connected, but no DHCP lease seen yet (still negotiating, or a static IP was set on the PC side)."
        fi
    else
        echo "  Not connected."
    fi

    local usb_a
    usb_a=$(detect_usb_a_iface)
    say "USB-A (external adapter):"
    if [ -z "$usb_a" ]; then
        echo "  None detected."
    elif iface_has_carrier "$usb_a"; then
        local peer
        peer=$(detect_usb_a_peer "$usb_a")
        if [ -n "$peer" ]; then
            echo "  Connected ($usb_a). Peer: $peer"
        else
            echo "  Connected ($usb_a), but no gateway/neighbor found yet."
        fi
    else
        echo "  Adapter present ($usb_a) but link is down."
    fi
}

if [ "$DO_DETECT" = "1" ]; then
    report_detect
    exit 0
fi

# resolve_iface - which interface to actually capture on: --iface wins,
# otherwise USB-C (eth0) if it's connected, otherwise the USB-A adapter if
# that's connected instead.
resolve_iface() {
    if [ -n "$IFACE_OVERRIDE" ]; then
        echo "$IFACE_OVERRIDE"
        return
    fi
    if iface_has_carrier eth0; then
        echo "eth0"
        return
    fi
    local usb_a
    usb_a=$(detect_usb_a_iface)
    if [ -n "$usb_a" ] && iface_has_carrier "$usb_a"; then
        echo "$usb_a"
        return
    fi
    echo ""
}

do_capture() {
    local iface="$1"
    [ -x "$SCRIPT_DIR/sniff.sh" ] || die "sniff.sh not found next to pc_link.sh."
    # CONSISTENCY FIX (found via code review - same class already fixed in
    # the LAN Sniffer payload's own eth0 fallback, missed here): capturing
    # on eth0 also captures whatever's riding the Pager's own SSH/
    # management link over USB-C, if that's how this is being reached -
    # the LAN Sniffer payload already says this plainly when it falls back
    # to eth0 ("may include your own SSH session"); this script silently
    # didn't, even though resolve_iface() picks eth0 by the exact same
    # rule (has-carrier, tried before the USB-A adapter).
    [ "$iface" = "eth0" ] && say "Note: eth0 is also the USB-C management link - if you're on this over SSH, its traffic will be in the capture too."
    say "Capturing on $iface for ${DURATION}s (this is the PC's own traffic across the wire)..."
    # BUG FOUND AND FIXED: this used to hand off to sniff.sh with no
    # --output, so captures landed as an indistinguishable
    # sniff-<iface>-<timestamp>.pcap - identical in name to a plain
    # `sniff.sh --iface` run. report.sh's "PC link captures" section
    # counted files in /root/loot/pclink/, a directory this script never
    # wrote to at all - always reported 0 even after real captures. A
    # "pclink-" prefix inside sniff.sh's own loot dir (report.sh now
    # matches on this prefix instead) makes them both findable and
    # actually distinguishable from generic sniff captures.
    local stamp outfile
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo pclink)
    outfile="/root/loot/sniff/pclink-${iface}-${stamp}.pcap"
    local args=(--iface "$iface" --duration "$DURATION" --output "$outfile" -y)
    [ "$BACKGROUND" = "1" ] && args+=(--background)
    "$SCRIPT_DIR/sniff.sh" "${args[@]}"
}

if [ "$DO_CAPTURE" = "1" ]; then
    target_iface=$(resolve_iface)
    if [ -z "$target_iface" ]; then
        die "No directly-wired PC link detected. Use --iface to specify one, or --detect to see what was found."
    fi
    confirm "Capture traffic on $target_iface?" || die "Aborted."
    # BUG FOUND AND FIXED (found via code review): this used to `exit 0`
    # unconditionally right after do_capture, regardless of whether the
    # underlying sniff.sh capture actually succeeded - pc_link.sh always
    # reported success via its own exit code even when sniff.sh failed
    # (bad interface, tcpdump missing, etc.), which matters for anything
    # scripted around this (a payload, sync.py, cron). Propagate the real
    # exit code instead of assuming success.
    do_capture "$target_iface"
    exit $?
fi

echo "== pc_link.sh =="
report_detect
echo
target_iface=$(resolve_iface)
if [ -n "$target_iface" ]; then
    DURATION=$(ask "Capture duration (seconds)" "$DURATION")
    if confirm "Capture traffic on $target_iface?"; then
        do_capture "$target_iface"
    fi
else
    say "Nothing auto-detected - nothing to capture."
fi

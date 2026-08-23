#!/bin/bash
# bettercap.sh - driver + on-device builder for bettercap (approved idea BC1).
#
# bettercap (github.com/bettercap/bettercap) is a Go program with cgo bindings
# to libpcap (and libusb for some modules). OpenWRT's feed ships the golang
# compiler and the libpcap RUNTIME (libpcap1) but NOT the libpcap headers, and
# there is no prebuilt mipsel bettercap - so this wrapper carries a --build
# recipe that installs the toolchain, fetches the matching libpcap headers by
# hand, sets the cgo flags, and compiles bettercap to /mmc/go/bin. It's the
# heaviest thing in the toolkit to build (large Go dep graph on a 251MB-RAM
# MIPS CPU) - expect it to take a while and possibly need a retry.
#
# NOTE: bettercap's core abilities (ARP-spoof MITM, sniffing, DNS spoof, WiFi
# and BLE recon) are already covered natively by this toolkit - deadnet.sh,
# sniff.sh/stealthnet.sh, dnsspoof.sh, airscout.sh, deauth.sh, bluetooth.sh -
# which are lighter on this hardware. bettercap is here for its interactive
# session/caplet workflow when you specifically want it.
#
# Usage:
#   bettercap.sh --build            install toolchain + compile bettercap (once, slow)
#   bettercap.sh --build-status     tail the build log
#   bettercap.sh [bettercap args]   run it (e.g. -iface eth1, -caplet ...)
#
# Only on networks you own or are authorized to test.

set -u
TOOL_NAME="bettercap.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

GOROOT_BIN="/mmc/usr/bin"                 # opkg golang lands here
BC_BIN="/mmc/go/bin/bettercap"
BUILD_LOG="/mmc/bettercap-build.log"
PCAP_VER="1.10.5"                          # match libpcap1 on the device
export PATH="/mmc/usr/bin:/mmc/usr/sbin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

do_build() {
    say "Installing build toolchain (golang, gcc, git, libpcap1)..."
    opkg update >/dev/null 2>&1
    opkg install -d mmc golang gcc git libpcap1 libusb-1.0-0 >>"$BUILD_LOG" 2>&1
    command -v go >/dev/null 2>&1 || { command -v /mmc/usr/bin/go >/dev/null 2>&1 || die "go not installed - see $BUILD_LOG"; }

    # libpcap headers (no -dev package in the feed): grab the matching source
    # just for its headers; we link against the already-installed libpcap1 .so.
    local inc="/mmc/pcap-include"
    if [ ! -f "$inc/pcap.h" ]; then
        say "Fetching libpcap $PCAP_VER headers..."
        wget -qO /tmp/libpcap.tgz "https://www.tcpdump.org/release/libpcap-$PCAP_VER.tar.gz" >>"$BUILD_LOG" 2>&1 \
            || die "Could not download libpcap source - see $BUILD_LOG."
        rm -rf /tmp/libpcap-src; mkdir -p /tmp/libpcap-src
        tar xzf /tmp/libpcap.tgz -C /tmp/libpcap-src --strip-components=1 >>"$BUILD_LOG" 2>&1
        mkdir -p "$inc/pcap"
        cp /tmp/libpcap-src/pcap/*.h "$inc/pcap/" 2>/dev/null
        cp /tmp/libpcap-src/pcap.h "$inc/" 2>/dev/null
        # some gopacket bindings include <pcap.h>, others <pcap/pcap.h> - provide both
        [ -f "$inc/pcap.h" ] || cp /tmp/libpcap-src/pcap/pcap.h "$inc/pcap.h" 2>/dev/null
    fi

    export GOPATH=/mmc/go GOCACHE=/mmc/go/cache
    export CGO_ENABLED=1 CC=gcc
    export CGO_CFLAGS="-I$inc"
    export CGO_LDFLAGS="-L/mmc/usr/lib -L/usr/lib -lpcap"
    mkdir -p "$GOPATH" "$GOCACHE"
    say "Building bettercap (this is the slow part - tail with --build-status)..."
    # clone + build a tagged release for reproducibility
    if [ ! -d /mmc/bettercap-src ]; then
        git clone --depth 1 https://github.com/bettercap/bettercap.git /mmc/bettercap-src >>"$BUILD_LOG" 2>&1 \
            || die "git clone failed - see $BUILD_LOG."
    fi
    ( cd /mmc/bettercap-src && go build -o "$BC_BIN" . ) >>"$BUILD_LOG" 2>&1
    if [ -x "$BC_BIN" ]; then
        say "bettercap built: $BC_BIN"
        "$BC_BIN" -version 2>/dev/null | head -1
    else
        die "Build did not produce a binary - see $BUILD_LOG (likely a missing cgo header or OOM on this 251MB device)."
    fi
}

case "${1:-}" in
    -h|--help|"") [ "${1:-}" = "" ] && [ ! -x "$BC_BIN" ] && usage
                  [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage ;;
esac

case "${1:-}" in
    --build) : > "$BUILD_LOG"; do_build ;;
    --build-status) tail -n 40 "$BUILD_LOG" 2>/dev/null || say "No build log yet." ;;
    *)
        [ -x "$BC_BIN" ] || die "bettercap not built yet - run: bettercap.sh --build"
        exec "$BC_BIN" "$@"
        ;;
esac

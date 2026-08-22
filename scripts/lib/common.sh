#!/bin/bash
#
# common.sh - Shared helpers for the Pager utility scripts. Source this,
# don't execute it directly.
#
#   . "$(dirname "$0")/lib/common.sh"
#
# Expects the sourcing script to set TOOL_NAME and CFG_NS before/after
# sourcing. Provides: say/err/die, cfg_get/cfg_set/cfg_del (wrapping the
# official PAYLOAD_*_CONFIG store), confirm/ask prompts, need_arg for
# set -u-safe argument parsing, and print_help (reads the CALLER script's
# own leading comment header between the "Usage:" marker and the first
# blank line after it, so each script's own file is the single source of
# truth for its --help text - no more hand-counted sed ranges going stale).

TOOL_NAME="${TOOL_NAME:-$(basename "${0:-tool}")}"
CFG_NS="${CFG_NS:-${TOOL_NAME%.sh}}"

say()  { echo "[$TOOL_NAME] $*"; }
err()  { echo "[$TOOL_NAME] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

cfg_get() { PAYLOAD_GET_CONFIG "$CFG_NS" "$1" 2>/dev/null; }
cfg_set() { PAYLOAD_SET_CONFIG "$CFG_NS" "$1" "$2" >/dev/null 2>&1; }
cfg_del() { PAYLOAD_DEL_CONFIG "$CFG_NS" "$1" >/dev/null 2>&1; }

ASSUME_YES="${ASSUME_YES:-0}"

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    local prompt="$1"
    read -r -p "$prompt [y/N] " ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask() {
    local prompt="$1" default="${2:-}" ans
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " ans
        echo "${ans:-$default}"
    else
        read -r -p "$prompt: " ans
        echo "$ans"
    fi
}

ask_secret() {
    # ask_secret "Prompt" -> echoes the entered value, input hidden
    local prompt="$1" ans
    read -r -s -p "$prompt: " ans; echo >&2
    echo "$ans"
}

# need_arg "$@" -- call as: need_arg "--flag-name" "$#"  (checks at least 2 remain)
need_arg() {
    local flag="$1" remaining="$2"
    [ "$remaining" -lt 2 ] && die "$flag needs a value"
}

# print_help SCRIPT_PATH - print everything between the leading "#!" line
# and the first blank (non-comment) line, stripped of the leading "# ".
print_help() {
    local script="$1"
    awk '
        NR==1 { next }
        /^#/ { sub(/^# ?/, ""); print; next }
        { exit }
    ' "$script"
}

# resolve_python3 - echoes the command prefix to run python3 with, whether
# it's on $PATH or only installed to the mmc partition (which needs its
# shared library found explicitly - see the postmortem in README.md on why
# this is a per-invocation env var and NOT a system-wide ld-musl path file).
# Usage: $(resolve_python3) script.py args...   (word-splitting is fine -
# the paths involved never contain spaces).
resolve_python3() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    if [ -x /mmc/usr/bin/python3.11 ]; then
        echo "env LD_LIBRARY_PATH=/mmc/usr/lib /mmc/usr/bin/python3.11"
        return 0
    fi
    return 1
}

# is_valid_mac MAC - does this look like a real xx:xx:xx:xx:xx:xx MAC
# address? Catches typos early with a clear error instead of a command
# silently doing nothing (or a sqlite3 query silently matching zero rows)
# several layers deeper.
is_valid_mac() {
    case "$1" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
        *) return 1 ;;
    esac
}

# iface_has_carrier IFACE - is a cable/adapter actually plugged in and
# link-up, not just an interface that exists? /sys/class/net/*/carrier is
# "1" when the physical link is up, "0" otherwise.
iface_has_carrier() {
    [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]
}

# is_wifi_connected - is the Pager currently associated to a network as a
# WiFi client? wlan0cli only exists once WIFI_CONNECT has actually
# associated it (confirmed live: absent entirely while disconnected, e.g.
# `ip addr show wlan0cli` errors "can't find device"). Shared by deauth.sh
# (--pick) and tracer.sh (--wifi) - was duplicated in deauth.sh until this
# was pulled out here.
is_wifi_connected() { ip -4 addr show wlan0cli 2>/dev/null | grep -q "inet "; }

# connected_bssid - BSSID the client interface is currently associated to,
# via the standard `iw` tool (not Hak5-specific, but present on this device
# and the normal way to ask a wireless interface who it's associated to).
connected_bssid() {
    command -v iw >/dev/null 2>&1 || return 1
    iw dev wlan0cli link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
}

# detect_usb_a_iface - whatever external USB Ethernet adapter (e.g. a
# UGREEN one) is plugged into the Pager's USB-A port, if any. Identified
# dynamically by sysfs device path containing "/usb" (i.e. actually
# enumerated over USB, unlike eth0's platform device) rather than assuming
# a fixed name like eth1 - OpenWRT assigns USB Ethernet adapters the next
# free ethN, which chipset and hotplug order can change. Shared by
# sniff.sh (--adapters) and pc_link.sh (--detect) - was duplicated in both
# until this was pulled out.
detect_usb_a_iface() {
    local ifn devpath
    for ifn in /sys/class/net/*; do
        ifn="$(basename "$ifn")"
        case "$ifn" in eth0|lo|br-lan|wlan*) continue ;; esac
        devpath="$(readlink -f "/sys/class/net/$ifn/device" 2>/dev/null)"
        case "$devpath" in *usb*) echo "$ifn"; return ;; esac
    done
}

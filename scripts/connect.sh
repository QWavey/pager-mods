#!/bin/bash
# connect.sh - Simple WiFi client connect for the Pager. Wraps the official
# WIFI_CONNECT / WIFI_WAIT / WIFI_DISCONNECT / WIFI_CLEAR commands and
# figures out the encryption type for you instead of making you specify
# psk/psk2/sae/sae-mixed/open up front.
#
# Usage:
#   connect.sh --name "SSID" --pw "password"     connect (auto-detects security)
#   connect.sh --name "Open Network"               connect to an open network
#   connect.sh --off                                disconnect
#   connect.sh --status                             show current connection
#   connect.sh                                       interactive mode
#
# Options:
#   --name SSID     Network to connect to
#   --pw PASS        Password (omit for an open network)
#   --off             Disconnect (keeps saved config - use --clear to wipe it)
#   --clear            Disconnect AND forget the saved network config
#   --status           Show current client connection status
#   --timeout SECS      How long to wait for association per attempt (default: 20)
#   -y, --yes           Don't prompt for confirmation
#   -h, --help           This help
#
# How "security resolved automatically" works: WIFI_CONNECT needs an
# explicit encryption type. Rather than guessing wrong and failing silently,
# this tries the encryption types in order of how common they actually are
# - psk2, then sae-mixed, then sae, then psk - and stops at the first one
# that actually associates (confirmed via the official WIFI_WAIT command).
# If none work, it tells you plainly instead of leaving you guessing.

set -u
TOOL_NAME="connect.sh"
CFG_NS="connect"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

usage() { print_help "$0"; exit 1; }

SSID=""
PASS=""
DO_OFF=0
DO_CLEAR=0
DO_STATUS=0
TIMEOUT=20

while [ $# -gt 0 ]; do
    case "$1" in
        --name) need_arg "--name" "$#"; SSID="$2"; shift 2 ;;
        --pw) need_arg "--pw" "$#"; PASS="$2"; shift 2 ;;
        --off) DO_OFF=1; shift ;;
        --clear) DO_CLEAR=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        --timeout) need_arg "--timeout" "$#"; TIMEOUT="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BUG FOUND AND FIXED (found via code review; this is the exact gap this
# codebase's own convention already closed everywhere else a numeric CLI
# arg is handed to a blocking command - see bluetooth.sh's --duration/
# --burst/--scan-time/--size and sniff.sh's --duration/--count, both of
# which explicitly call out "every other numeric flag elsewhere ...
# rejects a non-numeric value up front" - --timeout here was never given
# the same check, even though it flows straight into WIFI_WAIT below.
# Verified with a standalone snippet (same `case ... *[!0-9]*` pattern
# already used throughout the codebase): "", "abc", "-5", "12abc" are all
# rejected while "20"/"0" pass. Concretely, an un-validated garbage value
# (e.g. a typo'd `--timeout 3o`) would reach `WIFI_WAIT wlan0cli "$TIMEOUT"`
# and fail there instead of here - and because that failure is
# indistinguishable from a genuine "did not associate" (same `die` message
# below, same exit path), a successful connection could be reported as a
# failure (or vice versa, depending on how WIFI_WAIT itself handles a
# non-numeric argument) with no clue the real problem was the --timeout
# value itself. Reject it immediately with a clear, specific reason instead.
case "$TIMEOUT" in
    ''|*[!0-9]*) die "'--timeout' needs a whole number of seconds (got '$TIMEOUT')." ;;
esac

if [ "$DO_STATUS" = "1" ]; then
    say "WiFi client status:"
    ip -4 addr show wlan0cli 2>/dev/null || echo "  wlan0cli not configured"
    exit 0
fi

if [ "$DO_CLEAR" = "1" ]; then
    confirm "Disconnect and forget the saved WiFi client network?" || die "Aborted."
    # BUG FOUND AND FIXED (found via code review - the same "silent on
    # failure" class this codebase has repeatedly found and fixed elsewhere,
    # e.g. mimic.sh's header lists dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/
    # openap.sh/pcap.sh/.../wigle.sh as already fixed for exactly this -
    # this call had no `||` at all: WIFI_CLEAR failing produced the same
    # "Disconnected and cleared." success message as it actually working,
    # with no way to tell the two apart).
    WIFI_CLEAR wlan0cli && say "Disconnected and cleared." || die "Failed to clear the WiFi client configuration."
    exit 0
fi

if [ "$DO_OFF" = "1" ]; then
    # BUG FOUND AND FIXED (same class as --clear above): wifi.sh (this
    # script's sibling, also in scope) already checks WIFI_DISCONNECT's
    # exit status for the identical command ("Failed to disconnect the
    # WiFi client - it may still be associated.") - this --off branch was
    # the one place in this file still printing "Disconnected" unconditionally
    # regardless of whether WIFI_DISCONNECT actually succeeded.
    WIFI_DISCONNECT wlan0cli && say "Disconnected (config kept - reconnect with connect.sh --name ... again, or just rerun with no args)." || die "Failed to disconnect the WiFi client - it may still be associated."
    exit 0
fi

INTERACTIVE=0
[ -z "$SSID" ] && INTERACTIVE=1

if [ "$INTERACTIVE" = "1" ]; then
    echo "== connect.sh =="
    SSID=$(ask "WiFi network name (SSID)" "$(cfg_get last_ssid)")
    [ -z "$SSID" ] && die "A network name is required."
    if confirm "Does this network have a password?"; then
        PASS=$(ask_secret "Password")
    fi
fi

[ -z "$SSID" ] && die "No SSID given. Use --name or run interactively."

# BUG FOUND AND FIXED (found via code review): last_ssid used to be
# cfg_set BEFORE the connection was even attempted - the exact same
# "persists a value even when the command failed" bug already found and
# fixed in mgmt.sh and openap.sh for last_ssid/last AP state. A failed or
# never-attempted connect would still overwrite the last-known-good SSID
# shown as the interactive prompt default next time. Only persist it once
# WIFI_CONNECT+WIFI_WAIT actually succeed, below.

if [ -z "$PASS" ]; then
    say "Connecting to open network '$SSID'..."
    WIFI_CONNECT wlan0cli "$SSID" open NONE ANY || die "WIFI_CONNECT failed"
    if WIFI_WAIT wlan0cli "$TIMEOUT"; then
        cfg_set last_ssid "$SSID"
        say "Connected."
        exit 0
    fi
    die "Did not associate within ${TIMEOUT}s. Check the SSID is correct and in range."
fi

say "Connecting to '$SSID' - trying encryption types until one works..."
for enc in psk2 sae-mixed sae psk; do
    say "Trying $enc..."
    if WIFI_CONNECT wlan0cli "$SSID" "$enc" "$PASS" ANY && WIFI_WAIT wlan0cli "$TIMEOUT"; then
        cfg_set last_ssid "$SSID"
        say "Connected using $enc."
        exit 0
    fi
done

die "Could not connect to '$SSID' with any of psk2/sae-mixed/sae/psk. Check the password, or the network may use an unsupported/enterprise auth type."

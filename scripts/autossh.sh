#!/bin/bash
# autossh.sh - Maintain a persistent outbound SSH tunnel (e.g. phone-home
# remote access). Wraps AUTOSSH_ENABLE/_DISABLE/_CLEAR, AUTOSSH_CONFIGURE,
# AUTOSSH_ADD_PORT, and SSH_ADD_KNOWN_HOST.
# Syntax confirmed live via AUTOSSH_CONFIGURE --help / AUTOSSH_ADD_PORT --help:
#   AUTOSSH_CONFIGURE disable
#   AUTOSSH_CONFIGURE enable [host] [port] [user] [remoteport] [localport]
#   AUTOSSH_ADD_PORT local|remote [localport] [host] [remoteport]
#   SSH_ADD_KNOWN_HOST [hostname] [keytype] [keydata]
#
# Usage:
#   autossh.sh --enable
#   autossh.sh --disable
#   autossh.sh --clear [-y]
#   autossh.sh --setup HOST PORT USER REMOTEPORT LOCALPORT
#   autossh.sh --add-port local|remote LOCALPORT HOST REMOTEPORT
#   autossh.sh --known-host HOSTNAME KEYTYPE KEYDATA
#   autossh.sh --status        best-effort: is a tunnel actually up right now
#   autossh.sh                interactive mode

set -u
TOOL_NAME="autossh.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review, same class as loot.sh/
# ssidpool.sh): this file never defined a -y/--yes flag despite --clear
# being gated behind confirm() - could never be scripted. Filtered OUT of
# "$@" entirely (not just detected) so it can never accidentally land as a
# positional HOST/PORT/... argument to --setup/--add-port/--known-host.
_filtered_args=()
for _arg in "$@"; do
    case "$_arg" in
        -y|--yes) ASSUME_YES=1 ;;
        *) _filtered_args+=("$_arg") ;;
    esac
done
set -- "${_filtered_args[@]}"

# BUG FOUND AND FIXED (found via code review - the most complete instance
# of the "silent on failure" class already fixed throughout this
# codebase, e.g. mimic.sh/wigle.sh/alert.sh/ringtone.sh - this file had NO
# error handling anywhere at all, not even partially). This matters more
# here than almost anywhere else in the toolkit: AutoSSH is specifically
# for PERSISTENT REMOTE ACCESS - a silently-failed --setup/--enable (bad
# host, bad credentials, a rejected connection) would leave someone
# believing they have a working remote-access tunnel configured when they
# don't, and the gap wouldn't surface until the moment they actually
# needed that access and it wasn't there.
# BIG CHANGE: this whole script could only ever tell you whether the
# ENABLE/CONFIGURE/ADD_PORT commands themselves returned success - never
# whether a tunnel to the configured host is actually, currently up. For a
# script whose entire purpose is a phone-home access-of-last-resort, that's
# the one question that actually matters and the one this couldn't answer -
# "configured successfully" and "actually connected right now" are very
# different things (wrong credentials, an unreachable host, a firewall
# change on the far end all leave the config looking fine while the tunnel
# itself is silently dead). Best-effort only, clearly labeled as such: this
# process-name check has NOT been confirmed live against this exact
# firmware's AutoSSH implementation (the device wasn't reachable while this
# was written) - if it doesn't detect a real tunnel, verify by hand with
# `ps w | grep ssh` rather than trusting a false negative here.
do_status() {
    say "AutoSSH tunnel status (best-effort - see comment above for the caveat):"
    local hits
    hits=$(ps w 2>/dev/null | grep -iE 'autossh|ssh[^|]*-[RL] ' | grep -v grep)
    if [ -n "$hits" ]; then
        say "Tunnel process(es) found - looks like it's up:"
        echo "$hits"
    else
        say "No matching tunnel process found. This could mean AutoSSH is genuinely disabled/disconnected, OR that this best-effort process match just doesn't recognize this firmware's process name - check manually with 'ps w | grep ssh' before assuming the tunnel is really down."
    fi
}

case "${1:-}" in
    --status) do_status ;;
    --enable) AUTOSSH_ENABLE && say "AutoSSH enabled." || die "Failed to enable AutoSSH." ;;
    --disable) AUTOSSH_DISABLE && say "AutoSSH disabled." || die "Failed to disable AutoSSH." ;;
    --clear) confirm "Clear AutoSSH configuration?" && { AUTOSSH_CLEAR && say "Cleared." || die "Failed to clear AutoSSH configuration."; } ;;
    --setup)
        shift
        [ $# -lt 5 ] && die "Need: HOST PORT USER REMOTEPORT LOCALPORT"
        AUTOSSH_CONFIGURE enable "$1" "$2" "$3" "$4" "$5" \
            && say "AutoSSH configured for $1:$2 as $3 (remote:$4 -> local:$5)." \
            || die "Failed to configure AutoSSH for $1:$2 - check host/port/user are correct."
        ;;
    --add-port)
        shift
        [ $# -lt 4 ] && die "Need: local|remote LOCALPORT HOST REMOTEPORT"
        AUTOSSH_ADD_PORT "$1" "$2" "$3" "$4" && say "Port forward added." || die "Failed to add the $1 port forward ($2 -> $3:$4)."
        ;;
    --known-host)
        shift
        [ $# -lt 3 ] && die "Need: HOSTNAME KEYTYPE KEYDATA"
        SSH_ADD_KNOWN_HOST "$1" "$2" "$3" && say "Known host added for $1." || die "Failed to add known host $1."
        ;;
    -h|--help) usage ;;
    "")
        echo "== autossh.sh =="
        echo "1) Enable  2) Disable  3) Clear config  4) Full setup (host/port/user/ports)  5) Status"
        c=$(ask "Choose" "1")
        case "$c" in
            1) AUTOSSH_ENABLE && say "AutoSSH enabled." || err "Failed to enable AutoSSH." ;;
            2) AUTOSSH_DISABLE && say "AutoSSH disabled." || err "Failed to disable AutoSSH." ;;
            3) confirm "Clear AutoSSH configuration?" && { AUTOSSH_CLEAR && say "Cleared." || err "Failed to clear AutoSSH configuration."; } ;;
            5) do_status ;;
            4)
                h=$(ask "Remote host" ""); p=$(ask "Remote SSH port" "22")
                u=$(ask "Remote username" ""); rp=$(ask "Remote port (on the far end)" "2222")
                lp=$(ask "Local port (usually 22)" "22")
                AUTOSSH_CONFIGURE enable "$h" "$p" "$u" "$rp" "$lp" \
                    && say "AutoSSH configured for $h:$p as $u (remote:$rp -> local:$lp)." \
                    || err "Failed to configure AutoSSH for $h:$p - check host/port/user are correct."
                ;;
            *) say "Nothing to do." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

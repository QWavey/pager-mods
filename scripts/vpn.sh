#!/bin/bash
# vpn.sh - Configure/enable/disable OpenVPN or Wireguard. Wraps
# OPENVPN_CONFIGURE/_ENABLE/_DISABLE and WIREGUARD_CONFIGURE/_ENABLE/_DISABLE.
# Syntax confirmed live via OPENVPN_CONFIGURE --help / WIREGUARD_CONFIGURE --help:
#   OPENVPN_CONFIGURE disable
#   OPENVPN_CONFIGURE enable [config file]
#   WIREGUARD_CONFIGURE disable
#   WIREGUARD_CONFIGURE enable [wg.conf]
#   WIREGUARD_CONFIGURE enable [server-ip] [server-port] [server-pubkey] \
#       [server-psk|NONE] [private-key|AUTO] [local-ip] [ipv4-nets|NONE] [ipv6-nets|NONE]
#
# Usage:
#   vpn.sh openvpn --enable [config-file]
#   vpn.sh openvpn --disable
#   vpn.sh wireguard --enable [wg.conf]
#   vpn.sh wireguard --enable-full SERVER_IP SERVER_PORT SERVER_PUBKEY SERVER_PSK PRIVATE_KEY LOCAL_IP IPV4_NETS IPV6_NETS
#   vpn.sh wireguard --disable
#   vpn.sh --status         best-effort: is a VPN actually up right now
#   vpn.sh                interactive mode

set -u
TOOL_NAME="vpn.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

KIND="${1:-}"; shift 2>/dev/null || true
ACTION="${1:-}"; shift 2>/dev/null || true

# BUG FOUND AND FIXED (found via code review, same class already fixed in
# dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/reconsession.sh/
# ssidpool.sh/screen.sh): every branch below printed a success message
# unconditionally regardless of the underlying OPENVPN_CONFIGURE/
# WIREGUARD_CONFIGURE command's real exit code - arguably worse here than
# most of those siblings, since a VPN that silently failed to enable while
# being reported as "enabled" could leave traffic going out unprotected.
run_openvpn() {
    case "$ACTION" in
        --enable)
            { if [ $# -ge 1 ]; then OPENVPN_CONFIGURE enable "$1"; else OPENVPN_CONFIGURE enable; fi; } \
                && say "OpenVPN enabled." || die "Failed to enable OpenVPN."
            ;;
        --disable) OPENVPN_CONFIGURE disable && say "OpenVPN disabled." || die "Failed to disable OpenVPN." ;;
        *) err "Unknown openvpn action '$ACTION'"; usage ;;
    esac
}

run_wireguard() {
    case "$ACTION" in
        --enable)
            [ $# -lt 1 ] && die "Give a wg.conf file path."
            WIREGUARD_CONFIGURE enable "$1" && say "Wireguard enabled." || die "Failed to enable Wireguard."
            ;;
        --enable-full)
            [ $# -lt 8 ] && die "Need: SERVER_IP SERVER_PORT SERVER_PUBKEY SERVER_PSK PRIVATE_KEY LOCAL_IP IPV4_NETS IPV6_NETS"
            WIREGUARD_CONFIGURE enable "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" && say "Wireguard enabled." || die "Failed to enable Wireguard."
            ;;
        --disable) WIREGUARD_CONFIGURE disable && say "Wireguard disabled." || die "Failed to disable Wireguard." ;;
        *) err "Unknown wireguard action '$ACTION'"; usage ;;
    esac
}

# BIG CHANGE: this file's own header comment above already calls out that
# a silently-failed VPN enable is worse here than in most sibling scripts -
# real traffic could believe it's protected when it isn't - but until now
# the only signal was OPENVPN_CONFIGURE/WIREGUARD_CONFIGURE's own exit
# code at enable-time, never a way to check again later whether it's
# ACTUALLY still up. Best-effort, clearly labeled: OpenVPN via a real
# process check (ps), Wireguard via 'wg show' (the standard wireguard-
# tools command) if installed - neither guessed at unconfirmed platform
# internals.
do_status() {
    say "VPN status (best-effort):"
    if ps w 2>/dev/null | grep -q '[o]penvpn'; then
        say "OpenVPN: a live 'openvpn' process was found - looks up."
    else
        say "OpenVPN: no live 'openvpn' process found - looks down (or was never enabled)."
    fi
    if command -v wg >/dev/null 2>&1; then
        if wg show 2>/dev/null | grep -q .; then
            say "Wireguard: 'wg show' reports an active interface - looks up."
        else
            say "Wireguard: 'wg show' reports nothing active - looks down."
        fi
    else
        say "Wireguard: 'wg' tool not found on this device - can't check status this way."
    fi
}

case "$KIND" in
    --status) do_status ;;
    openvpn) run_openvpn "$@" ;;
    wireguard) run_wireguard "$@" ;;
    -h|--help) usage ;;
    "")
        echo "== vpn.sh =="
        k=$(ask "VPN type (openvpn/wireguard/status)" "wireguard")
        # BUG FOUND AND FIXED (found via code review, confirmed with an
        # isolated repro): every branch below that dispatches on $k used
        # `if [ "$k" = "openvpn" ]; then run_openvpn; else run_wireguard;
        # fi` - so a typo'd/unrecognized VPN type (e.g. "opnvpn") was never
        # rejected, it silently fell into the `else` and got treated as
        # wireguard. Reproduced standalone: with k="opnvpn" that exact
        # if/else prints "ROUTED: wireguard". For a VPN wrapper this is
        # worse than cosmetic - a user asking to (re)configure openvpn with
        # a typo would have wireguard silently (re)configured instead,
        # while believing openvpn was acted on. The CLI path (`case "$KIND"
        # in openvpn|wireguard|*) die ...`) and filters.sh's own run_filter
        # already validate their type argument explicitly with a die-on-
        # unknown default - this brings the interactive block in line with
        # that same established pattern instead of the old silent-wrong-
        # fallback behavior.
        case "$k" in
            status) do_status; exit 0 ;;
            openvpn|wireguard) : ;;
            *) die "Unknown VPN type '$k' (expected openvpn, wireguard, or status)" ;;
        esac
        a=$(ask "Action (--enable/--disable)" "--disable")
        KIND="$k"; ACTION="$a"
        if [ "$a" = "--enable" ]; then
            cfg=$(ask "Config file path (blank = use existing)" "")
            if [ -n "$cfg" ]; then
                if [ "$k" = "openvpn" ]; then run_openvpn "$cfg"; else run_wireguard "$cfg"; fi
            else
                if [ "$k" = "openvpn" ]; then run_openvpn; else die "wireguard --enable needs a config file."; fi
            fi
        else
            if [ "$k" = "openvpn" ]; then run_openvpn; else run_wireguard; fi
        fi
        ;;
    *) err "Unknown VPN type '$KIND' (expected openvpn or wireguard)"; usage ;;
esac

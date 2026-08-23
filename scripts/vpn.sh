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
# IMPROVEMENT (new feature - connection duration in --status, exactly the
# kind of thing this file's own header comment on do_status names as the
# one question "actually up" alone doesn't answer): knowing a VPN process
# is alive doesn't say whether it's a fresh connection or one that's been
# stable for days - genuinely useful at a glance, and the two helpers below
# only ever read already-relied-upon procfs/wg-tools state, no new
# dependency or guesswork beyond what do_status already does.
#
# fmt_duration SECONDS - compact "3d 4h" / "2h 15m" / "45m 12s" / "9s"
# elapsed-time formatting, shared by both checks below.
fmt_duration() {
    local s="${1:-0}" d h m sec
    case "$s" in ''|*[!0-9]*) echo "?"; return 1 ;; esac
    d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60)); sec=$((s % 60))
    if [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
    elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
    elif [ "$m" -gt 0 ]; then echo "${m}m ${sec}s"
    else echo "${sec}s"
    fi
}

# openvpn_uptime PID - best-effort process uptime via /proc/PID/stat's
# starttime field (in clock ticks since boot) and /proc/uptime - both
# already relied on elsewhere in this toolkit (pid_running() in
# lib/common.sh reads /proc/$pid/cmdline; several incident comments in that
# same file assume procfs is present), not a new dependency. Splits on the
# LAST ") " rather than a fixed field index, since /proc/PID/stat's own
# "(comm)" field can itself contain spaces or parentheses - a fixed-index
# split would silently misalign every field after it for such a process
# name. Not confirmed live against this exact firmware's clock-tick
# resolution; if the number looks wrong, cross-check with 'ps w' by hand.
openvpn_uptime() {
    local pid="$1" stat rest starttime hz now_uptime
    [ -r "/proc/$pid/stat" ] && [ -r /proc/uptime ] || return 1
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest="${stat##*) }"
    starttime=$(echo "$rest" | awk '{print $20}')
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    hz=$(getconf CLK_TCK 2>/dev/null)
    case "$hz" in ''|*[!0-9]*) hz=100 ;; esac
    # BUG FOUND AND FIXED (found via code review, confirmed with an
    # isolated repro): the case guard above only rejects an empty or
    # non-digit $hz - it happily accepts a literal "0", which passes
    # `*[!0-9]*` (every character in "0" IS a digit) even though 0 is
    # useless as a divisor. Repro of the exact awk line below with hz=0:
    #   awk -v u="1000" -v st="500" -v hz="0" \
    #     'BEGIN{v=u-(st/hz); if (v<0) v=0; printf "%d", v}'
    #   -> awk: cmd. line:1: fatal: division by zero attempted (exit 2)
    # do_status calls this function as
    # `ovpn_up=$(openvpn_uptime "$ovpn_pid" 2>/dev/null)`, so the fatal
    # error is swallowed and uptime is just silently omitted rather than
    # crashing the script - but that's accidental, not by design, and an
    # unguarded division is worth closing the same way every other numeric
    # input in this function already is. getconf should never actually
    # print "0" for CLK_TCK, but neither should it print garbage, and the
    # existing guard already defends against that - this closes the one
    # numeric value ("0") that slips past it.
    [ "$hz" -eq 0 ] 2>/dev/null && hz=100
    now_uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    case "$now_uptime" in ''|*[!0-9.]*) return 1 ;; esac
    awk -v u="$now_uptime" -v st="$starttime" -v hz="$hz" \
        'BEGIN{v=u-(st/hz); if (v<0) v=0; printf "%d", v}'
}

# wg_handshakes - Wireguard has no single "interface up since" figure the
# way a plain process does, so this reports the standard proxy: how long
# ago each peer's last handshake was, straight from 'wg show ... latest-
# handshakes' (the documented wireguard-tools command for exactly this,
# already gated behind the same `command -v wg` check do_status uses).
# A peer that has never handshaked reports timestamp 0, called out
# explicitly rather than printed as a nonsensical multi-decade duration.
# BUG FOUND AND FIXED (found via code review of the new procfs/wg-tools
# status code, confirmed with an isolated repro): the $ts field read from
# 'wg show all latest-handshakes' went straight into bash arithmetic
# (`ago=$((now - ts))`) with no numeric validation, unlike every other
# externally-sourced numeric field in this file (starttime and now_uptime in
# openvpn_uptime(), and fmt_duration()'s own input, are all case-guarded
# before arithmetic). Repro: feed the while-loop a line whose 3rd field
# isn't numeric (e.g. wg-tools output that's malformed, truncated, or from a
# future/older format) - `ago=$((now - ts))` with ts="notanumber" doesn't
# just fail cleanly, bash's arithmetic evaluator re-parses a non-numeric
# operand AS A VARIABLE NAME, and under this script's `set -u` an undefined
# one aborts with "notanumber: unbound variable". Standalone test
# (/tmp/wgtest.sh, mirroring this exact function against a 2-line piped
# input where only the FIRST peer's timestamp is bad):
#   BEFORE wg_handshakes
#   line 24: notanumber: unbound variable
#   AFTER wg_handshakes, exit=1
#   SCRIPT CONTINUES TO END
# Because the loop is the read side of a pipe, the crash only kills that
# subshell rather than all of vpn.sh - but it kills it immediately, so the
# SECOND peer (a perfectly good, later line in the same wg output) never
# gets read or printed either, and do_status shows no error at all: it
# already said "Wireguard: ... looks up." beforehand and simply continues,
# silently under-reporting how many peers are actually connected. For a
# security-relevant status command that is materially misleading, not
# cosmetic. Fixed by validating $ts the same way every other numeric field
# in this file already is, and reporting (not skipping) a malformed line
# instead of letting it take down the rest of the listing.
wg_handshakes() {
    local now line iface peer ts ago
    now=$(date +%s 2>/dev/null) || return 1
    wg show all latest-handshakes 2>/dev/null | while read -r iface peer ts; do
        [ -n "$iface" ] || continue
        case "${ts:-0}" in
            0) say "  $iface peer ${peer:0:12}...: no handshake yet" ;;
            *[!0-9]*) say "  $iface peer ${peer:0:12}...: unrecognized handshake timestamp '$ts'" ;;
            *)
                ago=$((now - ts))
                say "  $iface peer ${peer:0:12}...: last handshake $(fmt_duration "$ago") ago"
                ;;
        esac
    done
}

do_status() {
    say "VPN status (best-effort):"
    if ps w 2>/dev/null | grep -q '[o]penvpn'; then
        say "OpenVPN: a live 'openvpn' process was found - looks up."
        ovpn_pid=$(ps w 2>/dev/null | awk '/[o]penvpn/ {print $1; exit}')
        if [ -n "${ovpn_pid:-}" ]; then
            ovpn_up=$(openvpn_uptime "$ovpn_pid" 2>/dev/null)
            [ -n "$ovpn_up" ] && say "  process uptime: $(fmt_duration "$ovpn_up") (PID $ovpn_pid)"
        fi
    else
        say "OpenVPN: no live 'openvpn' process found - looks down (or was never enabled)."
    fi
    if command -v wg >/dev/null 2>&1; then
        if wg show 2>/dev/null | grep -q .; then
            say "Wireguard: 'wg show' reports an active interface - looks up."
            wg_handshakes
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

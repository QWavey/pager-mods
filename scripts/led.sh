#!/bin/bash
# led.sh - Control the Pager's LEDs. Wraps LED and DPADLED_CONFIG.
# Syntax confirmed live via LED --help / DPADLED_CONFIG --help.
#
# LED [color] [pattern]   e.g. LED R SLOW, LED W SOLID
#   colors:   R G B Y C M W (or off via the OFF state)
#   patterns: SOLID SLOW FAST VERYFAST SINGLE DOUBLE TRIPLE QUAD QUIN
#             ISINGLE IDOUBLE ITRIPLE IQUAD IQUIN SUCCESS
# LED [state]             e.g. LED ATTACK, LED FAIL, LED OFF
#   states: SETUP FAIL FAIL1 FAIL2 FAIL3 ATTACK STAGE1..5 SPECIAL SPECIAL1..5
#           CLEANUP FINISH OFF
# DPADLED_CONFIG [color]  one of: red green blue cyan yellow magenta white off
#
# Usage:
#   led.sh --set COLOR [PATTERN]     e.g. led.sh --set R SLOW
#   led.sh --state STATE               e.g. led.sh --state ATTACK
#   led.sh --off
#   led.sh --dpad COLOR                  red/green/blue/cyan/yellow/magenta/white/off
#   led.sh                                 interactive mode

set -u
TOOL_NAME="led.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BIG CHANGE (found via code review): every other command wrapper in this
# toolkit reports whether the underlying platform call actually succeeded
# (mimic.sh/dns.sh/gps.sh/mgmt.sh/openap.sh/... all document fixing exactly
# this) - this file was the one wrapper left with NO feedback of any kind,
# success or failure. Unlike examine.sh's PINEAPPLE_EXAMINE_CHANNEL (which
# has a confirmed, documented reason NOT to check - it doesn't reliably
# signal failure), there's no such known reason for LED/DPADLED_CONFIG here,
# so this brings led.sh in line with the rest of the toolkit's convention
# rather than leaving it as a silent outlier.
# IMPROVEMENT (round 2, genuine improvement pass - not a bug hunt): every
# failure message below used to be a bare "Failed to set the LED." with no
# hint of WHY - the caller is left to go re-read this file's own header
# comment to find out what a valid color/pattern/state actually looks like.
# This file's header already documents the exact valid values (confirmed
# live via LED --help / DPADLED_CONFIG --help), so folding them straight
# into the error text costs nothing and saves that round trip. Kept as
# pure message text, not a pre-flight whitelist check: the device is still
# the one source of truth for what's actually valid (a future firmware
# update adding a new color/pattern/state would silently break a hardcoded
# client-side whitelist, but can never break "the call failed, here's what
# used to be valid" text).
LED_VALID_COLORS="R G B Y C M W"
LED_VALID_PATTERNS="SOLID SLOW FAST VERYFAST SINGLE DOUBLE TRIPLE QUAD QUIN ISINGLE IDOUBLE ITRIPLE IQUAD IQUIN SUCCESS"
LED_VALID_STATES="SETUP FAIL FAIL1 FAIL2 FAIL3 ATTACK STAGE1..5 SPECIAL SPECIAL1..5 CLEANUP FINISH OFF"
LED_VALID_DPAD="red green blue cyan yellow magenta white off"

case "${1:-}" in
    --set) shift; [ $# -eq 0 ] && die "Give a color (and optional pattern)."; LED "$@" && say "LED set." || err "Failed to set the LED with '$*' - valid colors: $LED_VALID_COLORS; valid patterns: $LED_VALID_PATTERNS" ;;
    --state) shift; [ $# -eq 0 ] && die "Give a state name (ATTACK/FAIL/SETUP/etc)."; LED "$1" && say "LED state set to $1." || err "Failed to set LED state '$1' - valid states: $LED_VALID_STATES" ;;
    --off) LED OFF && say "LED off." || err "Failed to turn the LED off." ;;
    --dpad) shift; [ $# -eq 0 ] && die "Give a color (red/green/blue/cyan/yellow/magenta/white/off)."; DPADLED_CONFIG "$1" && say "D-pad LED set to $1." || err "Failed to set the D-pad LED to '$1' - valid D-pad colors: $LED_VALID_DPAD" ;;
    -h|--help) usage ;;
    "")
        echo "== led.sh =="
        echo "1) Set color+pattern  2) Set named state  3) Off  4) DPAD LED color"
        c=$(ask "Choose" "3")
        case "$c" in
            1) col=$(ask "Color (R/G/B/Y/C/M/W)" "W"); pat=$(ask "Pattern (SOLID/SLOW/FAST/...)" "SOLID"); LED "$col" "$pat" && say "LED set." || err "Failed to set the LED with '$col $pat' - valid colors: $LED_VALID_COLORS; valid patterns: $LED_VALID_PATTERNS" ;;
            2) st=$(ask "State (SETUP/FAIL/ATTACK/SPECIAL/CLEANUP/FINISH/OFF)" "ATTACK"); LED "$st" && say "LED state set to $st." || err "Failed to set LED state '$st' - valid states: $LED_VALID_STATES" ;;
            4) col=$(ask "DPAD color (red/green/blue/cyan/yellow/magenta/white/off)" "off"); DPADLED_CONFIG "$col" && say "D-pad LED set to $col." || err "Failed to set the D-pad LED to '$col' - valid D-pad colors: $LED_VALID_DPAD" ;;
            *) LED OFF && say "LED off." || err "Failed to turn the LED off." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

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

case "${1:-}" in
    --set) shift; [ $# -eq 0 ] && die "Give a color (and optional pattern)."; LED "$@" ;;
    --state) shift; [ $# -eq 0 ] && die "Give a state name (ATTACK/FAIL/SETUP/etc)."; LED "$1" ;;
    --off) LED OFF ;;
    --dpad) shift; [ $# -eq 0 ] && die "Give a color (red/green/blue/cyan/yellow/magenta/white/off)."; DPADLED_CONFIG "$1" ;;
    -h|--help) usage ;;
    "")
        echo "== led.sh =="
        echo "1) Set color+pattern  2) Set named state  3) Off  4) DPAD LED color"
        c=$(ask "Choose" "3")
        case "$c" in
            1) col=$(ask "Color (R/G/B/Y/C/M/W)" "W"); pat=$(ask "Pattern (SOLID/SLOW/FAST/...)" "SOLID"); LED "$col" "$pat" ;;
            2) st=$(ask "State (SETUP/FAIL/ATTACK/SPECIAL/CLEANUP/FINISH/OFF)" "ATTACK"); LED "$st" ;;
            4) col=$(ask "DPAD color (red/green/blue/cyan/yellow/magenta/white/off)" "off"); DPADLED_CONFIG "$col" ;;
            *) LED OFF ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

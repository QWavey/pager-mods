#!/bin/bash
# report.sh - Generate a single readable engagement report from everything
# this toolkit has captured this session: handshakes, LAN scans, sniff
# captures, deadnet discoveries, wardriving logs, and loot in general.
# Nothing invented here - it just reads and summarizes files this toolkit
# (and stock PineAP) already wrote to /root/loot/.
#
# Usage:
#   report.sh                     print the report to stdout
#   report.sh --save                save it to /root/loot/reports/report-TIMESTAMP.md
#   report.sh --save --archive        save it AND archive all current loot after
#   -h, --help                          this help

set -u
TOOL_NAME="report.sh"
LOOT_ROOT="/root/loot"
REPORT_DIR="$LOOT_ROOT/reports"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

DO_SAVE=0
DO_ARCHIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --save) DO_SAVE=1; shift ;;
        --archive) DO_ARCHIVE=1; shift ;;
        -h|--help) usage ;;
        *) err "Unknown argument: $1"; usage ;;
    esac
done

# BUG FOUND AND FIXED (found via code review): --archive only ever took
# effect inside the "$DO_SAVE" = "1" branch below - passing --archive
# without --save silently printed the report and archived nothing, with
# no indication the flag was ignored. Fail loudly instead.
[ "$DO_ARCHIVE" = "1" ] && [ "$DO_SAVE" != "1" ] && die "--archive requires --save (e.g. report.sh --save --archive)."

count_files() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

# count_matching / count_files_excluding DIR PATTERN - used to separate
# pc_link.sh's captures from generic sniff.sh ones. Both actually land in
# the SAME directory (pc_link.sh delegates to sniff.sh's own capture
# pipeline, it has no loot directory of its own) - pc_link.sh now names
# its files "pclink-*" specifically so they're distinguishable here
# instead of just disappearing into (or double-counting against) the
# generic sniff total.
count_matching() {
    local dir="$1" pattern="$2"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}
count_files_excluding() {
    local dir="$1" exclude="$2"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -maxdepth 1 -type f ! -name "$exclude" 2>/dev/null | wc -l | tr -d ' '
}

gen_report() {
    local now
    now=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown time")

    echo "# Pager Engagement Report"
    echo "Generated: $now"
    echo

    echo "## WiFi handshakes"
    local n
    n=$(count_files "$LOOT_ROOT/handshakes")
    echo "- $n file(s) in $LOOT_ROOT/handshakes/"
    if [ "$n" -gt 0 ]; then
        find "$LOOT_ROOT/handshakes" -type f 2>/dev/null | sed 's/^/  - /'
    fi
    echo

    echo "## LAN scans (LanScan.sh)"
    n=$(count_files "$LOOT_ROOT/lanscan")
    echo "- $n file(s) in $LOOT_ROOT/lanscan/"
    if [ "$n" -gt 0 ]; then
        local latest
        latest=$(find "$LOOT_ROOT/lanscan" -type f -name '*.txt' 2>/dev/null | sort | tail -1)
        if [ -n "$latest" ]; then
            echo "  Most recent: $latest"
            local hosts
            # BUG FOUND AND FIXED (found via code review, confirmed by
            # direct testing): `grep -c` exits 1 (not 0) when the count is
            # genuinely zero, even though it still correctly prints "0" to
            # stdout - so the `|| echo 0` fallback ALSO ran in that exact
            # case, appending a second "0" and leaving $hosts as the
            # two-line string "0\n0" instead of just "0" (confirmed via a
            # standalone test: a file with no matching lines produced
            # hosts="0\n0", breaking this line's formatting). Only fall
            # back to 0 when grep produced no output at all (a real error,
            # e.g. the file vanished/unreadable), not based on its exit
            # status.
            hosts=$(grep -c "^Nmap scan report for" "$latest" 2>/dev/null)
            hosts="${hosts:-0}"
            echo "  Hosts found: $hosts"
        fi
    fi
    echo

    echo "## DeadNet LAN discovery"
    n=$(count_files "$LOOT_ROOT/deadnet")
    echo "- $n file(s) in $LOOT_ROOT/deadnet/"
    if [ "$n" -gt 0 ]; then
        local latest
        latest=$(find "$LOOT_ROOT/deadnet" -type f -name 'discovery-*.txt' 2>/dev/null | sort | tail -1)
        if [ -n "$latest" ]; then
            echo "  Most recent discovery: $latest"
            echo "  Hosts:"
            sed 's/^/    - /' "$latest" 2>/dev/null
        fi
    fi
    echo

    echo "## Packet captures (sniff.sh)"
    n=$(count_files_excluding "$LOOT_ROOT/sniff" "pclink-*")
    echo "- $n file(s) in $LOOT_ROOT/sniff/ (excludes PC Link captures, counted separately below)"
    if [ "$n" -gt 0 ]; then
        # BUG FOUND AND FIXED: this listing was filtered to "*.pcap" while
        # the count above (count_files_excluding) matches ANY file - a
        # capture saved via `sniff.sh --output somename.log` (no .pcap
        # extension enforced there) would be counted in $n but never show
        # up in this list, so the number and the itemized list beneath it
        # could disagree. Match the same "any file" rule the count uses.
        find "$LOOT_ROOT/sniff" -maxdepth 1 -type f ! -name 'pclink-*' 2>/dev/null | sed 's/^/  - /'
    fi
    echo

    echo "## WiFi packet captures (WIFI_PCAP)"
    n=$(count_files "$LOOT_ROOT/pcap")
    echo "- $n file(s) in $LOOT_ROOT/pcap/"
    echo

    echo "## Bluetooth (bluetooth.sh)"
    n=$(count_files "$LOOT_ROOT/bluetooth")
    echo "- $n file(s) in $LOOT_ROOT/bluetooth/"
    if [ "$n" -gt 0 ]; then
        find "$LOOT_ROOT/bluetooth" -name '*.txt' 2>/dev/null | sed 's/^/  - /'
    fi
    echo

    echo "## PC link captures (pc_link.sh)"
    # BUG FOUND AND FIXED: pc_link.sh has no loot directory of its own -
    # it always delegates to sniff.sh's capture pipeline, which writes
    # into $LOOT_ROOT/sniff/. This used to count $LOOT_ROOT/pclink/, a
    # directory nothing ever wrote to - always reported 0 regardless of
    # how many real PC-link captures had been taken. pc_link.sh now names
    # its output files "pclink-*" inside sniff's own directory so they're
    # both real and separable from generic sniff captures.
    n=$(count_matching "$LOOT_ROOT/sniff" "pclink-*")
    echo "- $n file(s) in $LOOT_ROOT/sniff/ (pclink-*.pcap)"
    if [ "$n" -gt 0 ]; then
        find "$LOOT_ROOT/sniff" -maxdepth 1 -name 'pclink-*' 2>/dev/null | sed 's/^/  - /'
    fi
    echo

    echo "## Wardriving (Wigle)"
    n=$(count_files "$LOOT_ROOT/wigle")
    echo "- $n file(s) in $LOOT_ROOT/wigle/"
    echo

    echo "## Payload runs (PayloadRunner.sh)"
    n=$(count_files "$LOOT_ROOT/payload-runs")
    echo "- $n log(s) in $LOOT_ROOT/payload-runs/"
    echo

    echo "## Archive"
    n=$(count_files "$LOOT_ROOT/archive")
    echo "- $n file(s) already archived in $LOOT_ROOT/archive/"
    echo

    # BIG CHANGE: every section above is a hardcoded, named directory - the
    # exact same class of drift this file's own bug-fix history already
    # shows happened twice for real (pc_link's captures counting a
    # directory nothing wrote to; wigle/payload-runs/archive missing
    # entirely from an earlier version). Rather than trust that the list
    # above stays complete forever, scan for any loot subdirectory NOT
    # explicitly covered by a section above and call it out - so a future
    # new capture type doesn't just silently vanish from this report the
    # way past ones already did before being caught.
    local known="handshakes lanscan deadnet sniff pcap bluetooth wigle payload-runs archive reports"
    local other_found=0 d base cnt
    for d in "$LOOT_ROOT"/*/; do
        [ -d "$d" ] || continue
        base=$(basename "$d")
        case " $known " in *" $base "*) continue ;; esac
        if [ "$other_found" = "0" ]; then
            echo "## Other loot (not covered by a section above)"
            other_found=1
        fi
        cnt=$(count_files "$d")
        echo "- $base/: $cnt file(s) - this report needs a proper section for it if it's a real, ongoing capture type"
    done
    [ "$other_found" = "1" ] && echo

    local total_size
    total_size=$(du -sh "$LOOT_ROOT" 2>/dev/null | awk '{print $1}')
    echo "## Total loot size"
    echo "- $total_size"
}

if [ "$DO_SAVE" = "1" ]; then
    mkdir -p "$REPORT_DIR"
    STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo report)
    OUT="$REPORT_DIR/report-${STAMP}.md"
    gen_report > "$OUT"
    say "Report saved to $OUT"
    cat "$OUT"
    if [ "$DO_ARCHIVE" = "1" ]; then
        say "Archiving current loot..."
        # BUG FOUND AND FIXED (found via code review, same class already
        # fixed in dns.sh/dnsspoof.sh/gps.sh/mgmt.sh/openap.sh/pcap.sh/
        # reconsession.sh/ssidpool.sh/screen.sh/vpn.sh/wigle.sh): this
        # printed "Archived." unconditionally regardless of
        # PINEAPPLE_LOOT_ARCHIVE's real exit code.
        PINEAPPLE_LOOT_ARCHIVE && say "Archived." || err "Failed to archive loot (the report above was still saved to $OUT)."
    fi
else
    gen_report
fi

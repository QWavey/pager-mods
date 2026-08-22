#!/usr/bin/env python3
"""
setup.py - One-shot installer for the Pager Toolkit.

Run this from YOUR computer (not the Pager). Reads config.txt for the
device's IP and SSH password, then:

  1. Uploads every script under scripts/ to /root/scripts/ on the Pager
  2. Creates the extensionless command aliases (wifi -> wifictl, etc.,
     skipping names that collide with real system binaries)
  3. Adds /root/scripts to PATH via ~/.profile (idempotent - won't
     duplicate the line on repeat runs)
  4. Installs python3 via opkg (skip with --skip-python3)
  5. Installs scapy via opkg (needed by deadnet.sh - skip with --skip-scapy)
  6. Uploads every payload under payloads/ to /root/payloads/, with the
     correct structure for the on-device Payloads screen to actually see
     them: nested inside an EXISTING category folder (never its own new
     top-level category - the dashboard silently ignores those), payload
     directories chmod 700, payload.sh chmod 644 (not executable - real
     Hak5 payloads never are), and a matching _hak5_manifest.json
     generated per payload (the format the dashboard actually reads
     installed-payload metadata from). Then force-restarts the pineapple
     app process so it picks up the new payload list (see the README for
     why a plain `/etc/init.d/pineapplepager restart` does NOT work - its
     own stop_service() has a bug and stops the wrong daemon).
  7. Sets a Control Panel access token (or keeps the existing one)
  8. Prints a summary

Safe to re-run any time (e.g. after a factory reset) - every step is
idempotent. This deliberately does NOT touch any /etc/ system config
beyond the one PATH line in ~/.profile (a normal, reversible shell
convenience - not a system-wide library/linker change).

INCREMENTAL BY DEFAULT: a local cache (.deploy_state.json, next to this
file) remembers the sha1 of every file/payload last actually uploaded.
Re-running only pushes what changed since then - no more re-uploading all
~60 files (and bouncing the pineapple app process) on every single run.
Use --force to bypass the cache and push everything regardless (e.g.
after a factory reset, where the device's own copy no longer matches what
the cache thinks it has).

See sync.py for a wrapper that waits for the device to come back on SSH
(useful right after a reboot/reconnect) and then runs this incrementally.

Usage:
    python3 setup.py                  (reads config.txt next to this file)
    python3 setup.py --config other.txt
    python3 setup.py --skip-python3
    python3 setup.py --skip-scapy
    python3 setup.py --skip-payloads
    python3 setup.py --force            (ignore the incremental cache, push everything)
    python3 setup.py --quiet            (only print section headers, not every file)
    python3 setup.py --dry-run          (show what WOULD be uploaded/pruned - no
                                          connection made, nothing is changed. Works
                                          even with no config.txt / device offline.)

config.txt format:
    ip=172.16.52.1
    password=8017
"""
import argparse
import hashlib
import io
import json
import os
import sys
import time
from datetime import datetime, timezone

try:
    import paramiko
except ImportError:
    print("This script needs the 'paramiko' package. Install it with:")
    print("  pip install paramiko")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
REMOTE_ROOT = "/root/scripts"
STATE_FILE = os.path.join(HERE, ".deploy_state.json")

# Names that collide with real OpenWRT/system binaries - do NOT alias these.
COLLISION_NAMES = {"wifi": "wifictl", "autossh": "autosshctl", "reset": "devreset"}


def load_state():
    # Maps a stable key (remote path) -> sha1 of the content last
    # successfully uploaded there, so re-runs only push what actually
    # changed instead of re-uploading all ~60 files (and restarting the
    # pineapple app / touching payload manifests) every single time.
    # Missing/corrupt state just means "upload everything once" - never a
    # hard failure, since a stale or absent cache should degrade to the
    # old full-reupload behavior, not break the install.
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state):
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)


def read_config(path):
    cfg = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            cfg[key.strip()] = val.strip()
    if "ip" not in cfg or "password" not in cfg:
        print(f"ERROR: {path} must contain 'ip=' and 'password=' lines.")
        sys.exit(1)
    return cfg


# IMPROVEMENT (new feature): --dry-run needs to answer "what would this run
# actually do" using ONLY the same sha1-vs-state comparison upload_tree/
# deploy_payloads already do - but without ever touching sftp/paramiko, so
# it can run fully offline (no device connection at all, nothing to break
# if the device is unreachable). Deliberately a separate read-only function
# rather than threading a `dry_run` flag through upload_tree/deploy_payloads
# themselves: those two are already-verified, side-effecting code paths (SFTP
# writes, chmod, killing/restarting the pineapple app process) - duplicating
# just the read/hash/compare logic here keeps the real upload path completely
# unmodified and untouched, rather than risking a `dry_run` branch drifting
# from or accidentally short-circuiting the tested behavior.
def plan_scripts(local_root, remote_root, state, force=False):
    """Read-only preview of what upload_tree() would do: same walk/hash/skip
    logic, same SKIP_DIRS/SKIP_SUFFIXES, but no sftp calls of any kind."""
    SKIP_DIRS = {"__pycache__", ".git"}
    SKIP_SUFFIXES = (".pyc", ".pyo")

    to_upload = []
    unchanged = 0
    seen_remote_paths = set()
    for dirpath, dirnames, filenames in os.walk(local_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel = os.path.relpath(dirpath, local_root)
        remote_dir = remote_root if rel == "." else remote_root + "/" + rel.replace(os.sep, "/")
        for fname in filenames:
            if fname.endswith(SKIP_SUFFIXES):
                continue
            local_path = os.path.join(dirpath, fname)
            remote_path = remote_dir + "/" + fname
            seen_remote_paths.add(remote_path)
            with open(local_path, "rb") as f:
                content = f.read()
            digest = hashlib.sha1(content.replace(b"\r\n", b"\n")).hexdigest()
            if not force and state.get(remote_path) == digest:
                unchanged += 1
            else:
                to_upload.append(remote_path)

    prefix = remote_root + "/"
    stale = sorted(p for p in state if p.startswith(prefix) and p not in seen_remote_paths)
    return sorted(to_upload), unchanged, stale


def plan_payloads(local_payloads_root, state, force=False):
    """Read-only preview of what deploy_payloads() would do: same content-
    hash + PAYLOAD_META-hash cache key, but no sftp/exec_command calls."""
    if not os.path.isdir(local_payloads_root):
        return [], 0

    to_upload = []
    unchanged = 0
    for category in sorted(os.listdir(local_payloads_root)):
        cat_path = os.path.join(local_payloads_root, category)
        if not os.path.isdir(cat_path):
            continue
        for payload_name in sorted(os.listdir(cat_path)):
            payload_local = os.path.join(cat_path, payload_name)
            payload_sh_local = os.path.join(payload_local, "payload.sh")
            if not os.path.isfile(payload_sh_local):
                continue

            remote_dir = f"/root/payloads/user/{category}/{payload_name}"
            meta = PAYLOAD_META.get(payload_name, {
                "title": payload_name, "author": "unknown", "description": "", "version": "1.0",
            })
            with open(payload_sh_local, "rb") as f:
                content = f.read().replace(b"\r\n", b"\n")
            content_hash = hashlib.sha1(content).hexdigest()
            meta_hash = hashlib.sha1(json.dumps(meta, sort_keys=True).encode("utf-8")).hexdigest()
            cache_value = f"{content_hash}:{meta_hash}"
            state_key = f"{remote_dir}/payload.sh"
            if not force and state.get(state_key) == cache_value:
                unchanged += 1
            else:
                to_upload.append(f"{category}/{payload_name}")
    return sorted(to_upload), unchanged


def upload_tree(sftp, local_root, remote_root, log, state, force=False):
    # The Pager's shell scripts fail outright on Windows line endings (CR
    # breaks the shebang and every line after it) - this bit us once
    # already in this project. Since setup.py is explicitly meant to be
    # run from Windows, normalize CRLF -> LF for every uploaded file
    # rather than trusting the local files are already clean.
    #
    # Incremental: state[remote_path] caches the sha1 of what was last
    # actually uploaded there. A file whose current hash still matches is
    # skipped entirely (no SFTP round-trip) - --force bypasses this and
    # re-uploads everything, for the rare case the device's copy diverged
    # from what the cache thinks it pushed (e.g. after a factory reset).
    # BUG FOUND AND FIXED: this used to walk EVERYTHING under scripts/,
    # including __pycache__/*.pyc build artifacts left behind by running
    # `python -m py_compile` locally while developing (or just importing
    # server.py) - caught live when a stray .pyc actually got uploaded to
    # the device in a real deploy. Skip local dev-artifact directories/
    # files outright; they're never something the device needs.
    SKIP_DIRS = {"__pycache__", ".git"}
    SKIP_SUFFIXES = (".pyc", ".pyo")

    # BUG FOUND AND FIXED (root-caused live, via a real device): os.walk's
    # default top-down order visits the top-level scripts/*.sh files BEFORE
    # ever descending into scripts/lib/ - meaning every deploy has always
    # uploaded scripts that depend on lib/common.sh's shared functions
    # BEFORE common.sh itself got updated. This didn't matter while
    # common.sh barely changed, but now several scripts depend on shared
    # functions defined there (ip_link, pid_running, canonicalize_lan_
    # topology) - a deploy landing mid-upload, or a payload launched from
    # the physical device WHILE a push is still in flight, can hit a real
    # window where an already-updated script calls a shared function a
    # not-yet-updated common.sh doesn't have yet. Confirmed live: this is
    # exactly what an "ERROR: Interface 'eth0' does not exist" report
    # turned out to be (ip_link undefined mid-deploy - eth0 was fine the
    # whole time). Sort scripts/lib/ to the front of the walk so shared
    # dependencies always land before anything that depends on them, in
    # every deploy, not by luck of which files happened to change together.
    walk_entries = sorted(
        os.walk(local_root),
        key=lambda entry: 0 if os.path.basename(entry[0]) == "lib" else 1,
    )

    uploaded = skipped = 0
    seen_remote_paths = set()
    for dirpath, dirnames, filenames in walk_entries:
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel = os.path.relpath(dirpath, local_root)
        remote_dir = remote_root if rel == "." else remote_root + "/" + rel.replace(os.sep, "/")
        try:
            sftp.mkdir(remote_dir)
        except IOError:
            pass  # already exists
        for fname in filenames:
            if fname.endswith(SKIP_SUFFIXES):
                continue
            local_path = os.path.join(dirpath, fname)
            remote_path = remote_dir + "/" + fname
            seen_remote_paths.add(remote_path)
            with open(local_path, "rb") as f:
                content = f.read()
            normalized = content.replace(b"\r\n", b"\n")
            digest = hashlib.sha1(normalized).hexdigest()
            if not force and state.get(remote_path) == digest:
                skipped += 1
                continue
            sftp.putfo(io.BytesIO(normalized), remote_path)
            state[remote_path] = digest
            uploaded += 1
            log(f"  {remote_path}")
    if skipped:
        log(f"  ({skipped} file(s) unchanged since last push - skipped)")
    return uploaded, skipped, seen_remote_paths


# BIG CHANGE: upload_tree only ever adds/updates files - a script deleted
# locally (e.g. raw_deauth.py, removed as confirmed-dead code earlier this
# sweep) stayed on the device FOREVER, since nothing ever told setup.py to
# remove anything. state tracks every remote path this tool has ever
# pushed - anything still in there that ISN'T in the current local tree is
# exactly that: a file this tool put there that no longer has a local
# source. Scoped deliberately narrow and safe: only paths under
# REMOTE_ROOT that state itself remembers uploading - never a file this
# tool didn't put there, and never payload directories (deploy_payloads
# tracks those separately, under a different key prefix, untouched here).
def prune_stale_scripts(sftp, state, seen_remote_paths, log):
    prefix = REMOTE_ROOT + "/"
    stale = [p for p in list(state.keys()) if p.startswith(prefix) and p not in seen_remote_paths]
    if not stale:
        return
    log(f"Removing {len(stale)} stale file(s) no longer in the local scripts/ tree...")
    for p in stale:
        try:
            sftp.remove(p)
            log(f"  removed {p}")
            # BUG FOUND AND FIXED: this used to del state[p] unconditionally,
            # even when sftp.remove() raised - if removal genuinely failed
            # (a permissions issue, a busy handle, anything other than
            # "already gone"), the state cache would still forget this path
            # was ever tracked. On every future run, prune_stale_scripts()
            # only ever considers paths still present in `state` - so a
            # failed removal that also got forgotten here would NEVER be
            # retried again, silently leaving that stale file on the device
            # forever with no future run ever attempting to clean it up.
            # Only forget it once it's actually confirmed gone.
            del state[p]
        except IOError as e:
            log(f"  WARNING: couldn't remove {p} (may already be gone): {e}")


PAYLOAD_META = {
    "custom_lan_scan": {"title": "Custom LAN Scan", "author": "florian",
        "description": "nmap scan of the wired LAN (eth1) - pick a mode on-screen, logs to /root/loot/lanscan/", "version": "2.0"},
    "wifi_deauth": {"title": "WiFi Deauth", "author": "florian",
        "description": "Continuously deauth a network's clients until you press B. Same-name networks (mesh APs) are grouped - pick once to hit all of them. Dual-radio removed (caused repeated hard hangs needing a manual power cycle). Chase mode: a specific target roams a mesh, this follows it. Dynamic escalation: the default 'everyone' broadcast attack now periodically re-checks each AP for still-active clients and escalates burst pressure specifically where it's measurably not working yet - whole-range disruption, not one device.", "version": "9.0"},
    "deadnet_lan_kill": {"title": "DeadNet LAN Kill", "author": "florian",
        "description": "Discovers live LAN hosts, then ARP-poisons the whole wired LAN (eth1) to disconnect them. Real --background support with a liveness check (deadnet.sh previously had none despite claiming it did). Press B to stop.", "version": "4.0"},
    "bluetooth_jam": {"title": "Bluetooth Jam", "author": "florian",
        "description": "Scan (classic+BLE), L2CAP-flood one target, jam the whole area, flood BLE adverts, or occupy the 2.4GHz band (full sweep or BLE-advertising-channel focus). Press B to stop.", "version": "4.1"},
    "pc_link_recon": {"title": "PC Link Capture", "author": "florian",
        "description": "Detect the PC directly wired to the Pager (USB-C tether or USB-A adapter) and capture+summarize its traffic.", "version": "2.0"},
    "packet_tracer": {"title": "Live Packet Tracer", "author": "florian",
        "description": "Wireshark-style LIVE packet trace - WiFi connection, wired LAN, or passive nearby-WiFi monitoring. Errors clearly if there's nothing to trace. Press B to stop.", "version": "1.0"},
    "lan_sniffer": {"title": "LAN Sniffer", "author": "florian",
        "description": "Live LAN traffic view (auto-detected adapter, or bridge/tap both ports - internet is forwarded, not blocked, with a brief settling window after bridging; self-heals eth0/br-lan if the bridge drops it) - timer or infinite duration, A pauses/resumes, B asks to stop, then offers to save the log. HTTP/DNS/creds flagged live with source IP and destination host. Shows a live progress bar while the bridge comes up instead of one static line.", "version": "3.5"},
    "reset_device": {"title": "Reset Device State", "author": "florian",
        "description": "Undo everything this toolkit can leave in a non-standard state, or a fast pineapple-app restart, or a full slow reboot. Live progress, not a wait-then-dump.", "version": "1.2"},
}


def deploy_payloads(client, sftp, local_payloads_root, log, state, force=False):
    """Upload payloads/<category>/<name>/ to /root/payloads/user/<category>/<name>/,
    fix permissions to match real Hak5 payloads, and generate a matching
    _hak5_manifest.json for each (see module docstring for why).

    Incremental: a payload whose payload.sh content hash matches state's
    cached value is skipped entirely (no upload, no manifest rewrite, no
    chmod) - --force bypasses this. The pineapple app restart at the end
    only fires when something in `deployed` actually changed, so an
    all-unchanged run doesn't needlessly bounce the dashboard process."""
    if not os.path.isdir(local_payloads_root):
        log(f"  (no local payloads/ directory - skipping)")
        return

    def run(cmd, timeout=30):
        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        rc = stdout.channel.recv_exit_status()
        return rc, out, err

    deployed = []
    skipped = 0
    for category in sorted(os.listdir(local_payloads_root)):
        cat_path = os.path.join(local_payloads_root, category)
        if not os.path.isdir(cat_path):
            continue
        for payload_name in sorted(os.listdir(cat_path)):
            payload_local = os.path.join(cat_path, payload_name)
            if not os.path.isdir(payload_local):
                continue
            payload_sh_local = os.path.join(payload_local, "payload.sh")
            if not os.path.isfile(payload_sh_local):
                continue  # not a real payload dir (e.g. deadnet/ support code lives under scripts/lib now)

            remote_dir = f"/root/payloads/user/{category}/{payload_name}"

            meta = PAYLOAD_META.get(payload_name, {
                "title": payload_name, "author": "unknown", "description": "", "version": "1.0",
            })

            with open(payload_sh_local, "rb") as f:
                content = f.read().replace(b"\r\n", b"\n")
            content_hash = hashlib.sha1(content).hexdigest()
            # BUG FOUND AND FIXED: the incremental-skip cache used to be
            # keyed on content_hash alone - so editing ONLY a payload's
            # PAYLOAD_META entry above (fixing a description typo, bumping
            # the version) without touching payload.sh itself left the
            # cached value unchanged, and a plain incremental `setup.py`
            # run would skip this payload entirely: no manifest rewrite, no
            # chmod, and - worse - the drift-detection WARNING below (whose
            # own comment explicitly claims to catch a PAYLOAD_META-only
            # edit "or vice versa") never even ran, since it lives after
            # this skip check. Folding meta into the cache key so either
            # kind of edit invalidates it; last_hash in the manifest itself
            # (below) still records just the payload.sh content hash, since
            # that's its own established, on-device meaning.
            meta_hash = hashlib.sha1(json.dumps(meta, sort_keys=True).encode("utf-8")).hexdigest()
            cache_value = f"{content_hash}:{meta_hash}"
            state_key = f"{remote_dir}/payload.sh"
            if not force and state.get(state_key) == cache_value:
                skipped += 1
                continue

            try:
                sftp.mkdir(f"/root/payloads/user/{category}")
            except IOError:
                pass
            try:
                sftp.mkdir(remote_dir)
            except IOError:
                pass

            sftp.putfo(io.BytesIO(content), f"{remote_dir}/payload.sh")
            state[state_key] = cache_value

            # Catches exactly the kind of drift that's easy to introduce by
            # hand: bumping a payload's own "# Version:" header comment
            # without also updating its PAYLOAD_META entry above (or vice
            # versa) - the manifest always wins on-device, so a silent
            # mismatch here means the dashboard shows a version nobody
            # actually meant.
            header_version = None
            for line in content.decode("utf-8", errors="replace").splitlines()[:10]:
                if line.strip().lower().startswith("# version:"):
                    header_version = line.split(":", 1)[1].strip()
                    break
            if header_version and header_version != meta["version"]:
                log(f"  WARNING: {payload_name}/payload.sh header says Version: {header_version} "
                    f"but PAYLOAD_META in setup.py says {meta['version']} - one of them is stale.")
            manifest = {
                "payload": payload_name,
                "parent": f"user/{category}",
                "key": f"user~{category}~{payload_name.lower()}",
                "time": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
                "last_hash": content_hash,
                "zip": "",
                "title": meta["title"],
                "author": meta["author"],
                "description": meta["description"],
                "version": meta["version"],
            }
            sftp.putfo(io.BytesIO(json.dumps(manifest).encode("utf-8")), f"{remote_dir}/_hak5_manifest.json")

            # Match the permission profile of real, dashboard-visible payloads:
            # directory 700, payload.sh 644 (NOT executable), manifest 644.
            run(f"chmod 700 '{remote_dir}' && chmod 644 '{remote_dir}/payload.sh' '{remote_dir}/_hak5_manifest.json'")
            deployed.append(f"{category}/{payload_name}")
            log(f"  {remote_dir}")

    if skipped:
        log(f"  ({skipped} payload(s) unchanged since last push - skipped)")

    if not deployed:
        return

    # Force a real restart of the pineapple app process so it rescans the
    # payload list. /etc/init.d/pineapplepager restart does NOT work here -
    # its stop_service() stops pineapd (the wrong daemon) instead of the
    # actual /pineapple/pineapple process, so the stale process just keeps
    # running with its old in-memory payload cache. procd auto-respawns a
    # killed instance cleanly, so kill the real PID directly instead.
    rc, out, err = run('ps w | grep "/pineapple/pineapple" | grep -v grep')
    pid = out.split()[0] if out.split() else None
    if pid:
        run(f"kill {pid}")
        time.sleep(6)
        rc, out, err = run('ps w | grep "/pineapple/pineapple" | grep -v grep')
        if out.strip():
            log("  pineapple app process restarted cleanly - new payloads should now be visible on-screen.")
        else:
            log("  WARNING: pineapple app process did not respawn - you may need to power-cycle the device.")


# BUG FOUND AND FIXED (found live, via a real reboot): usb_monitor.sh only
# ever gets (re)started by setup.py explicitly checking/launching it - there
# was no autostart mechanism of any kind (confirmed live: no /etc/init.d
# entry for it, /etc/rc.local was still the untouched default stub, no
# crontab). A physical reboot leaves it not running until someone thinks to
# re-run setup.py or start it by hand - exactly what was observed: it was
# running right after a deploy, then simply wasn't anymore a few minutes
# later with nothing left running or logged, consistent with never having
# been restarted after whatever stopped it (or a boot in between).
# /etc/rc.local is the standard, OpenWRT-documented place for "run once
# system init finished" - this ensures ONE idempotent line there so a
# reboot brings the USB attach/detach watcher back on its own. Read-modify-
# write via SFTP (not a remote shell one-liner) specifically to avoid
# fragile quoting over an SSH exec_command round-trip for something that
# edits a system boot file.
USB_MONITOR_AUTOSTART_LINE = "[ -x /root/scripts/usb_monitor.sh ] && /root/scripts/usb_monitor.sh --background >/dev/null 2>&1"


def ensure_usb_monitor_autostart(client, log):
    try:
        sftp = client.open_sftp()
        try:
            with sftp.open("/etc/rc.local", "r") as f:
                content = f.read().decode("utf-8", errors="replace")
        except IOError:
            content = "exit 0\n"
        if USB_MONITOR_AUTOSTART_LINE in content:
            log("  usb_monitor.sh autostart already present in /etc/rc.local.")
            sftp.close()
            return
        lines = content.splitlines()
        # Insert right before the final "exit 0" - OpenWRT's rc.local always
        # ends with one, and anything placed AFTER it would never run.
        insert_at = len(lines)
        for i, line in enumerate(lines):
            if line.strip() == "exit 0":
                insert_at = i
                break
        lines.insert(insert_at, USB_MONITOR_AUTOSTART_LINE)
        new_content = "\n".join(lines) + "\n"
        with sftp.open("/etc/rc.local", "w") as f:
            f.write(new_content.encode("utf-8"))
        sftp.chmod("/etc/rc.local", 0o755)
        sftp.close()
        log("  Added usb_monitor.sh autostart to /etc/rc.local - it will survive a reboot now.")
    except Exception as e:
        log(f"  WARNING: could not ensure usb_monitor.sh autostart in /etc/rc.local: {e}")


def main():
    ap = argparse.ArgumentParser(description="Install the Pager Toolkit onto a WiFi Pineapple Pager.")
    ap.add_argument("--config", default=os.path.join(HERE, "config.txt"))
    ap.add_argument("--skip-python3", action="store_true", help="Don't install python3 (needed for the web Control Panel and deadnet.sh)")
    ap.add_argument("--skip-scapy", action="store_true", help="Don't install scapy (needed by deadnet.sh)")
    ap.add_argument("--skip-payloads", action="store_true", help="Don't (re)deploy the custom payloads")
    ap.add_argument("--skip-token", action="store_true", help="Don't touch the Control Panel access token")
    ap.add_argument("--force", action="store_true", help="Re-upload everything, ignoring the incremental deploy cache (.deploy_state.json)")
    ap.add_argument("--quiet", action="store_true", help="Only print section headers, not every uploaded file - for the auto-sync wrapper")
    ap.add_argument("--dry-run", action="store_true", help="Show what would be uploaded/pruned and exit - no device connection, nothing is changed")
    args = ap.parse_args()
    log = (lambda *a, **k: None) if args.quiet else print

    # IMPROVEMENT (new feature): handled before the config.txt check on
    # purpose - a dry run never connects to anything, so it doesn't need
    # ip=/password= either. Lets you preview a pending push (e.g. right
    # after editing a script) even with the device fully offline/unreachable
    # or no config.txt written yet.
    if args.dry_run:
        print("== Pager Toolkit Setup (DRY RUN - no connection made, nothing will change) ==")
        state = load_state()
        local_scripts = os.path.join(HERE, "scripts")
        if not os.path.isdir(local_scripts):
            print(f"ERROR: {local_scripts} not found - is this setup.py still next to its scripts/ folder?")
            sys.exit(1)

        to_upload, unchanged, stale = plan_scripts(local_scripts, REMOTE_ROOT, state, force=args.force)
        print(f"\nScripts ({REMOTE_ROOT}):")
        if to_upload:
            print(f"  Would upload {len(to_upload)} file(s):")
            for p in to_upload:
                print(f"    + {p}")
        else:
            print("  Nothing to upload.")
        if stale:
            print(f"  Would remove {len(stale)} stale file(s) no longer in the local tree:")
            for p in stale:
                print(f"    - {p}")
        print(f"  ({unchanged} file(s) unchanged since last push)")

        if not args.skip_payloads:
            local_payloads = os.path.join(HERE, "payloads")
            payload_upload, payload_unchanged = plan_payloads(local_payloads, state, force=args.force)
            print(f"\nPayloads (/root/payloads/user/):")
            if payload_upload:
                print(f"  Would upload/update {len(payload_upload)} payload(s):")
                for p in payload_upload:
                    print(f"    + {p}")
                print("  (a pineapple app restart would follow, so the dashboard picks up the new list)")
            else:
                print("  Nothing to upload.")
            print(f"  ({payload_unchanged} payload(s) unchanged since last push)")

        print("\nDry run only - no connection was made, nothing was uploaded or removed.")
        if not args.force:
            print("(add --force to preview a full re-push that ignores the incremental cache)")
        return

    if not os.path.isfile(args.config):
        print(f"ERROR: config file not found: {args.config}")
        print("Create it (see the docstring at the top of this file for the format).")
        sys.exit(1)

    cfg = read_config(args.config)
    ip = cfg["ip"]
    password = cfg["password"]

    print(f"== Pager Toolkit Setup ==")
    print(f"Connecting to {ip}...")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ip, username="root", password=password, timeout=10, look_for_keys=False, allow_agent=False)
    except Exception as e:
        print(f"ERROR: could not connect - {e}")
        sys.exit(1)

    def run(cmd, timeout=30):
        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        rc = stdout.channel.recv_exit_status()
        return rc, out, err

    state = load_state()

    print("Connected. Uploading scripts...")
    sftp = client.open_sftp()
    # BUG FOUND AND FIXED: paramiko's SFTPClient never sets a timeout on its
    # underlying channel by itself - confirmed by reading paramiko's own
    # source (site-packages/paramiko/sftp_client.py has zero references to
    # `timeout`/`settimeout` anywhere in the file). client.connect(...)'s
    # own timeout=10 above only bounds the initial TCP connect/handshake;
    # it does nothing for operations on channels opened afterward. That
    # means every sftp.mkdir()/putfo()/remove() call below could block
    # forever on a stalled connection (WiFi drop mid-upload, device losing
    # power) instead of raising promptly - exactly the "device disconnects
    # mid-deploy" case this module's docstring already designs around via
    # the incremental state cache, except without this the script would
    # just hang instead of ever reaching the point of failing (cleanly or
    # otherwise). paramiko's own SFTPClient.get_channel() docstring
    # literally suggests this exact fix ("useful for doing things like
    # setting a timeout on the channel") - applying it bounds every
    # individual blocking read/write, not the whole transfer, so a large
    # file that's still actively moving data is unaffected.
    sftp.get_channel().settimeout(30)
    local_scripts = os.path.join(HERE, "scripts")
    if not os.path.isdir(local_scripts):
        print(f"ERROR: {local_scripts} not found - is this setup.py still next to its scripts/ folder?")
        sys.exit(1)

    run(f"mkdir -p {REMOTE_ROOT}")
    _usb_monitor_remote = f"{REMOTE_ROOT}/usb_monitor.sh"
    _usb_monitor_digest_before = state.get(_usb_monitor_remote)
    uploaded, skipped, seen_remote_paths = upload_tree(sftp, local_scripts, REMOTE_ROOT, log, state, force=args.force)
    usb_monitor_changed = state.get(_usb_monitor_remote) != _usb_monitor_digest_before
    prune_stale_scripts(sftp, state, seen_remote_paths, log)
    save_state(state)  # save after every phase, not just at the end - a
    # later phase failing shouldn't lose credit for scripts that already
    # made it over
    sftp.close()
    if uploaded == 0 and skipped > 0:
        print(f"  All {skipped} script(s) already up to date - nothing to upload.")

    print("Setting execute permissions...")
    run(f"chmod +x {REMOTE_ROOT}/*.sh {REMOTE_ROOT}/lib/*.sh {REMOTE_ROOT}/gui {REMOTE_ROOT}/help {REMOTE_ROOT}/guiserver/server.py 2>/dev/null")

    print("Creating command aliases (skipping names that collide with real system tools)...")
    rc, out, err = run(f"ls {REMOTE_ROOT}/*.sh")
    sh_files = [os.path.basename(p) for p in out.split() if p.strip()]
    alias_cmds = []
    for f in sh_files:
        base = f[:-3]  # strip .sh
        if base in ("common",):
            continue
        alias_name = COLLISION_NAMES.get(base, base.lower())
        alias_cmds.append(f"ln -sf {REMOTE_ROOT}/{f} {REMOTE_ROOT}/{alias_name}")
    alias_cmds.append(f"ln -sf {REMOTE_ROOT}/webui.sh {REMOTE_ROOT}/webui")
    run(" && ".join(alias_cmds))
    print(f"  {len(alias_cmds)} aliases created.")

    print("Adding /root/scripts to PATH (~/.profile, idempotent)...")
    run(
        "grep -q 'root/scripts' /root/.profile 2>/dev/null || "
        "echo 'export PATH=\"$PATH:/root/scripts\"' >> /root/.profile"
    )

    # usb_monitor.sh: notifies on every USB-C/USB-A attach/detach.
    # Deliberately not a payload/picker - just a plain always-on watcher,
    # so it's started here automatically rather than needing anyone to
    # remember to launch it by hand. Idempotent: only starts it if it
    # isn't already running (e.g. a re-deploy shouldn't spawn a second one)
    # - EXCEPT when the script's own content just changed (usb_monitor_changed,
    # computed from upload_tree's hash cache above), in which case the
    # already-running copy is the OLD code and needs restarting to pick up
    # the change - otherwise a fix to this file would silently never take
    # effect until someone thought to restart it by hand.
    print("Starting usb_monitor.sh (USB-C/USB-A attach/detach watcher)...")
    rc, out, err = run(f". /root/.profile && {REMOTE_ROOT}/usb_monitor.sh --status", timeout=10)
    if "Running" in out and not usb_monitor_changed:
        print("  Already running.")
    else:
        if "Running" in out:
            run(f". /root/.profile && {REMOTE_ROOT}/usb_monitor.sh --stop", timeout=10)
            print("  Script changed - restarting to pick up the update...")
        run(f". /root/.profile && {REMOTE_ROOT}/usb_monitor.sh --background", timeout=10)
        print("  Started.")

    print("Ensuring usb_monitor.sh survives a reboot (/etc/rc.local)...")
    ensure_usb_monitor_autostart(client, log)

    if not args.skip_python3:
        rc, out, err = run("which python3", timeout=10)
        if rc == 0:
            print("python3 already installed.")
        else:
            print("Installing python3 (opkg install -d mmc python3, ~30-60s)...")
            rc, out, err = run("opkg update && opkg install -d mmc python3", timeout=180)
            if rc != 0:
                print("WARNING: python3 install may have failed:")
                print(err[-500:])
            else:
                print("python3 installed.")

    if not args.skip_scapy:
        rc, out, err = run("opkg list-installed 2>/dev/null | grep -q '^scapy '", timeout=10)
        if rc == 0:
            print("scapy already installed.")
        else:
            print("Installing scapy (opkg install -d mmc scapy, needed by deadnet.sh)...")
            rc, out, err = run("opkg install -d mmc scapy", timeout=180)
            if rc != 0:
                print("WARNING: scapy install may have failed:")
                print(err[-500:])
            else:
                print("scapy installed.")

    if not args.skip_payloads:
        print("Deploying custom payloads...")
        sftp = client.open_sftp()
        sftp.get_channel().settimeout(30)  # see the same fix on the scripts sftp session above
        local_payloads = os.path.join(HERE, "payloads")
        run("mkdir -p /root/payloads/user")
        deploy_payloads(client, sftp, local_payloads, log, state, force=args.force)
        save_state(state)
        sftp.close()

    if not args.skip_token:
        rc, out, err = run(f"PAYLOAD_GET_CONFIG webui token", timeout=10)
        existing = out.strip()
        if existing:
            print(f"Control Panel token already set (unchanged).")
        else:
            print("Setting a Control Panel access token...")
            rc, out, err = run(
                f"{REMOTE_ROOT}/webui.sh --set-token", timeout=10
            )
            print("  " + out.strip().replace("\n", "\n  "))

    print()
    print("== Done ==")
    print(f"SSH in and try: help")
    print(f"Or launch the Control Panel with: gui")
    client.close()


if __name__ == "__main__":
    # BUG FOUND AND FIXED: only the initial client.connect() call (inside
    # main()) was ever wrapped in a try/except - every subsequent operation
    # (run()'s exec_command() calls, upload_tree()'s/deploy_payloads()'s
    # direct sftp.mkdir()/putfo()/remove() calls, ensure_usb_monitor_
    # autostart()'s own sftp read/write of /etc/rc.local) assumes the SSH
    # session stays up for the whole deploy. Traced every call site between
    # the connect() and client.close() at the end of main(): none of them
    # are guarded, so a real mid-deploy disconnect (WiFi dropout, device
    # reboot, or now also the sftp channel timeout added above) raises
    # paramiko.SSHException/OSError/socket.timeout straight out of main()
    # with nothing to catch it - a raw Python traceback instead of the
    # clean "ERROR: ..." + exit(1) every other failure path in this file
    # already uses (see the connect() except clause just above, and
    # read_config()'s). This is purely a presentation gap, not a data-loss
    # one: state is saved via save_state() after every phase (scripts,
    # payloads), so a disconnect never loses already-pushed progress -
    # re-running setup.py picks up incrementally right where it left off.
    # Catching it here at the outermost level turns that into the same
    # actionable message instead of a scary traceback.
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted.")
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: lost connection or a command failed mid-deploy: {e}")
        print("Progress so far was saved (.deploy_state.json) - just re-run setup.py to resume.")
        sys.exit(1)

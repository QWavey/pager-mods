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

    uploaded = skipped = 0
    for dirpath, dirnames, filenames in os.walk(local_root):
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
    return uploaded, skipped


PAYLOAD_META = {
    "custom_lan_scan": {"title": "Custom LAN Scan", "author": "florian",
        "description": "nmap scan of the wired LAN (eth1) - pick a mode on-screen, logs to /root/loot/lanscan/", "version": "2.0"},
    "wifi_deauth": {"title": "WiFi Deauth", "author": "florian",
        "description": "Continuously deauth a network's clients until you press B. Same-name networks (mesh APs) are grouped - pick once to hit all of them. Dual-radio removed (caused repeated hard hangs needing a manual power cycle). Chase mode: a specific target roams a mesh, this follows it. Dynamic escalation: the default 'everyone' broadcast attack now periodically re-checks each AP for still-active clients and escalates burst pressure specifically where it's measurably not working yet - whole-range disruption, not one device.", "version": "9.0"},
    "deadnet_lan_kill": {"title": "DeadNet LAN Kill", "author": "florian",
        "description": "Discovers live LAN hosts, then ARP-poisons the whole wired LAN (eth1) to disconnect them. Press B to stop.", "version": "3.0"},
    "bluetooth_jam": {"title": "Bluetooth Jam", "author": "florian",
        "description": "Scan (classic+BLE), L2CAP-flood one target, jam the whole area, flood BLE adverts, or occupy the 2.4GHz band (full sweep or BLE-advertising-channel focus). Press B to stop.", "version": "4.1"},
    "pc_link_recon": {"title": "PC Link Capture", "author": "florian",
        "description": "Detect the PC directly wired to the Pager (USB-C tether or USB-A adapter) and capture+summarize its traffic.", "version": "2.0"},
    "packet_tracer": {"title": "Live Packet Tracer", "author": "florian",
        "description": "Wireshark-style LIVE packet trace - WiFi connection, wired LAN, or passive nearby-WiFi monitoring. Errors clearly if there's nothing to trace. Press B to stop.", "version": "1.0"},
    "lan_sniffer": {"title": "LAN Sniffer", "author": "florian",
        "description": "Live LAN traffic view (auto-detected adapter, or bridge/tap both ports - full internet stays intact, self-heals eth0/br-lan if the bridge drops it) - timer or infinite duration, A pauses/resumes, B asks to stop, then offers to save the log. HTTP/DNS/creds flagged live.", "version": "3.1"},
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


def main():
    ap = argparse.ArgumentParser(description="Install the Pager Toolkit onto a WiFi Pineapple Pager.")
    ap.add_argument("--config", default=os.path.join(HERE, "config.txt"))
    ap.add_argument("--skip-python3", action="store_true", help="Don't install python3 (needed for the web Control Panel and deadnet.sh)")
    ap.add_argument("--skip-scapy", action="store_true", help="Don't install scapy (needed by deadnet.sh)")
    ap.add_argument("--skip-payloads", action="store_true", help="Don't (re)deploy the custom payloads")
    ap.add_argument("--skip-token", action="store_true", help="Don't touch the Control Panel access token")
    ap.add_argument("--force", action="store_true", help="Re-upload everything, ignoring the incremental deploy cache (.deploy_state.json)")
    ap.add_argument("--quiet", action="store_true", help="Only print section headers, not every uploaded file - for the auto-sync wrapper")
    args = ap.parse_args()
    log = (lambda *a, **k: None) if args.quiet else print

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
    local_scripts = os.path.join(HERE, "scripts")
    if not os.path.isdir(local_scripts):
        print(f"ERROR: {local_scripts} not found - is this setup.py still next to its scripts/ folder?")
        sys.exit(1)

    run(f"mkdir -p {REMOTE_ROOT}")
    _usb_monitor_remote = f"{REMOTE_ROOT}/usb_monitor.sh"
    _usb_monitor_digest_before = state.get(_usb_monitor_remote)
    uploaded, skipped = upload_tree(sftp, local_scripts, REMOTE_ROOT, log, state, force=args.force)
    usb_monitor_changed = state.get(_usb_monitor_remote) != _usb_monitor_digest_before
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
    main()

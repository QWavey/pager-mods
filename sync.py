#!/usr/bin/env python3
"""
sync.py - Auto-connect + incremental push wrapper around setup.py.

The problem this solves: the Pager's SSH isn't always up (rebooting,
unplugged, mid-reconnect) and re-running the full installer by hand every
time you change one file is slow and noisy. This waits for SSH to come
back (retrying quietly instead of failing outright), then runs setup.py -
which is incremental by default (see its own docstring) - so only what
actually changed since the last successful push goes out, not a full
re-upload of everything.

Usage:
    python3 sync.py                  wait for SSH (up to 5 min), then push changed files
    python3 sync.py --timeout 60       give up waiting after 60s instead of the 300s default
    python3 sync.py --watch            after the first push, keep watching local files and
                                          push again automatically whenever any of them change
                                          (still incremental - only the changed ones go out).
                                          Ctrl+C to stop.
    python3 sync.py --force            first push ignores the incremental cache (see setup.py --force)
    python3 sync.py -- --skip-scapy    anything after -- is passed straight through to setup.py

Same config.txt as setup.py (ip=/password= next to this file).
"""
import argparse
import hashlib
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def read_config(path):
    cfg = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            cfg[key.strip()] = val.strip()
    return cfg


def ssh_is_up(ip, port=22, timeout=3):
    # A plain TCP connect to the SSH port - cheap, doesn't need paramiko
    # or credentials, just "is anything listening yet". Good enough to
    # gate on before handing off to setup.py, which does the real auth.
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_for_ssh(ip, overall_timeout):
    deadline = time.time() + overall_timeout
    attempt = 0
    print(f"Waiting for {ip}:22 to come up (up to {overall_timeout}s)...")
    while time.time() < deadline:
        attempt += 1
        if ssh_is_up(ip):
            print(f"  Up after {attempt} check(s).")
            return True
        time.sleep(5)
    print(f"  Still not reachable after {overall_timeout}s - giving up.")
    return False


def run_setup(extra_args):
    cmd = [sys.executable, os.path.join(HERE, "setup.py")] + extra_args
    print(f"Running: {' '.join(extra_args) or '(default)'}")
    result = subprocess.run(cmd, cwd=HERE)
    return result.returncode == 0


# --watch: fingerprint every file under scripts/ and payloads/ (same trees
# setup.py itself walks) by (path, mtime, size) - cheap, no hashing needed
# here since setup.py's own incremental cache already does the real
# content-hash comparison; this layer just needs to know "did anything
# change on disk since I last looked" to decide whether to bother calling
# setup.py at all.
def snapshot(root):
    snap = {}
    for tree in ("scripts", "payloads"):
        base = os.path.join(root, tree)
        if not os.path.isdir(base):
            continue
        for dirpath, _, filenames in os.walk(base):
            for fname in filenames:
                p = os.path.join(dirpath, fname)
                try:
                    st = os.stat(p)
                    snap[p] = (st.st_mtime_ns, st.st_size)
                except OSError:
                    pass
    return snap


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.path.join(HERE, "config.txt"))
    ap.add_argument("--timeout", type=int, default=300, help="Max seconds to wait for SSH before giving up (default 300)")
    ap.add_argument("--watch", action="store_true", help="After the first push, keep watching for local changes and auto-push them")
    ap.add_argument("--force", action="store_true", help="First push ignores the incremental cache")
    ap.add_argument("setup_args", nargs=argparse.REMAINDER, help="Anything after -- is passed to setup.py as-is")
    args = ap.parse_args()

    if not os.path.isfile(args.config):
        print(f"ERROR: config file not found: {args.config}")
        sys.exit(1)
    cfg = read_config(args.config)
    ip = cfg.get("ip")
    if not ip:
        print(f"ERROR: {args.config} needs an 'ip=' line.")
        sys.exit(1)

    extra = [a for a in args.setup_args if a != "--"]
    if args.force and "--force" not in extra:
        extra.append("--force")

    if not wait_for_ssh(ip, args.timeout):
        sys.exit(1)

    if not run_setup(extra):
        print("setup.py reported an error - see above.")
        sys.exit(1)

    if not args.watch:
        return

    print()
    print("Watching scripts/ and payloads/ for changes - Ctrl+C to stop.")
    last = snapshot(HERE)
    try:
        while True:
            time.sleep(3)
            now = snapshot(HERE)
            if now != last:
                changed = len(set(now) ^ set(last)) + sum(1 for k in now if k in last and now[k] != last[k])
                print(f"\nDetected changes ({changed} file(s) touched) - pushing...")
                if not ssh_is_up(ip):
                    print("  Device isn't reachable right now - will retry once it's back.")
                    if not wait_for_ssh(ip, args.timeout):
                        # BUG FIXED: this used to set last = now here, which
                        # marks the change as "already synced" even though
                        # run_setup() was never actually called for it - the
                        # pending edit would then be silently dropped
                        # forever (the next snapshot comparison sees no
                        # difference, since `last` already "saw" it). Leave
                        # `last` untouched so the same pending change keeps
                        # showing up as different on every future check
                        # until it genuinely gets pushed.
                        print("  Still unreachable - keeping the change queued, will retry on the next check.")
                        continue
                # BUG FOUND AND FIXED: run_setup()'s return value used to be
                # discarded here - if setup.py itself failed (a transient
                # SFTP/auth error, an interrupted push), `last` still got
                # set to `now` unconditionally, exactly the same "marks the
                # change as already synced even though it never actually
                # went out" bug already fixed just above for the
                # unreachable-device case, just untouched in this sibling
                # branch. Only adopt the new snapshot on a successful push -
                # otherwise leave `last` alone so the same pending change
                # keeps showing up as different and gets retried.
                if not run_setup(extra):
                    print("  setup.py reported an error - keeping the change queued, will retry on the next check.")
                    continue
                last = now
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()

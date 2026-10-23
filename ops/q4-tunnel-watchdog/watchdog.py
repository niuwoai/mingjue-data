#!/usr/bin/env python3
"""Verify q4's public SSH tunnel and recover only its designated client."""

import argparse
import fcntl
import json
import socket
import subprocess
import time
from pathlib import Path

VERSION = "0.1.0"
HOST = "h2.niuwoai.com"
PORT = 50022
SERVICE = "edge-cli-q4-ssh-h2.service"
FAILURE_THRESHOLD = 3
COOLDOWN_SECONDS = 300
HOST_KEY_PATH = Path("/etc/ssh/ssh_host_ed25519_key.pub")
STATE_DIRECTORY = Path("/var/lib/q4-tunnel-watchdog")


def emit(event, **fields):
    print(json.dumps({"version": VERSION, "event": event, **fields}), flush=True)


def local_ssh_ready():
    try:
        with socket.create_connection(("127.0.0.1", 22), timeout=3) as connection:
            connection.settimeout(3)
            return connection.recv(256).startswith(b"SSH-")
    except OSError:
        return False


def public_tunnel_ready():
    expected = HOST_KEY_PATH.read_text().split()
    if len(expected) < 2 or expected[0] != "ssh-ed25519":
        raise ValueError("q4 local Ed25519 public host key is invalid")
    result = subprocess.run(
        ["/usr/bin/ssh-keyscan", "-T", "5", "-t", "ed25519", "-p", str(PORT), HOST],
        capture_output=True, text=True, timeout=12, check=False,
    )
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[1:3] == expected[:2]:
            return True
    return False


def recovery_decision(state, healthy, now):
    failures = 0 if healthy else state.get("failures", 0) + 1
    last_restart = state.get("last_restart", 0)
    updated = {"failures": failures, "last_restart": last_restart}
    if healthy:
        return updated, "healthy"
    if failures < FAILURE_THRESHOLD:
        return updated, "waiting_for_threshold"
    if last_restart and now - last_restart < COOLDOWN_SECONDS:
        return updated, "cooldown"
    return updated, "restart_required"


def read_state(path):
    if not path.exists():
        return {"failures": 0, "last_restart": 0}
    try:
        state = json.loads(path.read_text())
        if not isinstance(state, dict):
            raise ValueError("state must be an object")
        for key in ("failures", "last_restart"):
            if type(state.get(key)) not in (int, float) or state[key] < 0:
                raise ValueError("invalid state counters")
        return state
    except (ValueError, TypeError) as error:
        emit("state_reset", reason=str(error))
        return {"failures": 0, "last_restart": 0}


def save_state(path, state):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def check_and_recover(directory, dry_run=False):
    if not local_ssh_ready():
        emit("local_ssh_unavailable", action="skip_tunnel_restart", dry_run=dry_run)
        return 1
    try:
        healthy = public_tunnel_ready()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        healthy = False
        emit("probe_error", reason=str(error))
    path = directory / "state.json"
    updated, action = recovery_decision(read_state(path), healthy, time.time())
    emit(action, failures=updated["failures"], host=HOST, port=PORT, dry_run=dry_run)
    if dry_run:
        return 0 if healthy else 1
    if action == "restart_required":
        # Persist the attempt first: a failed restart must also respect cooldown.
        updated.update(last_restart=time.time(), failures=0)
        save_state(path, updated)
        result = subprocess.run(
            ["/usr/bin/systemctl", "restart", SERVICE],
            capture_output=True, text=True, timeout=35, check=False,
        )
        emit("restart_completed", service=SERVICE, returncode=result.returncode)
        return result.returncode
    save_state(path, updated)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--state-dir", type=Path, default=STATE_DIRECTORY)
    args = parser.parse_args()
    args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (args.state_dir / "watchdog.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            emit("already_running")
            return 0
        return check_and_recover(args.state_dir, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())

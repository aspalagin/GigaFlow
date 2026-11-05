#!/bin/bash
# Install a local signed build; --check validates without replacing or launching.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 - "$repo_dir" "$@" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

if sys.platform != "darwin":
    raise SystemExit("Run this installer on macOS.")
if sys.argv[2:] not in ([], ["--check"]):
    raise SystemExit("Usage: bash scripts/install-app.sh [--check]")
check_only = sys.argv[2:] == ["--check"]
repo = Path(sys.argv[1])
home = Path.home()
source = repo / "app/build/GigaFlow.app"
destination = home / "Applications/GigaFlow.app"
runtime = home / "Developer/gigaam-pilot"
status_file = home / "Library/Application Support/GigaFlow/status.json"
app_id = "local.arseniy.gigaflow"

def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def designated_requirement(app):
    result = run(["/usr/bin/codesign", "-d", "-r-", str(app)])
    match = re.search(r"^designated => (.+)$", result.stdout + "\n" + result.stderr, re.M)
    if not match:
        raise SystemExit("Signed application has no designated requirement.")
    return match.group(1)

if not source.is_dir():
    raise SystemExit("Build the app first: bash app/build.sh")
with (source / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info.get("CFBundleIdentifier") != app_id:
    raise SystemExit("Unexpected application identifier.")
run(["/usr/bin/codesign", "--verify", "--strict", str(source)])
new_requirement = designated_requirement(source)
if destination.is_symlink():
    raise SystemExit("The installed application path must not be a symlink.")
if destination.exists() and designated_requirement(destination) != new_requirement:
    raise SystemExit("The installed app uses a different signing identity. Preserve its identity before updating.")
if not (runtime / ".venv/bin/python").is_file() or not (runtime / "models/gigaam-v3-e2e-rnnt-mlx/weights.safetensors").is_file():
    raise SystemExit("Set up the runtime first: bash scripts/setup-runtime.sh")
if check_only:
    print("Installation checks passed; no files replaced and no application launched.")
    raise SystemExit(0)
if subprocess.run(["/usr/bin/pgrep", "-x", "GigaFlow"], capture_output=True).returncode == 0:
    raise SystemExit("Quit GigaFlow from its menu, then run this installer again.")

destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".gigaflow-install-", dir=destination.parent) as staging:
    staged = Path(staging) / "GigaFlow.app"
    shutil.copytree(source, staged, symlinks=True)
    run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + new_requirement, str(staged)])
    backup = None
    if destination.exists():
        backup_dir = home / "Library/Application Support/GigaFlow/Backups"
        backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup = backup_dir / ("GigaFlow-" + time.strftime("%Y%m%d-%H%M%S") + ".app")
        if backup.exists():
            raise SystemExit("A backup with this timestamp already exists; retry in a moment.")
        os.rename(destination, backup)
    try:
        os.rename(staged, destination)
    except Exception:
        if backup is not None:
            os.rename(backup, destination)
        raise

existing_scale = subprocess.run(["/usr/bin/defaults", "read", app_id, "HUDScale"], capture_output=True)
if existing_scale.returncode != 0:
    run(["/usr/bin/defaults", "write", app_id, "HUDScale", "-float", str(2 / 3)])
run(["/usr/bin/open", str(destination)])
print("Installed and opened GigaFlow. Grant Microphone and Accessibility on first launch.")
PY

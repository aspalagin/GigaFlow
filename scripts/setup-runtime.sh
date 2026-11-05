#!/bin/bash
# Install a new runtime. Existing environments are deliberately left untouched.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_dir="$HOME/Developer/gigaam-pilot"
python_command="${GIGAFLOW_PYTHON:-python3.11}"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf 'GigaFlow requires an Apple Silicon Mac and a native arm64 shell.\n' >&2
  exit 1
fi

if [[ -e "$runtime_dir/.venv" || -L "$runtime_dir/.venv" ]]; then
  printf 'An existing runtime was found at %s/.venv; nothing was changed.\n' "$runtime_dir" >&2
  printf 'If it already works with GigaFlow, skip runtime setup and continue with app signing/building.\n' >&2
  printf 'For model download/verification only, run its Python with scripts/download-model.py.\n' >&2
  exit 1
fi

if ! command -v "$python_command" >/dev/null 2>&1; then
  printf 'Install native Python 3.11, then run this script again.\n' >&2
  printf 'To select an existing interpreter: GIGAFLOW_PYTHON=/path/to/python3.11 bash scripts/setup-runtime.sh\n' >&2
  exit 1
fi

"$python_command" - <<'PY'
import platform
import sys
if sys.version_info[:2] != (3, 11) or platform.machine() != "arm64":
    raise SystemExit("The pinned runtime requires native arm64 Python 3.11.")
PY

mkdir -p "$runtime_dir"
"$python_command" -m venv "$runtime_dir/.venv"
"$runtime_dir/.venv/bin/python" -m pip install --disable-pip-version-check -r "$repo_dir/requirements.lock.txt"
cp "$repo_dir/requirements.lock.txt" "$runtime_dir/requirements.lock.txt"
"$runtime_dir/.venv/bin/python" "$repo_dir/scripts/download-model.py"
printf '\nRuntime ready at %s. Continue with local app signing and building in README.md.\n' "$runtime_dir"

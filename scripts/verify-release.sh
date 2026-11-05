#!/bin/bash
# Verify the exact read-only image, optionally including public-reference ASR.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: bash scripts/verify-release.sh image.dmg [official-reference.wav]\n' >&2
  exit 1
fi
image="$1"
reference="${2:-}"
verification_dir=$(mktemp -d /tmp/gigaflow-release-check.XXXXXX)
mount_point=""
cleanup() {
  if [[ -n "$mount_point" ]]; then hdiutil detach "$mount_point" >/dev/null; fi
  rm -rf "$verification_dir"
}
trap cleanup EXIT
hdiutil verify "$image"
hdiutil attach -readonly -nobrowse -plist "$image" > "$verification_dir/mount.plist"
mount_point=$(/usr/bin/python3 - "$verification_dir/mount.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    entities = plistlib.load(stream)['system-entities']
print(next(entity['mount-point'] for entity in entities if 'mount-point' in entity))
PY
)
app="$mount_point/GigaFlow.app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/GigaFlow" --runtime-info > "$verification_dir/runtime.json"
/usr/bin/python3 - "$verification_dir/runtime.json" "$app" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text())
assert data['mode'] == 'bundled' and data['filesPresent']
Path(data['python']).relative_to(Path(sys.argv[2]))
Path(data['model']).relative_to(Path(sys.argv[2]))
print('Read-only DMG uses its bundled interpreter and model.')
PY
if [[ -n "$reference" ]]; then
  cp "$reference" "$verification_dir/official-example.wav"
  "$app/Contents/MacOS/GigaFlow" --self-test --self-test-audio "$verification_dir/official-example.wav"
  codesign --verify --deep --strict "$app"
fi
printf 'Release image verification passed.\n'

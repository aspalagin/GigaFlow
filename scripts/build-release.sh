#!/bin/bash
# Build an offline, self-contained arm64 DMG using the publisher's local identity.
# The DMG container is unsigned; the app and every nested Mach-O are signed.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf 'Build releases on a native Apple Silicon Mac.\n' >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)
release_dir="$repo_dir/dist/release-$version"
image="$repo_dir/dist/GigaFlow-$version-arm64.dmg"
if [[ -e "$release_dir" || -e "$image" ]]; then
  printf 'Release output already exists; move it aside before rebuilding.\n' >&2
  exit 1
fi
mkdir -p "$release_dir/image" "$release_dir/AppIcon.iconset"
chmod 755 "$release_dir/image"
xcrun swift scripts/make-icon.swift "$release_dir/AppIcon.iconset"
iconutil -c icns "$release_dir/AppIcon.iconset" -o assets/AppIcon.icns
bash app/build.sh
app="$release_dir/image/GigaFlow.app"
ditto app/build/GigaFlow.app "$app"
if [[ -n "${GIGAFLOW_BUNDLED_RUNTIME:-}" ]]; then
  # Reuse only an already assembled, verified runtime, never a virtualenv.
  test -f "$GIGAFLOW_BUNDLED_RUNTIME/runtime-manifest.json"
  ditto "$GIGAFLOW_BUNDLED_RUNTIME" "$app/Contents/Resources/Runtime"
else
  /usr/bin/python3 scripts/bundle-runtime.py --destination "$app/Contents/Resources/Runtime"
fi
/usr/bin/python3 - "$app" <<'PY'
import json
from pathlib import Path
import plistlib
import sys
app = Path(sys.argv[1])
runtime = app / 'Contents/Resources/Runtime'
manifest = json.loads((runtime / 'runtime-manifest.json').read_text())
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
info['LSMinimumSystemVersion'] = manifest['minimum_macos']
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream, sort_keys=False)
print('Bundled runtime requires macOS ' + manifest['minimum_macos'] + '+')
PY
mkdir -p "$app/Contents/Resources/Integrations"
cp integrations/hammerspoon/gigaflow.lua "$app/Contents/Resources/Integrations/gigaflow.lua"
cp app/enable-autostart.applescript "$app/Contents/Resources/enable-autostart.applescript"
cp THIRDPARTY.md "$app/Contents/Resources/THIRDPARTY.md"
/usr/bin/python3 - "$app" <<'PY'
from pathlib import Path
import os
import sys
app = Path(sys.argv[1])
# Readable by every installing user; preserve executable files without retaining
# private build-machine modes on notices, scripts or directories.
for path in [app, *app.rglob('*')]:
    if path.is_symlink():
        path.resolve(strict=True).relative_to(app)
    elif path.is_dir():
        path.chmod(0o755)
    else:
        executable = bool(path.stat().st_mode & 0o111)
        path.chmod(0o755 if executable else 0o644)
PY
/usr/bin/python3 app/sign-app.py "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/GigaFlow" --runtime-info
ln -s /Applications "$release_dir/image/Applications"
cp docs/INSTALL.txt "$release_dir/image/Установка.txt"
chmod 644 "$release_dir/image/Установка.txt"
hdiutil create -volname GigaFlow -srcfolder "$release_dir/image" -format UDZO \
  -imagekey zlib-level=9 "$image"
hdiutil verify "$image"
/usr/bin/python3 - "$image" <<'PY'
import hashlib
from pathlib import Path
import sys
image = Path(sys.argv[1])
if image.stat().st_size >= 2 * 1024**3:
    raise SystemExit('The DMG exceeds the GitHub Release asset limit.')
digest = hashlib.sha256()
with image.open('rb') as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(block)
(image.parent / 'SHA256SUMS.txt').write_text(digest.hexdigest() + '  ' + image.name + '\n')
print('Release image: ' + str(image))
print('Bytes: ' + str(image.stat().st_size))
PY

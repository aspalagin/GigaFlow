#!/bin/bash
# Generate a signed Sparkle feed for a finalized DMG. Never publishes it.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage on macOS: bash scripts/make-appcast.sh image.dmg [previous-appcast.xml]\n' >&2
  exit 1
fi
image=$(/usr/bin/python3 -I -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$1")
previous="${2:-}"
if [[ -z "$previous" && -f "$repo_dir/dist/appcast.xml" ]]; then
  previous="$repo_dir/dist/appcast.xml"
fi
signing_dir="${GIGAFLOW_UPDATE_SIGNING_DIR:-$HOME/Library/Application Support/GigaFlow/UpdateSigning}"
/usr/bin/python3 -I - "$repo_dir" "$signing_dir" <<'PY'
from pathlib import Path
import sys
repo, signing = (Path(path).resolve() for path in sys.argv[1:])
assert signing.is_absolute() and signing != repo and repo not in signing.parents, 'Private signing identity must remain outside the repository'
PY
key_file="$signing_dir/private-key.base64"
public_key=$(xcrun swift "$repo_dir/scripts/setup-update-signing.swift" --check --directory "$signing_dir")
bash "$repo_dir/scripts/fetch-sparkle.sh"
sparkle_bin="$repo_dir/vendor/Sparkle-2.10.1/bin"
mkdir -p "$repo_dir/dist"
work_dir=$(mktemp -d "$repo_dir/dist/.appcast-work.XXXXXX")
mount_point=""
cleanup() {
  if [[ -n "$mount_point" ]]; then hdiutil detach "$mount_point" >/dev/null || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Inspect the actual archive, rather than assuming a separate build directory
# still contains exactly the app that was packaged.
hdiutil verify "$image" >/dev/null
hdiutil attach -readonly -nobrowse -plist "$image" > "$work_dir/mount.plist"
mount_point=$(/usr/bin/python3 -I - "$work_dir/mount.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    entities = plistlib.load(stream)['system-entities']
print(next(entity['mount-point'] for entity in entities if 'mount-point' in entity))
PY
)
codesign --verify --deep --strict "$mount_point/GigaFlow.app"
/usr/bin/python3 -I - "$mount_point/GigaFlow.app/Contents/Info.plist" "$public_key" "$image" "$work_dir/metadata.json" <<'PY'
import json
from pathlib import Path
import plistlib
import re
import sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
version = info.get('CFBundleShortVersionString', '')
build = info.get('CFBundleVersion', '')
assert info.get('CFBundleIdentifier') == 'local.arseniy.gigaflow', 'Wrong application identifier'
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', version), 'Release version must have three numeric components'
assert re.fullmatch(r'[0-9]+', build), 'Build number must be numeric'
assert info.get('SUPublicEDKey') == sys.argv[2], 'App public key does not match the retained signing identity'
assert info.get('SUFeedURL') == 'https://github.com/aspalagin/GigaFlow/releases/latest/download/appcast.xml', 'Unexpected feed URL'
assert info.get('SUVerifyUpdateBeforeExtraction') is True, 'Archive verification must be enabled'
assert info.get('SURequireSignedFeed') is True, 'Signed feeds must be required'
image = Path(sys.argv[3])
assert image.name == 'GigaFlow-' + version + '-arm64.dmg', 'Archive filename does not match app version'
minimum = info.get('LSMinimumSystemVersion')
assert isinstance(minimum, str) and minimum, 'Missing minimum macOS version'
Path(sys.argv[4]).write_text(json.dumps({'version': version, 'build': build, 'minimum': minimum,
    'size': image.stat().st_size, 'url': 'https://github.com/aspalagin/GigaFlow/releases/download/v' + version + '/' + image.name}))
PY
hdiutil detach "$mount_point" >/dev/null
mount_point=""
version=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$work_dir/metadata.json")
mkdir -p "$work_dir/archives"
/usr/bin/python3 -I - "$image" "$work_dir/archives" <<'PY'
import os
from pathlib import Path
import shutil
import sys
source = Path(sys.argv[1])
target = Path(sys.argv[2]) / source.name
try:
    os.link(source, target)
except OSError:
    shutil.copyfile(source, target)
PY
if [[ -n "$previous" ]]; then
  "$sparkle_bin/sign_update" --ed-key-file "$key_file" --verify "$previous"
  cp "$previous" "$work_dir/appcast.xml"
  cp "$previous" "$work_dir/previous.xml"
fi
"$sparkle_bin/generate_appcast" --ed-key-file "$key_file" \
  --maximum-versions 0 --maximum-deltas 0 \
  --download-url-prefix "https://github.com/aspalagin/GigaFlow/releases/download/v$version/" \
  --link 'https://github.com/aspalagin/GigaFlow' \
  --full-release-notes-url "https://github.com/aspalagin/GigaFlow/releases/tag/v$version" \
  -o "$work_dir/appcast.xml" "$work_dir/archives"
"$sparkle_bin/sign_update" --ed-key-file "$key_file" --verify "$work_dir/appcast.xml"
/usr/bin/python3 -I - "$work_dir" "$sparkle_bin/sign_update" "$key_file" "$image" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
work = Path(sys.argv[1])
meta = json.loads((work / 'metadata.json').read_text())
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
def items(path):
    result = {}
    for item in ET.parse(path).findall('./channel/item'):
        enclosure = item.find('enclosure')
        assert enclosure is not None, 'Feed item missing enclosure'
        build = item.findtext(ns + 'version') or enclosure.get(ns + 'version')
        assert build and build.isdigit() and build not in result, 'Invalid or duplicate build in feed'
        result[build] = (item, enclosure)
    return result
current = items(work / 'appcast.xml')
assert meta['build'] in current, 'Current build missing from generated feed'
assert all(int(build) <= int(meta['build']) for build in current), 'Refusing to publish a downgrade'
item, enclosure = current[meta['build']]
assert item.findtext(ns + 'shortVersionString') == meta['version'], 'Version differs from packaged app'
assert item.findtext(ns + 'minimumSystemVersion') == meta['minimum'], 'Minimum macOS differs from packaged app'
assert enclosure.get('url') == meta['url'], 'Unexpected download URL'
assert int(enclosure.get('length', '-1')) == meta['size'], 'Archive size does not match feed'
signature = enclosure.get(ns + 'edSignature')
assert signature, 'Archive has no EdDSA signature'
subprocess.run([sys.argv[2], '--ed-key-file', sys.argv[3], '--verify', sys.argv[4], signature], check=True)
previous = work / 'previous.xml'
if previous.exists():
    for build, (_, old_enclosure) in items(previous).items():
        assert build in current, 'Previous release was removed from feed'
        assert current[build][1].attrib == old_enclosure.attrib, 'An existing release enclosure changed'
print('Verified archive, signed feed, release metadata and retained previous releases.')
PY
mv "$work_dir/appcast.xml" "$repo_dir/dist/appcast.xml"
chmod 644 "$repo_dir/dist/appcast.xml"
printf 'Prepared %s/dist/appcast.xml; upload with the DMG before publishing the release.\n' "$repo_dir"

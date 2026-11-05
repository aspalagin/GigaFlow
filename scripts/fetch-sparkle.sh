#!/bin/bash
# Fetch the pinned upstream framework/tools; never ship the build tools in .app.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
vendor="$repo_dir/vendor"
archive="$vendor/Sparkle-$version.tar.xz"
destination="$vendor/Sparkle-$version"
mkdir -p "$vendor"
staging=""
download=""
cleanup() {
  if [[ -n "$staging" ]]; then rm -rf "$staging"; fi
  if [[ -n "$download" ]]; then rm -f "$download"; fi
}
trap cleanup EXIT

if [[ ! -f "$archive" ]]; then
  download=$(mktemp "$vendor/.sparkle-download.XXXXXX")
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 300 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
    --output "$download"
  actual=$(shasum -a 256 "$download" | awk '{print $1}')
  if [[ "$actual" != "$checksum" ]]; then
    printf 'Sparkle download checksum mismatch.\n' >&2
    exit 1
  fi
  mv "$download" "$archive"
  download=""
fi

actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual" != "$checksum" ]]; then
  printf 'Cached Sparkle archive checksum mismatch; refusing to use it.\n' >&2
  exit 1
fi
if [[ ! -d "$destination" ]]; then
  staging=$(mktemp -d "$vendor/.sparkle-extract.XXXXXX")
  # The fixed hash authenticates the archive before extraction. Preserve the
  # framework's relative symlinks and executable bits, but not publisher UIDs.
  tar --no-same-owner -xf "$archive" -C "$staging" ./Sparkle.framework ./bin ./LICENSE
  printf '%s\n' "$checksum" > "$staging/.archive-sha256"
  mv "$staging" "$destination"
  staging=""
fi

if [[ ! -f "$destination/.archive-sha256" ]] || \
   [[ "$(cat "$destination/.archive-sha256")" != "$checksum" ]] || \
   [[ ! -x "$destination/Sparkle.framework/Sparkle" ]] || \
   [[ ! -x "$destination/bin/sign_update" ]] || [[ ! -f "$destination/LICENSE" ]]; then
  printf 'Sparkle cache is incomplete or has an unexpected version; move it aside and retry.\n' >&2
  exit 1
fi
if [[ "$(uname -s)" == Darwin ]]; then
  codesign --verify --deep --strict "$destination/Sparkle.framework"
fi
printf '%s\n' "$destination"

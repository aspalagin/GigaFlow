#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/build/GigaFlow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon \
  DictationHUD.swift FocusTracking.swift InputCounterGuard.swift GigaFlow.swift -o "$app/Contents/MacOS/GigaFlow"
cp Info.plist "$app/Contents/Info.plist"
cp worker.py "$app/Contents/Resources/worker.py"
if [ -f ../assets/AppIcon.icns ]; then
  cp ../assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/python3 ./sign-app.py "$app"
printf 'Built %s\n' "$app"

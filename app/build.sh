#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sparkle_dir=$(bash ../scripts/fetch-sparkle.sh)
app="$PWD/build/GigaFlow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses" "$app/Contents/Frameworks"
# Copy the complete framework, including its signed helper bundles and symlinks.
if [[ -e "$app/Contents/Frameworks/Sparkle.framework" ]]; then
  rm -rf "$app/Contents/Frameworks/Sparkle.framework"
fi
ditto "$sparkle_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_dir/LICENSE" "$app/Contents/Resources/Licenses/Sparkle.txt"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon \
  -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  DictationHUD.swift FocusTracking.swift InputCounterGuard.swift ClipboardSnapshot.swift \
  RecordingLifecycle.swift WorkerPipe.swift SingleInstance.swift UpdatePolicy.swift Updates.swift GigaFlow.swift \
  -o "$app/Contents/MacOS/GigaFlow"
cp Info.plist "$app/Contents/Info.plist"
cp worker.py "$app/Contents/Resources/worker.py"
if [ -f ../assets/AppIcon.icns ]; then
  cp ../assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/python3 ./sign-app.py "$app"
printf 'Built %s\n' "$app"

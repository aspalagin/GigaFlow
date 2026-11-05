#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
test_python="${GIGAFLOW_TEST_PYTHON:-python3}"
"$test_python" -m unittest discover -s app/tests -v
"$test_python" -m py_compile app/worker.py app/setup-signing.py app/sign-app.py scripts/download-model.py scripts/bundle-runtime.py scripts/check-update-tools.py
for script in app/build.sh app/enable-signing-trust.command scripts/*.sh; do
  bash -n "$script"
done
if [ "$(uname -s)" != Darwin ]; then
  printf 'Python and shell checks passed. Swift checks require macOS.\n'
  exit 0
fi
mkdir -p app/build
sparkle_dir=$(bash scripts/fetch-sparkle.sh)
xcrun swiftc -swift-version 5 -framework AppKit -framework ApplicationServices \
  app/FocusTracking.swift app/InputCounterGuard.swift app/tests/FocusPolicyChecks.swift \
  -o app/build/focus-policy-checks
app/build/focus-policy-checks
xcrun swiftc -swift-version 5 -framework AppKit \
  app/ClipboardSnapshot.swift app/tests/ClipboardChecks.swift -o app/build/clipboard-checks
app/build/clipboard-checks
xcrun swiftc -swift-version 5 \
  app/RecordingLifecycle.swift app/tests/RecordingLifecycleChecks.swift -o app/build/recording-lifecycle-checks
app/build/recording-lifecycle-checks
xcrun swiftc -swift-version 5 \
  app/WorkerPipe.swift app/tests/WorkerPipeChecks.swift -o app/build/worker-pipe-checks
app/build/worker-pipe-checks
xcrun swiftc -swift-version 5 \
  app/SingleInstance.swift app/tests/SingleInstanceChecks.swift -o app/build/single-instance-checks
app/build/single-instance-checks
xcrun swiftc -swift-version 5 \
  app/RecordingLifecycle.swift app/UpdatePolicy.swift app/tests/UpdatePolicyChecks.swift \
  -o app/build/update-policy-checks
app/build/update-policy-checks
xcrun swiftc -swift-version 5 scripts/setup-update-signing.swift -o app/build/setup-update-signing-check
controller_test="$repo_dir/app/build/UpdateControllerChecks.app"
mkdir -p "$controller_test/Contents/MacOS" "$controller_test/Contents/Frameworks"
ditto "$sparkle_dir/Sparkle.framework" "$controller_test/Contents/Frameworks/Sparkle.framework"
"$test_python" - "$controller_test/Contents/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'org.gigaflow.tests.update-controller',
        'CFBundleExecutable': 'UpdateControllerChecks', 'CFBundleName': 'UpdateControllerChecks',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.0.1',
        'LSUIElement': True}, stream)
PY
xcrun swiftc -swift-version 5 -framework AppKit -F "$sparkle_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  app/RecordingLifecycle.swift app/UpdatePolicy.swift app/Updates.swift app/tests/UpdateControllerChecks.swift \
  -o "$controller_test/Contents/MacOS/UpdateControllerChecks"
"$controller_test/Contents/MacOS/UpdateControllerChecks"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon \
  -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle_dir" \
  app/DictationHUD.swift app/FocusTracking.swift app/InputCounterGuard.swift app/ClipboardSnapshot.swift \
  app/RecordingLifecycle.swift app/WorkerPipe.swift app/SingleInstance.swift app/UpdatePolicy.swift app/Updates.swift app/GigaFlow.swift \
  -o app/build/GigaFlow-compile-check
plutil -lint app/Info.plist
"$test_python" scripts/check-update-tools.py
printf 'Checks passed. No microphone, model, publisher keys or live app used.\n'

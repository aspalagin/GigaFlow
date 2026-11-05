#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
test_python="${GIGAFLOW_TEST_PYTHON:-python3}"
"$test_python" -m unittest discover -s app/tests -v
"$test_python" -m py_compile app/worker.py app/setup-signing.py app/sign-app.py scripts/download-model.py scripts/bundle-runtime.py
for script in app/build.sh app/enable-signing-trust.command scripts/*.sh; do
  bash -n "$script"
done
if [ "$(uname -s)" != Darwin ]; then
  printf 'Python and shell checks passed. Swift checks require macOS.\n'
  exit 0
fi
mkdir -p app/build
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
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon \
  app/DictationHUD.swift app/FocusTracking.swift app/InputCounterGuard.swift app/ClipboardSnapshot.swift \
  app/RecordingLifecycle.swift app/WorkerPipe.swift app/SingleInstance.swift app/GigaFlow.swift \
  -o app/build/GigaFlow-compile-check
plutil -lint app/Info.plist
printf 'Checks passed. No microphone, model, signing identity or live app used.\n'

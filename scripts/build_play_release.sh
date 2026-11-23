#!/usr/bin/env bash
# z0 Agent Play release: analyze, test, store screenshots, signed AAB.
# Needs key.properties at the repo root (upload key; vault: Z0AGENT_UPLOAD_KEYSTORE_*).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/mnt/zer0models/tools/flutter-3.47.9/bin:$PATH
export FLUTTER_ROOT=/mnt/zer0models/tools/flutter-3.47.9
export PUB_CACHE=/mnt/zer0models/cache/pub GRADLE_USER_HOME=/mnt/zer0models/cache/gradle
export ANDROID_HOME=$HOME/Android/Sdk FLUTTER_SUPPRESS_ANALYTICS=true
export TMPDIR=/mnt/zer0models/cache/tmp ARES_PLAY_BUILD=true
mkdir -p "$TMPDIR"
test -f key.properties || { echo "missing key.properties" >&2; exit 2; }
flutter gen-l10n
flutter analyze lib/nextgen test/ng_theme_spec_test.dart test/store_screenshots_test.dart
flutter test test/ng_theme_spec_test.dart test/nextgen_test.dart
flutter test test/store_screenshots_test.dart --update-goldens
nice -n 10 flutter build appbundle --release --dart-define=ARES_PLAY_BUILD=true \
  --split-debug-info=symbols-play
aab=build/app/outputs/bundle/release/app-release.aab
ls -l "$aab"
keytool -printcert -jarfile "$aab" | grep -E 'Owner|SHA256:' | head -3
unzip -p "$aab" base/manifest/AndroidManifest.xml >/dev/null && echo "manifest ok"

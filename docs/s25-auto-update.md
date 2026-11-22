# S25 auto-update from staging

Every green `Play AAB (z0 Agent)` run on `staging` reaches Kevin's S25 without a human.

1. `play.yml` builds an arm64 APK signed with the upload key. Its versionCode is
   `(pubspec build + run number) * 10 + 2`, so each run installs over the last. The
   APK and `apk.json` (sha, run id, versionCode, signer) are uploaded as the
   `z0-agent-apk` artifact. Nothing is uploaded to Play.
2. On groot, `s25-z0-update.timer` (systemd user, every 5 min) runs
   `~/.local/bin/s25-z0-update`. It takes the newest successful staging run,
   downloads the artifact, checks the signer, sha and versionCode, and runs
   `adb install -r`. It never uninstalls the app or clears its data.
3. If the phone is not on adb, the updater scans its tailscale IP for the current
   wireless-debugging port and reconnects.
4. Receipts go to `~/.local/state/s25-update/receipts.jsonl` on groot, to the
   Studio film log, and as a comment on the merged pull request.

## Testing on a phone that has a newer local build

Testing on a phone that has a newer local build: dispatch `apk.yml` with
`build_number` above the installed versionCode/10.

A local `flutter build apk` can leave a higher versionCode on the phone than
CI's, and `adb install -r` then fails with `INSTALL_FAILED_VERSION_DOWNGRADE`.
Do not bump the pubspec build number for this: it is the release identity
(store changelogs, README version codes, workflow identity guards and release
tests all key off it).

1. Read the installed code: `adb shell dumpsys package io.github.kvnloo.z0agent | grep versionCode`.
2. Pick `n` greater than that code / 10. For an installed `30862`, `3087` works
   (arm64 versionCode `30872`).
3. Run "Release APK (z0 Agent)" (`apk.yml`) with `build_number` = `n`, e.g.
   `gh workflow run apk.yml --ref staging -f build_number=3087`.
4. Download the `z0-agent-test-<n>` artifact and `adb install -r` it.

Leaving `build_number` empty builds exactly as before (pubspec build number,
artifact `z0-agent-apk`). The input exists only on `apk.yml`; `play.yml` and
`release.yml` declare no dispatch inputs, so GitHub rejects a dispatch that
passes one. Test artifacts are named `z0-agent-test-<n>`, so the groot updater,
which reads `play.yml`'s `z0-agent-apk`, never installs them. Note the reverse:
until `play.yml`'s `(pubspec build + run number) * 10 + 2` passes `n * 10 + 2`,
the auto-updater's installs on that phone fail as downgrades.

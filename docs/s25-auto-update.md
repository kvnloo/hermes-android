# S25 auto-update from staging

Every green `Play AAB (z0 Agent)` run on `staging` reaches Kevin's S25 without a human.

1. `play.yml` builds an arm64 APK signed with the upload key. Its versionCode is
   `(pubspec build + 1000 + run number) * 10 + 2`, so each run installs over the
   last and over any `apk.yml` test build with `n` below `pubspec build + 1000`. The
   APK and `apk.json` (sha, run id, versionCode, signer) are uploaded as the
   `z0-agent-apk` artifact. Nothing is uploaded to Play.
2. On groot, `s25-z0-update.timer` (systemd user, every 5 min) runs
   `~/.local/bin/s25-z0-update`. It takes the newest successful staging run,
   downloads the artifact, checks the signer, sha and versionCode, and runs
   `adb install -r`. It never uninstalls the app or clears its data.
3. The phone is found by identity (serial + model), never by a fixed address.
   If it is not already on adb, the updater tries the last endpoint that
   worked, then the adb mDNS service named for its serial, then a port scan of
   its last LAN IP and its tailscale IP. While a green run waits for the
   phone, it stays pending; after 20 minutes the wait is reported once.
4. Receipts go to `~/.local/state/s25-update/receipts.jsonl` on groot, to the
   Studio film log (with a small evidence JSON per decision), to the z0live
   kanban card, and as a comment on the merged pull request.

## Testing on a phone that has a newer local build

Testing on a phone that has a newer local build: dispatch `apk.yml` with
`build_number` above the installed versionCode/10.

A local `flutter build apk` can leave a higher versionCode on the phone than
CI's, and `adb install -r` then fails with `INSTALL_FAILED_VERSION_DOWNGRADE`.
Do not bump the pubspec build number for this: it is the release identity
(store changelogs, README version codes, workflow identity guards and release
tests all key off it).

1. Read the installed code: `adb shell dumpsys package io.github.kvnloo.z0agent | grep versionCode`.
2. Pick `n` greater than that code / 10 and below `pubspec build + 1000` (4066
   today), so the next staging build still installs over it. For an installed
   `30862`, `3087` works (arm64 versionCode `30872`).
3. Run "Release APK (z0 Agent)" (`apk.yml`) with `build_number` = `n`, e.g.
   `gh workflow run apk.yml --ref staging -f build_number=3087`.
4. Download the `z0-agent-test-<n>` artifact and `adb install -r` it.

Leaving `build_number` empty builds exactly as before (pubspec build number,
artifact `z0-agent-apk`). The input exists only on `apk.yml`; `play.yml` and
`release.yml` declare no dispatch inputs, so GitHub rejects a dispatch that
passes one. Test artifacts are named `z0-agent-test-<n>`, so the groot updater,
which reads `play.yml`'s `z0-agent-apk`, never installs them. Note the reverse:
a test build with `n` at or above `pubspec build + 1000 + run number` makes the
auto-updater skip staging builds as downgrades until the run number catches up.

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

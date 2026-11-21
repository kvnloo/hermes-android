# Parity checklist: fork vs the official Hermes Android app

Target: the official app `ai.nousresearch.hermes.mobile` 1.0.0 (44). The fork keeps its NextGen theme engine and ephemeral-ui.

An item is checked only if a screenshot shows it working. Evidence is one of two kinds:

- `parity/<name>.jpg`: committed in this folder, downscaled.
- `local <path> <sha256 prefix>`: kept off this public repo because it shows private data (hostnames, emails, profile, session or task names). The path is under the parity workspace `hermes-uiux/shots/`. The hash is the first 12 hex digits of the full PNG's sha256.

Device: **S25** is Kevin's Galaxy S25 Ultra running the signed CI build of `11f4436`, then `10ce448`, on a hidden display. **emu** is the Pixel 8-sized emulator from PR #16. **emu-s** is the same emulator on `staging`: the debug build of `c2c81fa`, and for Glass the CI APK of `2d860bb` (PR #28). The S25 refused adb on 2026-11-21, so this round has no S25 shots.

## Hosts and sign-in

- [x] Add an instance by address and test it. Studio: local `fork-s25/s25-002-tested.png` `148530e0fe92` (S25). groot: local `fork-s25/s25-030-groot-tested.png` `b5a2fac35b26` (S25).
- [x] Password sign-in to Studio: local `fork-s25/s25-003-signin.png` `64a8868e1eed`, then home at local `fork-s25/s25-004-signedin.png` `87f3c5852dab` (S25).
- [x] Several saved instances, Settings → Self-Hosted Instances: local `fork-s25/s25-021-instances.png` `1dd8268a5ce1` (S25).
- [x] **Studio round trip.** Sent "Reply with exactly A0262-PONG-S25 and nothing else" and got `A0262-PONG-S25` back: `parity/s25-010-studio-roundtrip.jpg` (S25). Studio's `state.db` has both turns in session `20261120_212958_380baa`.
- [x] Browser (Google OIDC) sign-in to groot, on the build of `10ce448`. Google account step: local `fork-s25/s25-033-groot-oidc.png` `e7e83997d00a`. The app's loopback answers "Signed in": `parity/s25-044-groot-returned.jpg`. Home lists groot's bots: local `fork-s25/s25-045-groot-after-close.png` `26c3441ecd3f`. groot logged `native_token_success`. On the build of `11f4436` the app froze behind the tab and the redirect never landed (local `fork-s25/s25-036-groot-wait.png` `59c564ad98bb`); `60a487a` fixed that.
- [x] **groot round trip.** Sent "Reply with exactly A0262-PONG-GROOT and nothing else" and got `A0262-PONG-GROOT` back: `parity/s25-050-groot-roundtrip.jpg` (S25). groot's `state.db` has both turns in session `20261120_215716_0db3ab`.
- [ ] After a browser sign-in the tab stays open on "Signed in" until the user closes it. Not compared with the official app. Reason: the comparison needs a browser sign-in in the official app against an OIDC host. The emulator has no saved OIDC credentials, and the S25 refused adb this round.

## Home

- [x] Bot list with last message and time: local `fork-s25/s25-004-signedin.png` `87f3c5852dab` (S25).
- [x] Filters (view, sort, recent, show, agents, include groups): local `fork/r2-011-filters.png` `67828b1275c9` (emu).
- [x] New session sheet with every bot and New group: local `fork-s25/s25-005-newsession.png` `1edbc30607c7` (S25).
- [x] Search filters the bot list as you type: local `fork/a3-search-typed.png` `0228256db894` (emu-s).

## Chat

- [x] Empty chat, bot pill, composer with attach and dictate: `parity/s25-006-chat.jpg` (S25).
- [x] Tool summary row, Copy, Read aloud, Report, Retry and token count: `parity/r2-063-turn.jpg` (emu).
- [x] Dictation puts the header avatar into listening: `parity/r2-051-dictating.jpg` (emu).
- [x] Chat style (Bubbles): `parity/r2-121-bubbles.jpg` (emu).
- [x] More → Artifacts: `parity/r2-03-Artifacts.jpg` (emu).
- [x] More → Execution: `parity/r2-03-Execution.jpg` (emu).
- [x] More → Terminal: `parity/r2-03-Terminal.jpg` (emu).
- [x] "Worked for %s" after a turn ("Worked for 5s"): `parity/a3-chat-turn.jpg` (emu-s, disposable host). PR #26.
- [x] Reactions with skin tone (`message.react`). Picker with SKIN TONE row: `parity/a3-reaction-picker.jpg`. The host-confirmed 👍🏼 under the reply: `parity/a3-reaction-sent.jpg` (emu-s, disposable host). PR #26.
- [x] "Load earlier messages" at the top of a long chat: local `fork/a3-load-earlier.png` `4cb2c20471c9`. After the tap, the earlier turns are shown: local `fork/a3-load-earlier-after.png` `bf568317bcf3` (emu-s). PR #26.
- [x] "Memory updated" row after a background review writes memory: `parity/a3-memory-updated.jpg` (emu-s, disposable host), full PNG at local `fork/a3-memory-updated.png` `ca13636b5bf1`. Row built in PR #26; delivery fixed in the PR from `fix/review-summary-delivery`.
  - **Fault: the app dropped the event.** The host was fine. A review that writes USER.md logs `result=memory` but publishes `💾 Self-improvement review: User profile updated` (`display.review.label.user`). `NgChatController._isMemoryUpdate` matched only `Memory updated`, so it ignored that `review.summary` without drawing anything. The disposable host has no MEMORY.md, so every `result=memory` there, including the 02:38:42 one, was a USER.md write. The fix accepts both labels. The regression test `a user-profile review summary shows the memory row` in `test/nextgen_long_chat_test.dart` fails on the old matcher. It also checks that skill-only summaries, staged proposals and other sessions' summaries draw no row.
  - **Trace.** Host side: `agent/background_review.py` `_publish_review_summary` calls `background_review_callback`. `tui_gateway/session_registry.py` turns that into `_emit("review.summary", <ui session id>)`, which `tui_gateway/server.py` writes as `{"method":"event","params":{"type":"review.summary","session_id":…}}` on the WebSocket that owns the session. Wire probe (Node WebSocket on `/api/ws`): ui session `53b78606`, stored `20261121_033330_bc3fab`, `result=memory` at 03:33:41, then a `review.summary` with the user-profile label on that same session 10.7 s after the prompt. App: ui session `054aaa84`, connected 03:42:41, prompt 03:43:32, `result=memory` 03:43:42, USER.md written 03:43:39, row drawn under the reply.
  - **Reproduce.** (1) Disposable host: `HERMES_HOME=hermes-uiux/testhost/home hermes dashboard --host 127.0.0.1 --port 9131 --skip-build --no-open`, with `memory: nudge_interval: 1` in its `config.yaml`. (2) `adb reverse tcp:9131 tcp:9131`, then in the app Settings → Self-Hosted Instances → + → `127.0.0.1:9131` → Test → Continue. (3) In a Hermes chat, send a fact without asking the agent to save it, and tell it not to use tools, e.g. "Answer in one line and do not call any tools: what is 23 times 3? About me: I play cello in a community orchestra on Thursdays." If the turn itself calls `memory`, the review has nothing left to do and logs `result=none`. (4) Within about 10 s the row appears; `agent.log` shows `Background review complete … result=memory`.
  - **Remaining limits.** (a) The summary is live only: it is not in the transcript, so a chat reopened from history has no row, e.g. session `20261121_033330_bc3fab` reopened at 03:43 before its second turn. (b) The host publishes no summary for a memory `patch` (`Entry patched.`) and logs `result=none` (host `_action_lines`); the app cannot show what it never receives. (c) The app matches the English labels only; a host running another locale (e.g. `hu`: `… frissítve`) still gets no row. (d) Not tested: a review that finishes after the app has disconnected.

## Live Mode and avatars

- [x] Live Mode call surface (bot pill, orb, prompt, mic, close): `parity/r3-010-live.jpg` (emu).
- [ ] GPT-Live over WebRTC on a real device. Built, never run against a host that offers it. Reason: no host Kevin runs is known to offer GPT-Live, and the S25 was unreachable this round.
- [x] Avatar styles a user picks: faces, voice orb (Persona looks), thinking orb: `parity/053-picker-persona.jpg`, `parity/055-picker-orbs.jpg`, `parity/054-persona-rest.jpg` (emu).

## Groups

- [x] Create a group from member bots: `parity/r2-102-creategroup.jpg` (emu), member picker at local `fork/r2-013-newgroup.png` `8727f933fd5d`.
- [x] Group room where two bots answer: `parity/r2-104-roomreply.jpg` (emu, disposable host).

## Agent settings

- [x] Agent settings page: `parity/r2-070-agent.jpg` (emu).
- [x] Model: `parity/r2-07-Model.jpg` (emu).
- [x] Connections: `parity/r2-14-Connections.jpg` (emu).
- [x] Plugins with counts (64, 59 enabled): `parity/r2-14-Plugins.jpg` (emu).
- [x] MCP: `parity/r2-14-MCP.jpg` (emu).
- [x] Projects: `parity/r2-08-Projects.jpg` (emu).
- [x] Kanban with the real board: local `fork/r2-08-Kanban.png` `3dc0768c776c` (emu).
- [x] Artifacts for all of a bot's chats: local `fork/r2-08-Artifacts-poteto2.png` `3ec9424d0cb8` (emu).
- [x] Routines (the bot's scheduled jobs): local `fork/a3-routines.png` `b4bfab145f24` (emu-s). New Agent form: `parity/a3-newagent.jpg` (emu-s).

## Settings

- [x] Settings tree: `parity/s25-020-settings.jpg` (S25).
- [x] Security (screen lock toggle): `parity/r2-130-security.jpg` (emu). The lock prompt itself is a secure window and captures as black.
- [x] Caching: `parity/r2-09-Caching.jpg` (emu).
- [x] Terminal Connection over SSH: `parity/r2-111-termconn.jpg` (emu). Trust prompt: local `fork/r3-040-trust.png` `a5cf826b5b7a`. Live shell printing `parity-42`: local `fork/r3-032-terminal-shell.png` `5e3ad0b02f05`.
- [x] Look & Feel: theme mode, the new Solid/Glass surface, the theme engine's looks, and Import / Copy theme JSON: `parity/a3-lookfeel-surface.jpg`. Glass over the wallpaper: `parity/a3-glass-settings.jpg` (emu-s, PRs #25 and #28). Ephemeral-ui (OpenUI) boards render natively since PR #18, covered by widget tests; no screenshot.

## System surfaces in the official manifest

Built in PR #27 unless a reason is given.

- [x] Quick Settings tiles New Chat and Live Voice: `parity/a3-qs-tiles.jpg`. New Chat opens a new NextGen chat (`parity/a3-qs-newchat-opened.jpg`) and Live Voice opens Live Mode (`parity/a3-qs-livevoice-opened.jpg`) (emu-s).
- [x] Home screen widget "Hermes Agent Actions" with New Chat and Live Voice: `parity/a3-widget-home.jpg`. New Chat opened a new chat (emu-s).
- [x] Launcher shortcuts New Chat, Start Live Voice, Open Sessions, the same set as the official app: `parity/a3-shortcuts.jpg` (emu-s).
- [x] Share target: shared text lands as a NextGen new-chat draft: `parity/a3-share-text.jpg` (emu-s).
- [ ] System assistant: VoiceInteractionService, assist overlay, screen share. Reason: not built. It needs a VoiceInteractionService, a session service, an assist overlay activity and a screen-share foreground service, which is its own feature. Follow-up card.
- [ ] Device access: Health Connect, calendar, contacts, location, exact alarms. Reason: not built. Each source needs a permission flow on the phone and a tool contract with the host. Follow-up card.
- [ ] App Functions ("Ask your Hermes bots, run their routines…"). Reason: not built. It needs the AndroidX AppFunctions service and its generated schema, which no installed agent on Kevin's devices calls yet. Follow-up card.
- [x] Bot directory import (`application/vnd.ai.nousresearch.hermes.mobile.bot+json`): opening a bot file shows Import bot with name, title and description: local `fork/a3-bot-import.png` `5a5afe92d2c5` (emu-s). Fields beyond `name`, `title` and `description` aren't confirmed from the official app.
- [ ] Document scanner. Reason: not built. The official app uses the ML Kit document scanner, which adds a Google Play services dependency. Follow-up card.
- [ ] Push notifications with actions. The fork has `MobilePushService`; not compared. Reason: the official app pushes through Firebase and the fork through UnifiedPush. Comparing actions needs both apps registered for push on one host, which this round didn't set up.

## Boat validation

- [ ] Refresh store goldens with Nunito: three Flutter goldens regenerated and matched on rerun; needs emulator/S25 screenshot.

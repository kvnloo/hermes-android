# Parity checklist: fork vs the official Hermes Android app

Target: the official app `ai.nousresearch.hermes.mobile` 1.0.0 (44). The fork keeps its NextGen theme engine and ephemeral-ui.

An item is checked only if a screenshot shows it working. Evidence is one of two kinds:

- `parity/<name>.jpg`: committed in this folder, downscaled.
- `local <path> <sha256 prefix>`: kept off this public repo because it shows private data (hostnames, emails, profile, session or task names). The path is under the parity workspace `hermes-uiux/shots/`. The hash is the first 12 hex digits of the full PNG's sha256.

Device: **S25** is Kevin's Galaxy S25 Ultra running the signed CI build of `11f4436` on a hidden display. **emu** is the Pixel 8-sized emulator from PR #16.

## Hosts and sign-in

- [x] Add an instance by address and test it. Studio: local `fork-s25/s25-002-tested.png` `148530e0fe92` (S25). groot: local `fork-s25/s25-030-groot-tested.png` `b5a2fac35b26` (S25).
- [x] Password sign-in to Studio: local `fork-s25/s25-003-signin.png` `64a8868e1eed`, then home at local `fork-s25/s25-004-signedin.png` `87f3c5852dab` (S25).
- [x] Several saved instances, Settings → Self-Hosted Instances: local `fork-s25/s25-021-instances.png` `1dd8268a5ce1` (S25).
- [x] **Studio round trip.** Sent "Reply with exactly A0262-PONG-S25 and nothing else" and got `A0262-PONG-S25` back: `parity/s25-010-studio-roundtrip.jpg` (S25). Studio's `state.db` has both turns in session `20261120_212958_380baa`.
- [ ] Browser (Google OIDC) sign-in to groot. The Google step finished: local `fork-s25/s25-033-groot-oidc.png` `e7e83997d00a`. groot logged `login_success` and `native_code_issued`. The app was frozen behind the tab, so the redirect never landed: local `fork-s25/s25-036-groot-wait.png` `59c564ad98bb`. Fixed in `60a487a`; not yet re-run on the S25.
- [ ] groot round trip. Waits on the item above.

## Home

- [x] Bot list with last message and time: local `fork-s25/s25-004-signedin.png` `87f3c5852dab` (S25).
- [x] Filters (view, sort, recent, show, agents, include groups): local `fork/r2-011-filters.png` `67828b1275c9` (emu).
- [x] New session sheet with every bot and New group: local `fork-s25/s25-005-newsession.png` `1edbc30607c7` (S25).
- [ ] Search. Built, no screenshot yet.

## Chat

- [x] Empty chat, bot pill, composer with attach and dictate: `parity/s25-006-chat.jpg` (S25).
- [x] Tool summary row, Copy, Read aloud, Report, Retry and token count: `parity/r2-063-turn.jpg` (emu).
- [x] Dictation puts the header avatar into listening: `parity/r2-051-dictating.jpg` (emu).
- [x] Chat style (Bubbles): `parity/r2-121-bubbles.jpg` (emu).
- [x] More → Artifacts: `parity/r2-03-Artifacts.jpg` (emu).
- [x] More → Execution: `parity/r2-03-Execution.jpg` (emu).
- [x] More → Terminal: `parity/r2-03-Terminal.jpg` (emu).
- [ ] "Worked for %s" after a turn. Not built.
- [ ] Reactions with skin tone (`message.react`). Not built.
- [ ] "Load earlier messages". Not built.
- [ ] "Memory updated" row. Not built.

## Live Mode and avatars

- [x] Live Mode call surface (bot pill, orb, prompt, mic, close): `parity/r3-010-live.jpg` (emu).
- [ ] GPT-Live over WebRTC on a real device. Built, never run against a host that offers it.
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
- [ ] Routines and New Agent. Built, no screenshot yet.

## Settings

- [x] Settings tree: `parity/s25-020-settings.jpg` (S25).
- [x] Security (screen lock toggle): `parity/r2-130-security.jpg` (emu). The lock prompt itself is a secure window and captures as black.
- [x] Caching: `parity/r2-09-Caching.jpg` (emu).
- [x] Terminal Connection over SSH: `parity/r2-111-termconn.jpg` (emu). Trust prompt: local `fork/r3-040-trust.png` `a5cf826b5b7a`. Live shell printing `parity-42`: local `fork/r3-032-terminal-shell.png` `5e3ad0b02f05`.
- [ ] Look & Feel (the fork's theme engine) and ephemeral-ui cards. Kept, no screenshot this round.

## System surfaces in the official manifest

None of these are in the fork yet unless noted.

- [ ] Quick Settings tiles: New Chat and Live Voice.
- [ ] Home screen widget "Hermes Agent Actions".
- [ ] Launcher shortcuts New Chat, Live Voice, Sessions. The fork has its own `shortcuts.xml`; not compared.
- [ ] Share target. The fork accepts SEND and SEND_MULTIPLE; not compared.
- [ ] System assistant: VoiceInteractionService, assist overlay, screen share.
- [ ] Device access: Health Connect, calendar, contacts, location, exact alarms.
- [ ] App Functions ("Ask your Hermes bots, run their routines…").
- [ ] Bot directory import (`application/vnd.ai.nousresearch.hermes.mobile.bot+json`).
- [ ] Document scanner.
- [ ] Push notifications with actions. The fork has `MobilePushService`; not compared.

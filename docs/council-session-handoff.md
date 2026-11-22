# Council session handoff (HA-041)

Glide's `/council` reads a `glide.council-run/v1` JSON snapshot. On Glide
main, `/council card` publishes an ephemeral transcript card with a
summary and a local popup callback. The card is not a durable council
snapshot and does not contain the reports needed by Android.

## Proposed session envelope

The snapshot format is unchanged. Until the Glide handoff contract is
published, the Android reader assumes the following session envelope:

- The writer stores the council under the selected Hermes bot profile,
  in a dedicated session with `source: "council"` in the dashboard session
  list. The session's `id` is the shared identity; the title is for display.
- Once a snapshot is available, the writer stores the complete v1 JSON
  object as the plain string `content` of the latest assistant message
  in that session (no Markdown fences or added fields). Store an updated
  snapshot as another complete latest message under the same ID.
- Android uses the bot's existing dashboard client to read the latest
  message of that exact session. It doesn't create a session, send a
  message, or read Glide's configured endpoint directly. An empty council
  can be retried; an invalid snapshot is never replaced with a demo.

On Android, expand the bot on Home and tap its **Council · …** row (also
available in **Show all**). The card shows the shared ID, brief and reports.
Use **Read all** or select a report to keep listening. Playback is local:
there is no shared sentence offset, automatic playback, or live audio stream.
A retry or reopen reads the current saved snapshot.

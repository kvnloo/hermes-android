# HA-035: Live Mode lanes as orbiting orbs

Dash's z0live call can have lanes attached to the current thread: a fast
lane, a large lane and a council lane (Dash DA-024, lane timeline DA-077).
Each lane has a status (working, idle, error), what it is doing now, and what
it last handed back. Live Mode on Android now has the same lanes.

## What the user sees

- With lanes on offer, a **Lanes** button sits left of the mic. It opens
  "Lanes on this thread" with one switch each for Fast, Large and Council.
- Each attached lane is a small orb on a slow orbit around the bot's orb
  (bolt = Fast, head = Large, group = Council) with its name under it. The
  ring is accent while the lane works (with a spinner), red after an error.
  With system animations off the orbit holds still.
- A line under the status sums the lanes up the way Dash's collapsed lane
  panel does, e.g. `3 lanes · 1 working · Large: Working on "is the plan sound"`.
- **Routing.** Tap a lane orb and "Talking to Fast" shows under the status;
  the next heard turn goes to that lane, its reply is spoken, and both lines
  land in the transcript as `You → Fast` and `Fast lane`. Tap another lane to
  switch, tap the bot's orb (or the same lane again) to talk to the bot.
  Detaching the lane in use routes back to the bot. On a GPT-Live call a
  delegation goes to the selected lane and its reply goes back to the voice.

## Where lanes come from

The Hermes gateway has no multi-lane RPC: upstream `tui_gateway/server.py`
offers `session.*`, `prompt.submit` and `model.options`, nothing for lanes.
So lanes sit behind a `LiveLanes` seam (`lib/hm/features/live/live_lanes.dart`)
and the only driver is `FixtureLiveLanes`: scripted replies after a fixed
latency (Fast 0.6 s, Large 2 s, Council 3 s). It speaks Dash's broker lane
records (`lane_attached`, `lane_step`, `lane_handoff`, `lane_error`,
`lane_detached`) and can replay a JSONL tail of them, so a gateway or bridge
that emits those records can drive the same UI later.

Production builds offer no lanes, and Live Mode is unchanged. A build made
with `--dart-define=HERMES_LIVE_LANES_FIXTURE=true` offers the fixture lanes
on every call; the sheet says the answers are scripted.

## Tests

- `test/hm/live_lanes_test.dart`: record folding, summary text, the fixture,
  and the controller routing chained and GPT-Live turns per lane.
- `test/hm/live_lanes_screen_test.dart`: orbs on one circle 120° apart that
  move over time, still under reduce motion, routing by tap, the sheet,
  detaching the target, and an error on an orb.

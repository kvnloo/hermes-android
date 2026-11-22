# Parity captures and the parity diff

Goal: our app and the official Hermes Android app (`ai.nousresearch.hermes.mobile`) look and behave the same, screen by screen. Our theme engine and ephemeral UI stay; the background does not count. `tools/parity_diff.py` measures how close one screen is. `tools/parity_report.py` runs every screen and writes `report/README.md`.

The older `*.jpg` / `*.mp4` files in this folder are hand-taken notes. The diff only reads the folders below.

## Layout

```
docs/parity/
  reference/official-<screen>.png   official app screenshot
  reference/official-<screen>.xml   uiautomator dump of the same frame
  current/z0agent-<screen>.png      our app, same screen, same state
  current/z0agent-<screen>.xml
  report/<screen>.md                generated: verdict, issues, per-element table, heatmap link
  report/<screen>.json              generated: the same data as JSON
  report/<screen>-heatmap.png       generated
  report/README.md                  generated: one row per screen
```

`<screen>` is lowercase kebab-case and names the screen and its state, e.g. `chat-empty`, `chat-turn`, `drawer-open`, `settings`, `sessions-expanded`. Both apps are captured in the same state (same sessions and text, same section expanded or collapsed). A screen with no `current/` pair shows up as FAIL ("no capture").

## How captures are made

tek makes the captures on the Studio with Kevin's S25. Boat sandboxes have no phone, so they never capture.

- Both apps run on fsdisplay, the focus-safe virtual display, so capturing doesn't steal focus from the phone's main screen. The display has the same size and density as display 0 (the S25 panel), so pixel bounds are comparable across captures.
- For each screen: put both apps in the same state, then save a PNG screenshot and a `uiautomator dump` of that same frame. Bounds in the XML are in physical px.
- Official captures are references. They change only when the official app changes. Ours are re-captured after a UI change.
- Captures hold screen content only. Use demo data, with no real names, hosts, tokens or messages on screen.

## What the diff does

1. Layout. It parses both XML dumps and keeps visible leaf-ish nodes: anything with text or a content-desc, anything clickable, checkable or long-clickable, and images. Status-bar nodes (`com.android.systemui`) are dropped. Nodes are matched by equal label first. A label is the text or the content-desc with state words such as "expanded", "collapsed" or "selected" removed. What's left is matched by role (button, input, image, text) and nearest position within a radius. The report lists elements missing in ours and extra in ours. For each matched pair it gives the dx/dy/dw/dh delta in px and in % of the screen, any text change, the font size (the bounds height of a text node) and the visual state (expanded, checked, selected).
2. Pixels, background ignored. Each image's background is estimated per row as the median colour of the pixels outside all elements, plus the dominant colour. This covers flat backgrounds and vertical gradients. Only the element region (the union of matched bounds) is compared. Pixels that are background in both images are skipped. A pixel counts as different when no pixel in its 3x3 neighbourhood in the other image is within `--pixel-delta` on every channel, and the difference can't be explained as the same translucent or anti-aliased content over a different background (`A - B = t * (bgA - bgB)` for some `t` between 0 and 1). The heatmap marks differing pixels red, missing elements with a yellow box, extra elements with a magenta box and out-of-tolerance elements with cyan/blue boxes.
3. Verdict. A screen passes when all of these hold:
   - no interactive element is missing or extra,
   - every matched element is within `--pos-px` 4 px or `--pos-pct` 1% of the screen dimension on x, y, width and height,
   - every matched element has the same visual state (for example, a list that is expanded in the official app is not collapsed in ours),
   - under `--pixel-pct` 3% of element pixels differ,
   - both screenshots are the same size.

   The score runs 0-100. A passing screen scores 90 or more and a failing one 89 or less. Text changes and missing or extra non-interactive nodes lower the score. Text changes never fail a screen. Missing or extra non-interactive nodes fail it only with `--fail-on-missing-any`.

Other flags: `--pixel-delta` (24), `--bg-tol` (12), `--match-radius-pct` (8% of the diagonal), `--keep-system`. Exit codes are 0 for pass, 1 for fail and 2 for missing inputs.

## Running it

Python 3 with `pillow` and `numpy`, no network:

```
python3 -m pip install pillow numpy pytest
python3 tools/parity_diff.py chat-empty              # one screen -> docs/parity/report/chat-empty.md
python3 tools/parity_report.py                       # every screen -> docs/parity/report/README.md
python3 tools/parity_report.py --screens chat-empty,settings
python3 -m pytest -q tools/test_parity_diff.py       # synthetic fixtures
```

To try it without captures, generate the synthetic fixtures and report on them:

```
python3 tools/parity_fixtures.py /tmp/parity-demo
python3 tools/parity_report.py --root /tmp/parity-demo
```

## Using it in a UI lane (done_check)

A lane that changes a screen names the screens it touches. Its done_check is:

```
python3 tools/parity_report.py --screens <screen>[,<screen>...]    # must exit 0
```

It runs on fresh `current/` captures from tek. A lane can't capture on Boat. Until tek sends captures, the lane lists the screens under "Needs device check" and commits no guessed captures. Commit the regenerated `report/` files with the captures. Don't loosen thresholds to make a screen pass. If an exception is really needed, say so in the PR body.

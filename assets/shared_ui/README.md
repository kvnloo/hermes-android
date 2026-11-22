# Pinned ephemeral-ui inputs

`PIN.json` records the upstream commit and public versions for
`theme/glide.json`, `theme/tokens.schema.json` and `catalog/catalog.json`
from `kvnloo/ephemeral-ui`. Copy these files byte-for-byte at the new
revision and update the pin when upstream changes. Flutter builds and tests
use local assets only. `python3 scripts/check_shared_ui_pin.py` (the PR gate)
checks the committed bytes against the recorded revision; `--upstream main`
detects newer upstream data and runs only on schedule/dispatch, so upstream
merges never fail PRs. Nothing downloads assets into the app at runtime.

Classic and NextGen use the shared default palette, Material type scale and
radii, with existing explicit palette/preset choices preserved. CSS font
stacks use Flutter's platform sans face; existing custom widgets can retain
their own typography. Shared glass metadata is available in the extension;
NextGen glass uses the shared bar tint as a minimum so it does not relax the
existing accessibility floor. Native Android blur and the elemental material
shader remain platform-specific.

HA-042's Turbo control shares one persisted preference across Classic and
NextGen. Theme transitions use `duration(role, turbo: true)`; route, sheet
and widget animations with their own durations divide by the same
`turboFactor` (2× speed means half the duration). Reduced motion still takes
precedence.

Both Settings screens link to the catalog gallery. This app doesn't yet have
an ephemeral-ui v0 native renderer: every fixture gets an explicit
unsupported cell (or unavailable when the fixture provides no data). OpenUI
boards use a different input format and aren't used as a stand-in. Native
props parity is therefore not claimed.

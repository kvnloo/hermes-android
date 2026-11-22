# Pinned ephemeral-ui inputs

`PIN.json` records the upstream commit and public versions for
`theme/glide.json`, `theme/tokens.schema.json` and `catalog/catalog.json`
from `kvnloo/ephemeral-ui`. Copy these files byte-for-byte at the new
revision and update the pin when upstream changes. Flutter builds and tests
use local assets only. `python3 scripts/check_shared_ui_pin.py` checks the
committed bytes against the recorded revision and detects newer upstream data;
it never downloads assets into the app at runtime.

Classic and NextGen use the shared default palette, Material type scale and
radii, with existing explicit palette/preset choices preserved. CSS font
stacks use Flutter's platform sans face; existing custom widgets can retain
their own typography. Shared glass metadata is available in the extension;
NextGen glass uses the shared bar tint as a minimum so it does not relax the
existing accessibility floor. Native Android blur and the elemental material
shader remain platform-specific.

HA-042's Turbo control is not in this branch's staging base. Theme
transitions use the same persisted preference name as HA-042. The Flutter
theme exposes `turboFactor` and `duration(role, turbo: true)`; durations
divide by the factor (2× speed means half the duration). Route transitions
with pre-existing durations should likewise divide by the extension's
`turboFactor`, not keep a separate magic multiplier.

Both Settings screens link to the catalog gallery. This app doesn't yet have
an ephemeral-ui v0 native renderer: every fixture gets an explicit
unsupported cell (or unavailable when the fixture provides no data). OpenUI
boards use a different input format and aren't used as a stand-in. Native
props parity is therefore not claimed.

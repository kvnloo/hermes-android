#!/usr/bin/env python3
"""Verify vendored ephemeral-ui sources and check for newer published data."""

import json
import plistlib
import re
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "assets/shared_ui"
RAW = "https://raw.githubusercontent.com/kvnloo/ephemeral-ui"
FILES = ("theme/glide.json", "theme/tokens.schema.json", "catalog/catalog.json")


def fetch(ref, source):
    with urlopen(f"{RAW}/{ref}/{source}", timeout=20) as response:
        return response.read()


def main():
    pin = json.loads((VENDOR / "PIN.json").read_text())
    revision = pin["revision"]
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise SystemExit("PIN.json must name a full ephemeral-ui commit SHA")

    errors = []
    for source in FILES:
        local = (VENDOR / Path(source).name).read_bytes()
        pinned = fetch(revision, source)
        if local != pinned:
            errors.append(f"{source}: vendored bytes differ from {revision}")
        if pinned != fetch("main", source):
            errors.append(f"{source}: pin is stale; re-vendor from ephemeral-ui upstream")

    theme = json.loads((VENDOR / "glide.json").read_text())
    catalog = json.loads((VENDOR / "catalog.json").read_text())
    for name, data in (("theme", theme), ("catalog", catalog)):
        if data["v"] != 0 or data["version"] != pin[f"{name}Version"]:
            errors.append(f"{name}: incompatible format or PIN.json version mismatch")

    brand = theme["brand"]["name"]
    if (ROOT / "fastlane/metadata/android/en-US/title.txt").read_text().strip() != brand:
        errors.append("Android store title differs from the shared brand name")
    with (ROOT / "ios/Runner/Info.plist").open("rb") as plist_file:
        if plistlib.load(plist_file).get("CFBundleDisplayName") != brand:
            errors.append("iOS display name differs from the shared brand name")
    gradle = (ROOT / "android/app/build.gradle.kts").read_text()
    labels = re.findall(r'manifestPlaceholders\["appLabel"\]\s*=\s*"([^"]+)"', gradle)
    if labels != [brand, f"{brand} Dev"]:
        errors.append("Android launcher labels differ from the shared brand name")

    if errors:
        raise SystemExit("\n".join(errors))
    kinds = catalog["kinds"]
    fixtures = sum(len(kind["fixtures"]) for kind in kinds)
    print(f"Verified {revision}: theme v{theme['version']}, "
          f"catalog v{catalog['version']} ({len(kinds)} kinds, {fixtures} fixtures), "
          f"brand {brand}.")


if __name__ == "__main__":
    main()

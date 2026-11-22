#!/usr/bin/env python3
"""Verify vendored ephemeral-ui sources and check for newer published data.

  python3 scripts/check_shared_ui_pin.py                  # PR gate
  python3 scripts/check_shared_ui_pin.py --upstream main  # scheduled freshness

The PR gate compares vendored bytes with the immutable pinned commit and checks
versions and brand names, so its result depends only on the PR's own tree.
--upstream reports files whose pinned copy differs from the ref (drift); it
runs on schedule/dispatch so an ephemeral-ui merge never turns PRs red.
"""

import argparse
import json
import os
import plistlib
import re
import sys
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "assets/shared_ui"
RAW = "https://raw.githubusercontent.com/kvnloo/ephemeral-ui"
FILES = ("theme/glide.json", "theme/tokens.schema.json", "catalog/catalog.json")


def fetch(ref, source):
    with urlopen(f"{RAW}/{ref}/{source}", timeout=20) as response:
        return response.read()


def stale(revision, ref, fetch=fetch):
    """Files whose content at the pinned revision differs from ref."""
    return [
        f"{source}: pin {revision[:7]} is stale against {ref}; re-vendor from "
        "ephemeral-ui upstream"
        for source in FILES
        if fetch(revision, source) != fetch(ref, source)
    ]


def pinned_errors(revision, fetch=fetch, vendor=VENDOR):
    """Vendored files that are not byte-identical to the pinned revision."""
    return [
        f"{source}: vendored bytes differ from {revision}"
        for source in FILES
        if (vendor / Path(source).name).read_bytes() != fetch(revision, source)
    ]


def main(argv=None, fetch=fetch):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--upstream", metavar="REF", help="scheduled freshness check")
    args = parser.parse_args(argv)

    pin = json.loads((VENDOR / "PIN.json").read_text())
    revision = pin["revision"]
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise SystemExit("PIN.json must name a full ephemeral-ui commit SHA")

    if args.upstream:
        errors = stale(revision, args.upstream, fetch)
        if errors:
            path = os.environ.get("GITHUB_STEP_SUMMARY")
            if path:
                with open(path, "a", encoding="utf-8") as out:
                    out.write("### Shared UI pin drift\n\n"
                              + "".join(f"- {e}\n" for e in errors))
            raise SystemExit("\n".join(errors))
        print(f"Pin {revision} is current with {args.upstream}.")
        return

    errors = pinned_errors(revision, fetch)

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
    main(sys.argv[1:])

#!/usr/bin/env python3
"""Verify, check and refresh the vendored ephemeral-ui card catalog.

assets/shared_ui/catalog.json is a byte-for-byte copy of kvnloo/ephemeral-ui
catalog/catalog.json at the commit PIN.json names (`revision`), with its
`catalogVersion`. The same pin covers any theme files vendored beside it.

  python3 scripts/ephemeral_ui_catalog.py --verify          # offline shape/pin
  python3 scripts/ephemeral_ui_catalog.py --check-pinned    # PR gate: unedited?
  python3 scripts/ephemeral_ui_catalog.py --check-upstream  # scheduled: stale?
  python3 scripts/ephemeral_ui_catalog.py --update <ref>    # re-vendor from ref

--check-pinned fails when the copy differs from the pinned revision (it was
edited). It reads only the immutable pinned commit, so a PR's result depends
on its own tree. --check-upstream (schedule/dispatch only) fails when the copy
differs from the upstream ref, default main (it is stale), naming any kind
upstream has that the vendored copy, and so the gallery, does not cover.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "assets" / "shared_ui"
CATALOG = VENDOR / "catalog.json"
PIN = VENDOR / "PIN.json"
REPO = "kvnloo/ephemeral-ui"
RAW = "https://raw.githubusercontent.com/{repo}/{ref}/{path}"
CATALOG_PATH = "catalog/catalog.json"
# Other upstream files that may be vendored beside the catalog under one pin.
THEME_FILES = {"glide.json": "theme/glide.json", "tokens.schema.json": "theme/tokens.schema.json"}
COMMIT_API = "https://api.github.com/repos/{repo}/commits/{ref}"
SUPPORTED_SHAPE = 0


class CatalogError(Exception):
    pass


def parse(data: bytes) -> dict:
    catalog = json.loads(data)
    if catalog.get("v") != SUPPORTED_SHAPE:
        raise CatalogError(
            f"catalog shape v={catalog.get('v')!r}; this app reads v={SUPPORTED_SHAPE}"
        )
    kinds = catalog.get("kinds") or []
    count = catalog.get("count") or {}
    fixtures = sum(len(k.get("fixtures") or []) for k in kinds)
    if count.get("kinds") != len(kinds) or count.get("fixtures") != fixtures:
        raise CatalogError("catalog counts disagree with its kinds")
    return catalog


def kinds(catalog: dict) -> list[str]:
    return [k["kind"] for k in catalog["kinds"]]


def verify(catalog_bytes: bytes, pin: dict) -> dict:
    """Offline: the copy is a v0 catalog at the pinned version."""
    revision = pin.get("revision", "")
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise CatalogError("PIN.json revision must be a full ephemeral-ui commit SHA")
    catalog = parse(catalog_bytes)
    if catalog["version"] != pin.get("catalogVersion"):
        raise CatalogError(
            f"catalog version {catalog['version']} != PIN.json catalogVersion "
            f"{pin.get('catalogVersion')}"
        )
    return catalog


def unedited(catalog_bytes: bytes, pinned_bytes: bytes, revision: str) -> list[str]:
    """The copy is byte-identical to upstream at the pinned revision."""
    if catalog_bytes == pinned_bytes:
        return []
    return [
        f"assets/shared_ui/catalog.json differs from {REPO}@{revision[:7]}; "
        "never edit the copy, re-vendor with --update"
    ]


def compare(pinned: dict, local_bytes: bytes, upstream_bytes: bytes, ref: str) -> list[str]:
    """Problems that make the pinned copy stale against upstream; [] if current."""
    if upstream_bytes == local_bytes:
        return []
    upstream = parse(upstream_bytes)
    problems = []
    new = [k for k in kinds(upstream) if k not in set(kinds(pinned))]
    gone = [k for k in kinds(pinned) if k not in set(kinds(upstream))]
    if new:
        problems.append(f"uncovered kinds at {REPO}@{ref}: {', '.join(new)}")
    if gone:
        problems.append(f"kinds removed at {REPO}@{ref}: {', '.join(gone)}")
    if upstream["version"] != pinned["version"]:
        problems.append(
            f"catalog version {pinned['version']} pinned, {upstream['version']} at {ref}"
        )
    if not problems:
        problems.append(f"catalog.json changed at {ref} (fixtures or props)")
    return problems


def summary(markdown: str) -> None:
    """Append to the GitHub Actions job summary when running in Actions."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write(markdown)


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "hermes-android-ci"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--check-pinned", action="store_true")
    mode.add_argument("--check-upstream", nargs="?", const="main", metavar="REF")
    mode.add_argument("--update", metavar="REF")
    args = parser.parse_args(argv)

    pin = json.loads(PIN.read_text())
    try:
        if args.update:
            ref = args.update
            data = fetch(RAW.format(repo=REPO, ref=ref, path=CATALOG_PATH))
            catalog = parse(data)
            commit = json.loads(fetch(COMMIT_API.format(repo=REPO, ref=ref)))["sha"]
            CATALOG.write_bytes(data)
            pin["revision"] = commit
            pin["catalogVersion"] = catalog["version"]
            for name, path in THEME_FILES.items():
                if (VENDOR / name).exists():
                    theme = fetch(RAW.format(repo=REPO, ref=commit, path=path))
                    (VENDOR / name).write_bytes(theme)
                    if name == "glide.json":
                        pin["themeVersion"] = json.loads(theme)["version"]
            PIN.write_text(json.dumps(pin, indent=2) + "\n")
            print(
                f"vendored catalog v{catalog['version']} ({len(catalog['kinds'])} kinds) "
                f"from {REPO}@{commit[:7]}; add layouts for new kinds, then run "
                "flutter test --update-goldens"
            )
            return 0

        local = CATALOG.read_bytes()
        pinned = verify(local, pin)
        if args.verify:
            print(
                f"ok: catalog v{pinned['version']} ({len(pinned['kinds'])} kinds) "
                f"pinned at {pin['revision'][:7]}"
            )
            return 0

        revision = pin["revision"]
        if args.check_pinned:
            problems = unedited(
                local, fetch(RAW.format(repo=REPO, ref=revision, path=CATALOG_PATH)), revision
            )
            for problem in problems:
                print(f"edited: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"ok: catalog v{pinned['version']} is {REPO}@{revision[:7]} byte for byte")
            return 0

        ref = args.check_upstream
        problems = compare(
            pinned, local, fetch(RAW.format(repo=REPO, ref=ref, path=CATALOG_PATH)), ref
        )
        if problems:
            fix = f"python3 scripts/ephemeral_ui_catalog.py --update {ref}"
            for problem in problems:
                print(f"stale: {problem}", file=sys.stderr)
            print(f"re-vendor: {fix}", file=sys.stderr)
            summary(
                f"### ephemeral-ui catalog drift\n\nPinned {REPO}@{revision[:7]} is behind "
                f"`{ref}`:\n\n" + "".join(f"- {p}\n" for p in problems)
                + f"\nRe-vendor: `{fix}`\n"
            )
            return 1
        print(f"ok: catalog v{pinned['version']} at {revision[:7]} is current with {ref}")
        return 0
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

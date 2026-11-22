#!/usr/bin/env python3
"""Pin, verify and refresh the vendored ephemeral-ui card catalog.

assets/ephemeral_ui/catalog.json is a verbatim copy of kvnloo/ephemeral-ui
catalog/catalog.json; PIN.json records the commit, version and sha256.

  python3 scripts/ephemeral_ui_catalog.py --verify          # offline: copy == pin
  python3 scripts/ephemeral_ui_catalog.py --check-upstream  # fail when stale
  python3 scripts/ephemeral_ui_catalog.py --update <ref>    # re-vendor from ref

--check-upstream compares the pin with the catalog at the upstream ref
(default: main) and exits 1 when the pinned copy is stale, naming any kind
upstream has that the vendored copy (and so the gallery) does not cover.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "assets" / "ephemeral_ui"
CATALOG = VENDOR / "catalog.json"
PIN = VENDOR / "PIN.json"
REPO = "kvnloo/ephemeral-ui"
RAW = "https://raw.githubusercontent.com/{repo}/{ref}/catalog/catalog.json"
COMMIT_API = "https://api.github.com/repos/{repo}/commits/{ref}"
SUPPORTED_SHAPE = 0


class CatalogError(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    """The vendored copy is the pinned file, untouched."""
    digest = sha256(catalog_bytes)
    if digest != pin["sha256"]:
        raise CatalogError(
            f"assets/ephemeral_ui/catalog.json sha256 {digest} != pin {pin['sha256']}; "
            "never edit the copy, re-vendor with --update"
        )
    catalog = parse(catalog_bytes)
    if catalog["version"] != pin["version"]:
        raise CatalogError(
            f"catalog version {catalog['version']} != pin {pin['version']}"
        )
    return catalog


def compare(pinned: dict, pin: dict, upstream_bytes: bytes, ref: str) -> list[str]:
    """Problems that make the pinned copy stale against upstream; [] if current."""
    if sha256(upstream_bytes) == pin["sha256"]:
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


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "hermes-android-ci"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--check-upstream", nargs="?", const="main", metavar="REF")
    mode.add_argument("--update", metavar="REF")
    args = parser.parse_args(argv)

    pin = json.loads(PIN.read_text())
    try:
        if args.update:
            data = fetch(RAW.format(repo=REPO, ref=args.update))
            catalog = parse(data)
            commit = json.loads(fetch(COMMIT_API.format(repo=REPO, ref=args.update)))["sha"]
            CATALOG.write_bytes(data)
            pin.update(
                ref=args.update,
                commit=commit,
                version=catalog["version"],
                sha256=sha256(data),
            )
            PIN.write_text(json.dumps(pin, indent=2) + "\n")
            print(
                f"vendored catalog v{catalog['version']} ({len(catalog['kinds'])} kinds) "
                f"from {REPO}@{commit[:7]}; now add layouts for new kinds and "
                "run flutter test --update-goldens"
            )
            return 0

        pinned = verify(CATALOG.read_bytes(), pin)
        if args.verify:
            print(
                f"ok: catalog v{pinned['version']} ({len(pinned['kinds'])} kinds) "
                f"matches pin {pin['commit'][:7]}"
            )
            return 0

        ref = args.check_upstream
        problems = compare(pinned, pin, fetch(RAW.format(repo=REPO, ref=ref)), ref)
        if problems:
            for problem in problems:
                print(f"stale: {problem}", file=sys.stderr)
            print(
                f"re-vendor: python3 scripts/ephemeral_ui_catalog.py --update {ref}",
                file=sys.stderr,
            )
            return 1
        print(f"ok: pinned catalog v{pinned['version']} is current with {REPO}@{ref}")
        return 0
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

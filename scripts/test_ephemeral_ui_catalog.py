import contextlib
import copy
import io
import json
import os
import tempfile
import unittest
from unittest import mock

from scripts import ephemeral_ui_catalog as eui


def _catalog(kinds=("metric", "chat"), version="0.1.0"):
    return {
        "v": 0,
        "version": version,
        "count": {"kinds": len(kinds), "fixtures": len(kinds)},
        "kinds": [{"kind": k, "fixtures": [{"id": f"{k}/a"}]} for k in kinds],
    }


def _bytes(catalog):
    return json.dumps(catalog).encode()


class EphemeralCatalogPinTest(unittest.TestCase):
    def setUp(self):
        self.catalog = _catalog()
        self.data = _bytes(self.catalog)
        self.pin = {"revision": "a" * 40, "catalogVersion": "0.1.0"}

    def test_vendored_repo_copy_matches_its_pin(self):
        pin = json.loads(eui.PIN.read_text())
        catalog = eui.verify(eui.CATALOG.read_bytes(), pin)
        self.assertEqual(len(catalog["kinds"]), catalog["count"]["kinds"])

    def test_short_revision_fails_verify(self):
        with self.assertRaisesRegex(eui.CatalogError, "full ephemeral-ui commit"):
            eui.verify(self.data, dict(self.pin, revision="7c5daca"))

    def test_version_mismatch_fails_verify(self):
        with self.assertRaisesRegex(eui.CatalogError, "catalogVersion"):
            eui.verify(self.data, dict(self.pin, catalogVersion="0.2.0"))

    def test_edited_copy_is_reported(self):
        self.assertEqual(eui.unedited(self.data, self.data, "a" * 40), [])
        problems = eui.unedited(self.data + b" ", self.data, "a" * 40)
        self.assertTrue(problems and "never edit" in problems[0])

    def test_other_shape_is_rejected(self):
        other = dict(self.catalog, v=1)
        with self.assertRaisesRegex(eui.CatalogError, "shape"):
            eui.parse(_bytes(other))

    def test_bad_counts_are_rejected(self):
        other = copy.deepcopy(self.catalog)
        other["count"]["kinds"] = 5
        with self.assertRaisesRegex(eui.CatalogError, "counts"):
            eui.parse(_bytes(other))

    def test_identical_upstream_is_current(self):
        self.assertEqual(eui.compare(self.catalog, self.data, self.data, "main"), [])

    def test_new_upstream_kind_is_reported_uncovered(self):
        upstream = _bytes(_catalog(("metric", "chat", "weather"), "0.2.0"))
        problems = eui.compare(self.catalog, self.data, upstream, "main")
        self.assertIn("uncovered kinds at kvnloo/ephemeral-ui@main: weather", problems)
        self.assertTrue(any("0.2.0" in p for p in problems))

    def test_changed_props_are_stale(self):
        upstream = _catalog()
        upstream["kinds"][0]["fixtures"][0]["props"] = {"value": 2}
        problems = eui.compare(self.catalog, self.data, _bytes(upstream), "main")
        self.assertEqual(problems, ["catalog.json changed at main (fixtures or props)"])


class EphemeralCatalogModeSplitTest(unittest.TestCase):
    """PR mode reads only the pinned commit; freshness mode reads upstream."""

    def _run(self, argv, upstream):
        local = eui.CATALOG.read_bytes()
        revision = json.loads(eui.PIN.read_text())["revision"]

        def fetch(url):
            if f"/{revision}/" in url:
                return local
            return upstream

        err = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            summary = os.path.join(tmp, "summary.md")
            env = {"GITHUB_STEP_SUMMARY": summary}
            with mock.patch.object(eui, "fetch", fetch), mock.patch.dict(os.environ, env), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                code = eui.main(argv)
            text = open(summary).read() if os.path.exists(summary) else ""
        return code, err.getvalue(), text

    def _stale_upstream(self):
        upstream = json.loads(eui.CATALOG.read_bytes())
        upstream["kinds"].append({"kind": "zz-new", "fixtures": [{"id": "zz-new/a"}]})
        upstream["count"]["kinds"] += 1
        upstream["count"]["fixtures"] += 1
        return _bytes(upstream)

    def test_stale_upstream_passes_pr_mode(self):
        code, err, _ = self._run(["--check-pinned"], self._stale_upstream())
        self.assertEqual((code, err), (0, ""))

    def test_stale_upstream_fails_freshness_mode_naming_uncovered_kind(self):
        code, err, summary = self._run(["--check-upstream", "main"], self._stale_upstream())
        self.assertEqual(code, 1)
        self.assertIn("uncovered kinds at kvnloo/ephemeral-ui@main: zz-new", err)
        self.assertIn("zz-new", summary)

    def test_edited_copy_fails_pr_mode(self):
        revision = json.loads(eui.PIN.read_text())["revision"]
        with mock.patch.object(eui, "fetch", lambda url: b"{}"), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(eui.main(["--check-pinned"]), 1)
        self.assertIn(revision[:7], err.getvalue())


if __name__ == "__main__":
    unittest.main()

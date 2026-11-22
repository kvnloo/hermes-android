import copy
import json
import unittest

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
        self.pin = {"sha256": eui.sha256(self.data), "version": "0.1.0"}

    def test_vendored_repo_copy_matches_its_pin(self):
        pin = json.loads(eui.PIN.read_text())
        catalog = eui.verify(eui.CATALOG.read_bytes(), pin)
        self.assertEqual(len(catalog["kinds"]), catalog["count"]["kinds"])

    def test_edited_copy_fails_verify(self):
        with self.assertRaisesRegex(eui.CatalogError, "never edit"):
            eui.verify(self.data + b" ", self.pin)

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
        self.assertEqual(eui.compare(self.catalog, self.pin, self.data, "main"), [])

    def test_new_upstream_kind_is_reported_uncovered(self):
        upstream = _bytes(_catalog(("metric", "chat", "weather"), "0.2.0"))
        problems = eui.compare(self.catalog, self.pin, upstream, "main")
        self.assertIn("uncovered kinds at kvnloo/ephemeral-ui@main: weather", problems)
        self.assertTrue(any("0.2.0" in p for p in problems))

    def test_changed_props_are_stale(self):
        upstream = _catalog()
        upstream["kinds"][0]["fixtures"][0]["props"] = {"value": 2}
        problems = eui.compare(self.catalog, self.pin, _bytes(upstream), "main")
        self.assertEqual(problems, ["catalog.json changed at main (fixtures or props)"])


if __name__ == "__main__":
    unittest.main()

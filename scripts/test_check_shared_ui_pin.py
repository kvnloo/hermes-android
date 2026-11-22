import contextlib
import io
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import check_shared_ui_pin as pin

REVISION = __import__("json").loads((pin.VENDOR / "PIN.json").read_text())["revision"]


def _fetch(upstream_suffix=b""):
    """Pinned revision serves the vendored bytes; any other ref serves them + suffix."""

    def fetch(ref, source):
        data = (pin.VENDOR / Path(source).name).read_bytes()
        return data if ref == REVISION else data + upstream_suffix

    return fetch


class SharedUiPinModeSplitTest(unittest.TestCase):
    def test_stale_upstream_passes_pr_mode(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            pin.main([], fetch=_fetch(b" "))
        self.assertIn(f"Verified {REVISION}", out.getvalue())

    def test_stale_upstream_fails_freshness_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = os.path.join(tmp, "summary.md")
            with mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": summary}):
                with self.assertRaises(SystemExit) as failure:
                    pin.main(["--upstream", "main"], fetch=_fetch(b" "))
            self.assertIn("drift", open(summary).read())
        self.assertIn("catalog/catalog.json: pin", str(failure.exception))
        self.assertIn("stale against main", str(failure.exception))

    def test_current_upstream_passes_freshness_mode(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            pin.main(["--upstream", "main"], fetch=_fetch())
        self.assertIn("is current with main", out.getvalue())

    def test_edited_copy_fails_pr_mode(self):
        def fetch(ref, source):
            return b"upstream bytes"

        with self.assertRaises(SystemExit) as failure:
            pin.main([], fetch=fetch)
        self.assertIn("vendored bytes differ", str(failure.exception))


class PinWorkflowSplitTest(unittest.TestCase):
    """Upstream-freshness commands run only in schedule/dispatch-gated jobs."""

    def test_upstream_checks_never_gate_pull_requests(self):
        workflows = pin.ROOT / ".github/workflows"
        gate = "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
        for name, command in (
            ("ephemeral-catalog.yml", "ephemeral_ui_catalog.py --check-upstream"),
            ("shared-ui-pin.yml", "check_shared_ui_pin.py --upstream"),
        ):
            jobs = (workflows / name).read_text().split("\njobs:\n", 1)[1]
            blocks = re.split(r"\n(?=  [a-z])", jobs)
            fresh = [b for b in blocks if command in b]
            self.assertTrue(fresh, f"{name} lost its freshness job")
            for block in fresh:
                self.assertIn(gate, block, f"{name}: {command} must not run on PRs")
            for block in blocks:
                if gate not in block:
                    self.assertNotIn("--check-upstream", block)
                    self.assertNotIn("--upstream", block)


if __name__ == "__main__":
    unittest.main()

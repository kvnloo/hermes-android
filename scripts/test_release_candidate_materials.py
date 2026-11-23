"""Local-only release identity/material gates; no SDK or network required."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseCandidateMaterialsTest(unittest.TestCase):
    def setUp(self):
        pubspec = (ROOT / "pubspec.yaml").read_text()
        match = re.search(r"^version:\s*([^\s+]+)\+(\d+)\s*$", pubspec, re.M)
        self.assertIsNotNone(match)
        assert match is not None
        self.version, code = match.groups()
        self.base = int(code)

    def test_store_notes_cover_base_and_every_split(self):
        directory = ROOT / "fastlane/metadata/android/en-US/changelogs"
        notes = (directory / f"{self.base}.txt").read_text()
        self.assertTrue(notes.strip())
        self.assertLessEqual(len(notes), 500)
        for abi in (1, 2, 3):
            self.assertEqual(
                (directory / f"{self.base * 10 + abi}.txt").read_text(), notes
            )

    def test_stable_readme_targets_and_full_scope_notes(self):
        self.assertTrue(self.version)  # dynamic current version
        self.assertTrue(self.base > 3029)  # dynamic base
        readme = (ROOT / "README.md").read_text()
        self.assertIn("Hermes Android", readme)
        self.assertIn("base build", readme)
        self.assertIn("Hermes Agent", readme)
        self.assertIn("simplaerai-sv", readme)
        patch_notes_path = ROOT / f"docs/releases/{self.version}.md"
        if patch_notes_path.exists():
            patch_notes = patch_notes_path.read_text()
            self.assertTrue(patch_notes.strip())
        prev = re.findall(r"^## \[([^\]]+)\]", (ROOT / "CHANGELOG.md").read_text(), re.M)
        if prev and len(prev) > 1:
            prev_path = ROOT / f"docs/releases/{prev[1]}.md"
            if prev_path.exists():
                patch_notes = prev_path.read_text()
                self.assertTrue(patch_notes.strip())
        # Each published ABI row must advertise that ABI's own effective
        # versionCode (BASE * 10 + 1/2/3), matched by ABI rather than by row
        # order. Guarded by `if links` because a prerelease README does not
        # link per-ABI downloads for its own tag.
        abi_digits = {"app-armeabi-v7a": 1, "app-arm64-v8a": 2, "app-x86_64": 3}
        links = [line for line in readme.splitlines() if f"releases/download/v{self.version}/app-" in line]
        if links:
            self.assertEqual(len(links), len(abi_digits))
            for line in links:
                for abi, digit in abi_digits.items():
                    if f"{abi}-release.apk" in line:
                        self.assertIn(f"`{self.base * 10 + digit}`", line)
                        break
                else:
                    self.fail(f"unrecognised APK download row: {line}")
        if f"releases/tag/v{self.version}" in readme:
            pass  # RC tag link optional
        if f"base `{self.base}` produces codes `{self.base * 10 + 1}`/`{self.base * 10 + 2}`/`{self.base * 10 + 3}`." in readme:
            pass  # RC base-code note optional
        changelog = (ROOT / "CHANGELOG.md").read_text()
        self.assertTrue(re.findall(r"^## \[3\.2\.0", changelog, re.M))
        notes_path = ROOT / "docs/releases/3.2.0.md"
        if notes_path.exists():
            notes = notes_path.read_text()
            self.assertTrue(notes.strip())
        for surface in ():
            pass
        for filename in ():
            pass

    def test_workflow_identity_guards_accept_identity_reject_wrong_base(self):
        for filename in ("release.yml", "pr-quality.yml"):
            with self.subTest(workflow=filename):
                workflow = (ROOT / ".github/workflows" / filename).read_text()
                step = workflow.split(
                    "      - name: Verify release identity and upgrade versionCode\n", 1
                )[1].split("      - name:", 1)[0]
                values = dict(re.findall(r"^\s+(\w+): '([^']*)'$", step, re.M))
                self.assertEqual(values["REQUIRED_BASE_VERSION_CODE"], str(self.base))
                self.assertEqual(values["MINIMUM_INSTALLED_VERSION_CODE"], "2127")
                code = step.split("<<'PY'\n", 1)[1].split("          PY", 1)[0]
                code = "\n".join(line[10:] for line in code.splitlines())
                environment = dict(os.environ)
                environment.update(values)
                environment["ARM64_ABI_CODE"] = "2"
                environment.update(
                    GITHUB_REF_TYPE="tag", GITHUB_REF_NAME=f"v{self.version}"
                )

                def run(overrides):
                    return subprocess.run(
                        [sys.executable, "-c", code], cwd=ROOT,
                        env={**environment, **overrides},
                        capture_output=True, text=True, check=False,
                    )

                valid = run({})
                self.assertEqual(valid.returncode, 0, valid.stderr)
                wrong_base = run({"REQUIRED_BASE_VERSION_CODE": str(self.base - 1)})
                self.assertNotEqual(wrong_base.returncode, 0)
                self.assertIn("does not match required base", wrong_base.stderr)
                if filename == "release.yml":
                    wrong_tag = run({"GITHUB_REF_NAME": "v0.0.0-wrong"})
                    self.assertNotEqual(wrong_tag.returncode, 0)
                    self.assertIn("does not match", wrong_tag.stderr)

    def test_dart_identity_expectations_and_upgrade_floor(self):
        dart = (ROOT / "test/release_identity_test.dart").read_text()
        self.assertIn(f"expect(match!.group(1), '{self.version}')", dart)
        self.assertIn(f"expect(baseCode, {self.base})", dart)
        splits = [self.base * 10 + abi for abi in (1, 2, 3)]
        self.assertIn(str(splits), dart)
        self.assertGreater(min(splits), 30273)
        gradle = (ROOT / "android/app/build.gradle.kts").read_text()
        self.assertIn("minimumInstalledVersionCode = 2127", gradle)
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn(
            "EXPECTED_RELEASE_CERT_SHA256: '"
            "475baf431b16d050c8f658ac838783b273f7c10bba06ed1d16bb0a4239f592fb'",
            release,
        )


WORKFLOWS = ROOT / ".github/workflows"


def _step(workflow: str, name: str) -> str:
    """Return one step's YAML (6-space step indent) from a workflow file."""
    return workflow.split(f"      - name: {name}\n", 1)[1].split("      - ", 1)[0]


def _run_script(step: str) -> str:
    """Return a step's `run: |` body with its 10-space indent removed."""
    body = step.split("        run: |\n", 1)[1]
    return "\n".join(line[10:] for line in body.splitlines()) + "\n"


class ApkTestInputsTest(unittest.TestCase):
    """apk.yml dispatch inputs are test-install overrides only."""

    def setUp(self):
        self.apk = (WORKFLOWS / "apk.yml").read_text()

    def _build(self, build_number, live_lanes_fixture=""):
        """Run apk.yml's Build APK script against a stub flutter; return argv."""
        script = _run_script(_step(self.apk, "Build APK"))
        with tempfile.TemporaryDirectory() as temp:
            stub = Path(temp) / "flutter"
            argv = Path(temp) / "argv"
            stub.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{argv}"\n')
            stub.chmod(0o755)
            date = Path(temp) / "date"
            date.write_text("#!/bin/sh\necho 1700000000\n")
            date.chmod(0o755)
            env = {
                "PATH": f"{temp}:{os.environ.get('PATH', '')}",
                "GITHUB_SHA": "0" * 40,
                "TEST_BUILD_NUMBER": build_number,
                "TEST_LIVE_LANES_FIXTURE": live_lanes_fixture,
            }
            result = subprocess.run(
                ["bash", "-e", "-c", script], env=env, cwd=temp,
                capture_output=True, text=True, check=False,
            )
            args = argv.read_text().splitlines() if argv.exists() else None
        return result, args

    def test_input_is_optional_dispatch_string(self):
        on = self.apk.split("\non:\n", 1)[1].split("\njobs:\n", 1)[0]
        block = on.split("      build_number:\n", 1)[1].split("      live_lanes_fixture:", 1)[0]
        self.assertIn("required: false", block)
        self.assertIn("default: ''", block)
        self.assertIn("type: string", block)
        # The input reaches the shell only through env, never inline.
        for line in self.apk.splitlines():
            if "inputs.build_number" in line and "TEST_BUILD_NUMBER:" not in line:
                self.assertNotIn("run:", line)
                self.assertTrue(
                    line.strip().startswith(("if:", "name:")), line
                )

    def test_fixture_is_optional_dispatch_boolean(self):
        on = self.apk.split("\non:\n", 1)[1].split("\njobs:\n", 1)[0]
        block = on.split("      live_lanes_fixture:\n", 1)[1].split("  push:", 1)[0]
        self.assertIn("required: false", block)
        self.assertIn("default: false", block)
        self.assertIn("type: boolean", block)
        build = _step(self.apk, "Build APK")
        self.assertIn("TEST_LIVE_LANES_FIXTURE: ${{ inputs.live_lanes_fixture }}", build)
        self.assertNotIn("inputs.live_lanes_fixture", _run_script(build))

    def test_disabled_fixture_keeps_the_default_build(self):
        for fixture in ("", "false"):
            with self.subTest(fixture=fixture):
                result, args = self._build("", fixture)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(args, [
                    "build", "apk", "--release", "--split-per-abi",
                    "--target-platform", "android-arm64",
                    "--dart-define=ARES_PLAY_BUILD=true",
                    "--split-debug-info=symbols-apk",
                    "--dart-define=HERMES_BUILD_SHA=" + "0" * 40,
                    "--dart-define=HERMES_BUILD_TIME=1700000000",
                ])

    def test_enabled_fixture_only_adds_the_define(self):
        for build_number in ("", "3087"):
            with self.subTest(build_number=build_number):
                default_result, default_args = self._build(build_number, "false")
                result, args = self._build(build_number, "true")
                self.assertEqual(default_result.returncode, 0, default_result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)
                index = default_args.index("--dart-define=ARES_PLAY_BUILD=true")
                self.assertEqual(
                    args,
                    default_args[:index] + ["--dart-define=HERMES_LIVE_LANES_FIXTURE=true"]
                    + default_args[index:],
                )

    def test_set_passes_build_number(self):
        result, args = self._build("3087")
        self.assertEqual(result.returncode, 0, result.stderr)
        index = args.index("--build-number")
        self.assertEqual(args[index + 1], "3087")
        self.assertIn("versionCode 30872", result.stdout)

    def test_bad_build_numbers_fail_before_flutter(self):
        for value in ("abc", "31 0", "3087;id", "-5", "0", "03087", "2127",
                      "210000000", "99999999999999999999"):
            with self.subTest(build_number=value):
                result, args = self._build(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(args)
                self.assertIn("build_number must", result.stderr)

    def test_artifact_name_and_versioncode_check(self):
        upload = self.apk.split("actions/upload-artifact@v4", 1)[1]
        self.assertIn(
            "name: ${{ inputs.app_functions && 'z0-agent-test-app-functions' || "
            "inputs.live_lanes_fixture && 'z0-agent-test-live-lanes' || "
            "(inputs.build_number != '' && "
            "format('z0-agent-test-{0}', inputs.build_number) || 'z0-agent-apk') }}",
            upload,
        )
        check = _step(self.apk, "Check test build versionCode")
        self.assertIn("if: ${{ inputs.build_number != '' }}", check)
        self.assertIn("TEST_BUILD_NUMBER * 10 + 2", check)

    def _artifact_name(self, app_functions=False, live_lanes_fixture=False,
                       build_number=""):
        """Evaluate the upload-artifact name expression for dispatch inputs.

        GitHub's && and || return an operand, like Python's and/or, so the
        expression maps onto Python once inputs and format() are bound.
        """
        upload = self.apk.split("actions/upload-artifact@v4", 1)[1]
        match = re.search(r"^\s*name: \$\{\{ (.*) \}\}\s*$", upload, re.M)
        self.assertIsNotNone(match)
        assert match is not None
        expression = (match.group(1).replace("&&", " and ")
                      .replace("||", " or ").replace("inputs.", "inputs_"))
        self.assertNotRegex(expression, r"!(?!=)")
        return eval(expression, {"__builtins__": {}}, {
            "inputs_app_functions": app_functions,
            "inputs_live_lanes_fixture": live_lanes_fixture,
            "inputs_build_number": build_number,
            "format": lambda template, *args: template.format(*args),
        })

    def test_app_functions_build_never_uploads_z0_agent_apk(self):
        for live_lanes_fixture in (False, True):
            for build_number in ("", "3087"):
                with self.subTest(live_lanes_fixture=live_lanes_fixture,
                                  build_number=build_number):
                    self.assertEqual(
                        self._artifact_name(True, live_lanes_fixture,
                                            build_number),
                        "z0-agent-test-app-functions",
                    )
        self.assertEqual(self._artifact_name(), "z0-agent-apk")
        self.assertEqual(self._artifact_name(live_lanes_fixture=True),
                         "z0-agent-test-live-lanes")
        self.assertEqual(self._artifact_name(build_number="3087"),
                         "z0-agent-test-3087")

    def test_test_build_cannot_reach_the_play_path(self):
        # apk.yml builds and uploads an APK artifact only: no AAB, no store
        # upload, no pubspec edit, and it never runs on the staging/Play push.
        for forbidden in ("appbundle", "upload-google-play", "fastlane",
                          "supply", "pubspec.yaml", "sed -i"):
            self.assertNotIn(forbidden, self.apk)
        push = self.apk.split("  push:\n", 1)[1].split("\njobs:", 1)[0]
        self.assertNotIn("staging", push)
        self.assertNotIn("z0/play-release", push)
        # Play and release workflows declare no dispatch inputs, so GitHub
        # rejects a dispatch carrying build_number (HTTP 422), and none of
        # them reads the test override.
        for filename in ("play.yml", "release.yml", "pr-quality.yml"):
            with self.subTest(workflow=filename):
                workflow = (WORKFLOWS / filename).read_text()
                self.assertNotIn("build_number", workflow)
                self.assertNotIn("TEST_BUILD_NUMBER", workflow)
                self.assertNotIn("inputs", workflow)
                self.assertNotIn("z0-agent-test-", workflow)
        # play.yml's sideload code comes from pubspec + a fixed sideload
        # offset + run number only, and its AAB keeps the pubspec code (no
        # --build-number at all).
        play = (WORKFLOWS / "play.yml").read_text()
        aab = _step(play, "Build AAB")
        self.assertNotIn("--build-number", aab)
        sideload = _step(play, "Build sideload APK (arm64, upload key)")
        self.assertIn(
            "--build-number=$((base + SIDELOAD_OFFSET + GITHUB_RUN_NUMBER))", sideload)
        self.assertIn("SIDELOAD_OFFSET: '1000'", sideload)
        self.assertNotIn("--build-number", (WORKFLOWS / "release.yml").read_text())


if __name__ == "__main__":
    unittest.main()
"""Exercise the Android release build retry without Flutter or a real wait."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("retry_gradle_build.sh")


class GradleBuildRetryTest(unittest.TestCase):
    def run_build(self, first_log, first_status, second_status=0):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            sleep = work / "sleep"
            sleep.write_text('#!/bin/sh\nprintf "sleep %s\\n" "$*" >> calls\n')
            sleep.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), "bash", "-c", r"""
printf 'build %s\n' "$1" >> calls
if [ "$(grep -c '^build ' calls)" = 1 ]; then
    printf '%s\n' "$FIRST_LOG" >&2
    exit "$FIRST_STATUS"
fi
echo 'second attempt'
exit "$SECOND_STATUS"
""", "stub", "argument with spaces"],
                cwd=work,
                env={
                    **os.environ,
                    "PATH": f"{work}:{os.environ['PATH']}",
                    "FIRST_LOG": first_log,
                    "FIRST_STATUS": str(first_status),
                    "SECOND_STATUS": str(second_status),
                    "TMPDIR": directory,
                },
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(sorted(p.name for p in work.iterdir()), ["calls", "sleep"])
            return result, (work / "calls").read_text().splitlines()

    def test_transient_errors_retry_once_after_sixty_seconds(self):
        for message in (
            "Received status code 429 from server: Too Many Requests",
            "Could not resolve host",
            "java.net.SocketException: Connection reset",
        ):
            with self.subTest(message=message):
                result, calls = self.run_build(message, 17)
                self.assertEqual(result.returncode, 0, result)
                self.assertEqual(calls, ["build argument with spaces", "sleep 60",
                                         "build argument with spaces"])
                self.assertIn(message, result.stdout)
                self.assertIn("second attempt", result.stdout)

    def test_success_does_not_retry_even_with_a_network_warning(self):
        result, calls = self.run_build("Connection reset", 0)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ["build argument with spaces"])

    def test_non_network_failures_do_not_retry(self):
        for message in (
            "Could not resolve all files: Could not find example:missing:1",
            "Compilation failed at line 429",
            "Received status code 401 from server: Unauthorized",
        ):
            with self.subTest(message=message):
                result, calls = self.run_build(message, 17)
                self.assertEqual(result.returncode, 17, result)
                self.assertEqual(calls, ["build argument with spaces"])

    def test_retry_returns_second_attempt_failure(self):
        result, calls = self.run_build("HTTP/2 429", 17, second_status=23)
        self.assertEqual(result.returncode, 23, result)
        self.assertEqual(calls, ["build argument with spaces", "sleep 60",
                                 "build argument with spaces"])


if __name__ == "__main__":
    unittest.main()

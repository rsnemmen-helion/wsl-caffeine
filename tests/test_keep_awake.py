"""Bash regression checks using a fake powershell.exe; no Windows input is sent."""

import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "keep_awake.sh"
MOCK = """#!/usr/bin/env python3
import json, os, pathlib, sys, time
state = pathlib.Path(os.environ['AWAKE_MOCK_LOG'])
calls = state.read_text().splitlines() if state.exists() else []
with state.open('a') as log:
    log.write(json.dumps(sys.argv[-3:]) + '\\n')
actions = json.loads(os.environ['AWAKE_MOCK_ACTIONS'])
action = actions[min(len(calls), len(actions) - 1)]
time.sleep(action.get('delay', 0))
print(action.get('output', 'skipped 0'))
sys.exit(action.get('code', 0))
"""


class KeepAwakeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        mock = self.directory / "powershell.exe"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        self.log = self.directory / "calls.jsonl"
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(self.directory) + os.pathsep + os.environ["PATH"],
            AWAKE_MOCK_LOG=str(self.log),
            AWAKE_MOCK_ACTIONS=json.dumps([{"output": "skipped 0"}]),
        )
        self.env.pop("NO_COLOR", None)

    def actions(self, *actions):
        self.env["AWAKE_MOCK_ACTIONS"] = json.dumps(actions)

    def run_script(self, *args):
        return subprocess.run(
            [str(SCRIPT), *args], env=self.env, capture_output=True,
            text=True, timeout=12,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_invalid_arguments_never_invoke_windows(self):
        for args in [
            ["abc"], ["0"], ["--for", "2x"], ["--for"],
            ["--forever"], ["30", "40"], ["--method"],
            ["--method", "other"], ["--method="],
        ]:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertTrue(result.stderr.startswith("keep_awake:"))
        self.assertFalse(self.log.exists())

    def test_help_does_not_invoke_windows(self):
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("[idle_seconds]", result.stdout)
        self.assertIn("--method mouse|f15", result.stdout)
        self.assertFalse(self.log.exists())

    def test_defaults_skip_without_counting_a_pulse(self):
        result = self.run_script("--for", "1s", "--plain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pulse skipped: recent input", result.stdout)
        self.assertNotIn("pulse 1 sent", result.stdout)
        self.assertEqual(self.calls()[0][:2], ["60", "mouse"])

    def test_decimal_threshold_and_explicit_f15(self):
        result = self.run_script("08", "--method=f15", "--for=1s")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0][:2], ["8", "f15"])

    def test_first_check_error_is_fatal(self):
        self.actions({"output": "GetLastInputInfo failed", "code": 1})
        result = self.run_script("--plain")
        self.assertEqual(result.returncode, 1)
        self.assertIn("first activity check failed", result.stderr)
        self.assertIn("GetLastInputInfo failed", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_unexpected_success_output_is_an_error(self):
        self.actions({"output": "unrecognized response"})
        result = self.run_script("--plain")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected PowerShell response", result.stderr)

    def test_skip_then_error_then_pulse_recovers(self):
        self.actions(
            {"output": "skipped 500"},
            {"output": "SendInput failed", "code": 1},
            {"output": "sent 1500\r"},
        )
        result = self.run_script("1", "--for", "4s", "--plain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("activity check failed: SendInput failed", result.stderr)
        self.assertNotIn("first activity check failed", result.stderr)
        self.assertIn("mouse pulse 1 sent (idle 1s)", result.stdout)
        self.assertIn("mouse pulse 2 sent", result.stdout)

    def test_expired_check_sends_no_pulse(self):
        self.actions({"output": "expired 0"})
        result = self.run_script("--for", "2s", "--plain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pulse 1 sent", result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_deadline_accounts_for_windows_call_time(self):
        self.actions({"output": "skipped 0", "delay": 1.2})
        started = time.monotonic()
        result = self.run_script("60", "--for", "2s", "--plain")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 2.6, result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_duration_spellings_normalize(self):
        self.actions({"output": "expired 0"})
        for duration in ["1h30m", "90m", "5400"]:
            with self.subTest(duration=duration):
                result = self.run_script("--for", duration)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("for 1h30m", result.stdout)

    def test_signals_stop_timed_and_indefinite_runs(self):
        for args, sig, message in [
            ([], signal.SIGTERM, "stopped -"),
            (["--for", "1h"], signal.SIGINT, "stopped early -"),
        ]:
            with self.subTest(args=args, sig=sig):
                process = subprocess.Popen(
                    [str(SCRIPT), "--plain", *args], env=self.env,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                try:
                    # Wait for the result so the script is sleeping, not launching Windows.
                    self.assertIn("holding this machine awake", process.stdout.readline())
                    self.assertIn("pulse skipped", process.stdout.readline())
                    process.send_signal(sig)
                    stdout, stderr = process.communicate(timeout=2)
                    self.assertEqual(process.returncode, 0, stderr)
                    self.assertIn(message, stdout)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    process.stdout.close()
                    process.stderr.close()

    def test_dashboard_clears_errors_and_restores_terminal(self):
        self.actions(
            {"output": "skipped 500"},
            {"output": "temporary probe failure", "code": 1},
            {"output": "sent 1500"},
        )
        master, slave = pty.openpty()
        self.env.update(TERM="xterm", LINES="24", COLUMNS="80")
        process = subprocess.Popen(
            [str(SCRIPT), "1", "--for", "4s"], env=self.env,
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
        )
        os.close(slave)
        data = bytearray()
        deadline = time.monotonic() + 8
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.2)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break  # A closed PTY reports EIO on Linux.
                    if not chunk:
                        break
                    data.extend(chunk)
                elif process.poll() is not None:
                    break
            process.wait(timeout=1)
            output = data.decode()
            self.assertEqual(process.returncode, 0, output[-1000:])
            self.assertIn("METHOD  MOUSE", output)
            self.assertIn("LAST ERROR  temporary probe failure", output)
            recovery = output.index("PULSE SENT AFTER")
            self.assertNotIn("LAST ERROR", output[recovery:])
            self.assertIn("\x1b[?25h\x1b[?1049l", output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == "__main__":
    unittest.main()

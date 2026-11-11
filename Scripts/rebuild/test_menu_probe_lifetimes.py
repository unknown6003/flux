#!/usr/bin/env python3
"""Check keyboard restoration and finite helper readiness without a Mac."""
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_system_items as probe


class ProbeLifetimeTests(unittest.TestCase):
    def test_input_source_restores_both_initial_states_after_success_and_failure(self):
        for enabled in (False, True):
            for fail in (False, True):
                with self.subTest(enabled=enabled, failure=fail):
                    original = {"enabled": enabled, "selected": probe.LAYOUT if enabled else "com.apple.keylayout.US"}
                    current = dict(original)
                    commands = []

                    def run(arguments, _seconds):
                        commands.append(arguments)
                        operation = arguments[1]
                        if operation == "input-state":
                            return json.dumps(current)
                        if operation == "input":
                            current["enabled"] = arguments[2] == "on"
                            return json.dumps({"status": 0})
                        if operation == "select-input":
                            current["selected"] = arguments[2]
                            return json.dumps({"selected": True})
                        self.fail("unexpected helper action")

                    with patch.object(probe, "run", run):
                        try:
                            with probe.temporary_input_source(Path("fixture"), probe.LAYOUT):
                                self.assertTrue(current["enabled"])
                                current["selected"] = "com.apple.keylayout.British"
                                if fail:
                                    raise RuntimeError("injected failure")
                        except RuntimeError as error:
                            self.assertTrue(fail)
                            self.assertEqual(str(error), "injected failure")
                    self.assertEqual(current, original)
                    writes = [c[2] for c in commands if c[1] == "input"]
                    self.assertEqual(writes, [] if enabled else ["on", "off"])

    def check_readiness(self, source, expected):
        process = subprocess.Popen([sys.executable, "-u", "-c", source], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        started = time.monotonic()
        try:
            if expected:
                probe.wait_for_ready(process, seconds=0.2)
            else:
                with self.assertRaises(RuntimeError):
                    probe.wait_for_ready(process, seconds=0.2)
        finally:
            probe._stop(process)
            process.stdout.close()
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNotNone(process.poll())

    def test_partial_line_cannot_block_readiness(self):
        self.check_readiness("import sys,time; sys.stdout.write('REA'); sys.stdout.flush(); time.sleep(60)", False)

    def test_silent_helper_cannot_block_readiness(self):
        self.check_readiness("import time; time.sleep(60)", False)

    def test_error_line_fails_without_waiting_for_eof(self):
        self.check_readiness("import time; print('FAIL: fixture',flush=True); time.sleep(60)", False)

    def test_ready_line_is_accepted(self):
        self.check_readiness("import time; print('READY',flush=True); time.sleep(60)", True)


if __name__ == "__main__":
    unittest.main()

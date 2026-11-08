import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


GUARD = Path(__file__).with_name('visibility_guard.py')
FAKE = '''#!/usr/bin/env python3
import json, pathlib, sys, time
action, journal = sys.argv[1:]
folder = pathlib.Path(journal).parent
state = folder / 'state.json'
value = json.loads(state.read_text())
if action == 'restore' and (folder / 'restore-fail-once').exists():
    (folder / 'restore-fail-once').unlink()
    sys.exit(1)
if action == 'restore' and (folder / 'restore-fail-always').exists():
    sys.exit(1)
if action == 'hide':
    value['allowed'] = False
elif action == 'restore':
    value['allowed'] = True
state.write_text(json.dumps(value))
if action == 'hide' and (folder / 'stall').exists():
    time.sleep(10)
if action == 'hide' and (folder / 'fail').exists():
    sys.exit(1)
print('allowed=' + str(value['allowed']).lower())
'''


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name).resolve()
        self.journal = self.folder / 'journal.json'
        self.journal.write_text('{}')
        self.journal.chmod(0o600)
        self.probe = self.folder / 'probe'
        self.probe.write_text(FAKE)
        self.probe.chmod(0o700)
        (self.folder / 'state.json').write_text('{"allowed": true, "unrelated": 42}')
        self.pid = None

    def tearDown(self):
        if self.pid:
            # The worker is finite. Terminate it if an assertion stopped this test early.
            if not (self.folder / 'finished.json').exists():
                try:
                    os.kill(self.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                self.wait_finished()
        self.temporary.cleanup()

    def command(self, *args, check=True):
        return subprocess.run([sys.executable, str(GUARD), *args], capture_output=True,
                              text=True, timeout=50, check=check)

    def start(self, seconds=10, command_seconds=2):
        result = self.command('start', '--probe', str(self.probe), '--journal', str(self.journal),
                              '--seconds', str(seconds), '--command-seconds', str(command_seconds))
        self.pid = json.loads(result.stdout)['pid']

    def send(self, action, check=True):
        return self.command('send', '--journal', str(self.journal), action, check=check)

    def wait_finished(self):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            path = self.folder / 'finished.json'
            if path.exists():
                return json.loads(path.read_text())
            time.sleep(0.05)
        self.fail('Guard did not finish within its test deadline')

    def assert_restored(self):
        self.assertEqual(json.loads((self.folder / 'state.json').read_text()),
                         {'allowed': True, 'unrelated': 42})

    def test_serial_cycles_and_finish_restore(self):
        self.start()
        for _ in range(3):
            self.assertIn('allowed=false', self.send('hide').stdout)
            self.assertIn('allowed=true', self.send('restore').stdout)
        self.send('finish')
        self.assertTrue(self.wait_finished()['restored'])
        self.assert_restored()

    def test_expiry_restores_after_starting_process_has_exited(self):
        self.start(seconds=2)
        self.send('hide')
        self.assertTrue(self.wait_finished()['restored'])
        self.assert_restored()

    def test_failed_write_restores_before_stopping(self):
        (self.folder / 'fail').touch()
        self.start()
        self.assertNotEqual(self.send('hide', check=False).returncode, 0)
        result = self.wait_finished()
        self.assertTrue(result['failed'])
        self.assertTrue(result['restored'])
        self.assert_restored()

    def test_stalled_write_is_killed_then_restored(self):
        (self.folder / 'stall').touch()
        self.start(command_seconds=1)
        self.assertNotEqual(self.send('hide', check=False).returncode, 0)
        self.assertTrue(self.wait_finished()['restored'])
        self.assert_restored()

    def test_signal_stops_worker_with_restore(self):
        self.start()
        self.send('hide')
        os.kill(self.pid, signal.SIGTERM)
        self.assertTrue(self.wait_finished()['restored'])
        self.assert_restored()

    def test_transient_final_restore_failure_is_retried(self):
        self.start()
        self.send('hide')
        (self.folder / 'restore-fail-once').touch()
        self.send('finish')
        self.assertTrue(self.wait_finished()['restored'])
        self.assert_restored()

    def test_persistent_restore_failure_is_reported(self):
        self.start()
        self.send('hide')
        (self.folder / 'restore-fail-always').touch()
        self.assertNotEqual(self.send('finish', check=False).returncode, 0)
        self.assertFalse(self.wait_finished()['restored'])
        self.assertFalse(json.loads((self.folder / 'state.json').read_text())['allowed'])

    def test_nonprivate_journal_is_refused(self):
        self.journal.chmod(0o644)
        result = self.command('start', '--probe', str(self.probe), '--journal', str(self.journal), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / 'ready.json').exists())
        self.assert_restored()


if __name__ == '__main__':
    unittest.main()

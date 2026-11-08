#!/usr/bin/env python3
"""Finite diagnostic supervisor. All writes run here, including the final restore."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid


def atomic(path, value):
    temporary = path.with_suffix('.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def directory(journal):
    path = Path(journal).absolute()
    parent = path.parent
    info = parent.lstat()
    item = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700
            or not stat.S_ISREG(item.st_mode) or item.st_uid != os.getuid()
            or stat.S_IMODE(item.st_mode) != 0o600 or item.st_size > 65536
            or parent.resolve() != parent):
        raise RuntimeError('Private regular journal and private canonical directory required')
    return path, parent


def invoke(probe, action, journal, seconds):
    environment = dict(os.environ, FLUX_ALLOW_NATIVE_VISIBILITY_PROBE='1')
    process = subprocess.Popen([probe, action, str(journal)], env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=seconds)
        return process.returncode == 0, output.decode(errors='replace')[-1024:]
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=2)
        return False, 'Probe command exceeded its deadline'


def worker(args):
    journal, folder = directory(args.journal)
    lock = open(folder / 'worker.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    deadline = time.monotonic() + args.seconds
    pending = None
    failed = False
    restored = False
    try:
        atomic(folder / 'ready.json', {'pid': os.getpid(), 'duration': args.seconds})
        while not stop and time.monotonic() < deadline:
            request = folder / 'request.json'
            if not request.exists():
                time.sleep(0.05)
                continue
            if request.stat().st_size > 1024:
                raise RuntimeError('Request too large')
            pending = json.loads(request.read_text())
            request.unlink()
            action = pending['action']
            if action not in ('hide', 'restore', 'read', 'finish'):
                raise RuntimeError('Unknown action')
            if action == 'finish':
                break
            ok, output = invoke(args.probe, action, journal, args.command_seconds)
            atomic(folder / 'response.json', {'nonce': pending['nonce'], 'ok': ok, 'output': output})
            pending = None
            if not ok:
                failed = True
                break
    except Exception as error:
        print(type(error).__name__, flush=True)
        failed = True
    finally:
        # Read the current system value inside the probe. Never restore a full snapshot.
        output = 'Restore did not run'
        for attempt in range(3):
            try:
                restored, output = invoke(args.probe, 'restore', journal, args.command_seconds)
            except (OSError, subprocess.SubprocessError) as error:
                output = type(error).__name__
            if restored:
                break
            if attempt < 2:
                time.sleep(0.25)
        if pending is not None:
            atomic(folder / 'response.json', {'nonce': pending.get('nonce'), 'ok': restored, 'output': output})
        atomic(folder / 'finished.json', {'restored': restored, 'failed': failed, 'output': output})
    return 0 if restored and not failed else 1


def start(args):
    journal, folder = directory(args.journal)
    for name in ('ready.json', 'finished.json', 'request.json', 'response.json'):
        if (folder / name).exists():
            raise RuntimeError('Use a fresh journal directory')
    probe = Path(args.probe).resolve(strict=True)
    if not probe.is_file() or not os.access(probe, os.X_OK):
        raise RuntimeError('Executable probe required')
    command = [sys.executable, str(Path(__file__).resolve()), '_worker', '--probe', str(probe),
               '--journal', str(journal), '--seconds', str(args.seconds),
               '--command-seconds', str(args.command_seconds)]
    descriptor = os.open(folder / 'guard.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if (folder / 'ready.json').exists():
            print((folder / 'ready.json').read_text())
            return 0
        if process.poll() is not None:
            raise RuntimeError('Guard failed before ready')
        time.sleep(0.05)
    process.terminate()
    try:
        process.wait(timeout=args.command_seconds + 3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
    raise RuntimeError('Guard was not ready within five seconds')


def send(args):
    _, folder = directory(args.journal)
    with open(folder / 'client.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not (folder / 'ready.json').exists() or (folder / 'finished.json').exists():
            raise RuntimeError('Guard is not running')
        if (folder / 'request.json').exists():
            raise RuntimeError('A command is already pending')
        nonce = str(uuid.uuid4())
        atomic(folder / 'request.json', {'action': args.action, 'nonce': nonce})
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline:
            response = folder / 'response.json'
            if response.exists():
                value = json.loads(response.read_text())
                if value.get('nonce') == nonce:
                    print(json.dumps(value))
                    return 0 if value['ok'] else 1
            if (folder / 'finished.json').exists():
                raise RuntimeError('Guard finished before this request completed')
            time.sleep(0.05)
    raise RuntimeError('Request exceeded its deadline; guard retains the restore duty')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    for name in ('start', '_worker'):
        command = commands.add_parser(name)
        command.add_argument('--probe', required=True)
        command.add_argument('--journal', required=True)
        command.add_argument('--seconds', type=float, default=180)
        command.add_argument('--command-seconds', type=float, default=15)
    command = commands.add_parser('send')
    command.add_argument('--journal', required=True)
    command.add_argument('action', choices=('hide', 'restore', 'read', 'finish'))
    args = parser.parse_args()
    if args.mode in ('start', '_worker') and not (2 <= args.seconds <= 240 and 1 <= args.command_seconds <= 20):
        parser.error('Guard duration must be 2–240 seconds; command limit must be 1–20 seconds')
    try:
        return {'start': start, '_worker': worker, 'send': send}[args.mode](args)
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Quit the built native app from inside a main-actor Task, as the updater does.

Flux 0.22.0 and 0.22.1 hung here: terminate ran inside a main-queue job, so the
terminate-later loop could never drain the main queue to finish clean-up.
Pass only when the app exits by itself within the deadline, twice.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def run_once(executable, delay, deadline, direct=False):
    env = dict(os.environ, FLUX_PROBE_QUIT_FROM_TASK_AFTER=str(delay))
    if direct:
        env["FLUX_PROBE_QUIT_DIRECT"] = "1"
    started = time.monotonic()
    process = subprocess.Popen([str(executable)], env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=deadline)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
        print(output, flush=True)
        raise RuntimeError(f"FAIL: Flux did not quit within {deadline}s after a quit from a Task")
    seconds = round(time.monotonic() - started, 2)
    print(output, flush=True)
    if process.returncode != 0:
        raise RuntimeError(f"FAIL: Flux exited with status {process.returncode}")
    return seconds


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--delay", type=float, default=4)
    parser.add_argument("--deadline", type=float, default=30)
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Flux"
    times = [run_once(executable, args.delay, args.deadline) for _ in range(2)]
    # The 8 s terminate deadline is a fallback. Clean-up must finish first.
    if any(seconds > args.delay + 7 for seconds in times):
        raise RuntimeError(f"FAIL: quit relied on the fallback deadline: {times}")
    # Control: the 0.22.1 direct terminate inside a Task cannot run clean-up,
    # so only the fallback deadline ends it. This proves the cause and the rescue.
    control = run_once(executable, args.delay, args.deadline, direct=True)
    if control < args.delay + 7:
        raise RuntimeError(f"FAIL: the direct-terminate control quit in {control} s; the cause is not what we think")
    print(f"PASS: Flux quit from a main-actor Task in {times} s; direct control needed the deadline ({control} s)", flush=True)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(error, file=sys.stderr, flush=True)
        raise SystemExit(1)

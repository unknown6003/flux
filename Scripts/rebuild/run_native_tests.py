#!/usr/bin/env python3
"""Require Swift Testing completion as well as a zero process exit."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


def completed_count(output):
    matches = re.findall(r"Test run with ([1-9][0-9]*) tests?(?: in [0-9]+ suites?)? passed after ", output)
    if not matches:
        raise RuntimeError("Swift Testing did not report a completed passing run")
    return int(matches[-1])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("suite", choices=["FluxCoreTests", "FluxPlatformTests", "FluxUITests", "FluxApplicationTests"])
    parser.add_argument("--filter", default=None)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    directory = root / "build/native-test-logs"
    directory.mkdir(parents=True, exist_ok=True)
    suffix = ".isolated" if args.filter else ""
    log = directory / (args.suite + suffix + ".log")
    with log.open("w") as output:
        process = subprocess.Popen(["swift", "test", "--filter", args.filter or args.suite], cwd=root,
                                   env=os.environ | {"FLUX_NATIVE_TEST_PHASE_PATH": str(directory / ("rating-phase" + suffix + ".log"))},
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=90 if args.filter else 240)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise
    result = log.read_text(errors="replace")
    print(result, end="")
    if status != 0:
        raise RuntimeError(f"{args.suite} exited {status}")
    count = completed_count(result)
    print(f"Completed {args.suite}: {count} passing tests")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

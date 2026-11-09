#!/usr/bin/env python3
"""Require Swift Testing completion as well as a zero process exit."""
import argparse
import json
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
    parser.add_argument("suite", choices=["FluxCoreTests", "FluxPlatformTests", "FluxUITests", "FluxApplicationTests", "FluxRatingProbe"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    directory = root / "build/native-test-logs"
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / (args.suite + ".log")
    with log.open("w") as output:
        command = ["swift", "run", "FluxRatingProbe"] if args.suite == "FluxRatingProbe" else ["swift", "test", "--filter", args.suite]
        process = subprocess.Popen(command, cwd=root,
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=240)
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
    if args.suite == "FluxRatingProbe":
        reports = [json.loads(line) for line in result.splitlines() if line.startswith('{"nativeRatingScenariosPassed"')]
        if len(reports) != 1 or reports[0].get("nativeRatingScenariosPassed") != 4:
            raise RuntimeError("Native rating scenarios did not finish")
        print("Completed four native AppKit rating scenarios")
        return
    count = completed_count(result)
    print(f"Completed {args.suite}: {count} passing tests")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

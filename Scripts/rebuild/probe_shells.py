#!/usr/bin/env python3
"""Compare equivalent throwaway native shells. This is not a whole-app benchmark."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "native-shells"


def run(command, seconds):
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        __import__("os").killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise RuntimeError(f"deadline: {command[0]}")
    if process.returncode:
        raise RuntimeError(f"exit {process.returncode}: {stderr[-4000:]}")
    return stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    for name in ["AppKit", "SwiftUI"]:
        run(["swiftc", "-swift-version", "6", "-O", "-parse-as-library", "-module-name", f"Flux{name}ShellProbe",
             str(ROOT / "Scripts/rebuild/ShellProbe.swift"),
             str(ROOT / f"Scripts/rebuild/{name}Shell.swift"), "-o", str(OUT / name)], 60)
    samples = []
    for repeat in range(3):
        for name in (["AppKit", "SwiftUI"] if repeat % 2 == 0 else ["SwiftUI", "AppKit"]):
            if time.monotonic() - start > 160:
                raise RuntimeError("overall deadline")
            lines = run([str(OUT / name)], 20).splitlines()
            phases = [json.loads(line) for line in lines if line.startswith("{")]
            if [item["phase"] for item in phases] != ["closed", "shown", "cycles", "closedAfterCycles"]:
                raise RuntimeError(f"incomplete phases: {name}")
            samples.append({"framework": name, "repeat": repeat, "phases": phases})
    report = {"scope": "Separate optimized binaries, same20 rows and controls,2-second intervals,100 create/display/release cycles. No real widgets/services, media helpers, wakeup counters or physical UI interaction.", "samples": samples}
    (OUT / "samples.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

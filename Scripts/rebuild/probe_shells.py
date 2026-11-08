#!/usr/bin/env python3
"""Compare equivalent throwaway native shells. This is not a whole-app benchmark."""
import json
import os
from pathlib import Path
import plistlib
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
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate(timeout=5)
        (OUT / "timeout-stdout.txt").write_text(stdout)
        (OUT / "timeout-stderr.txt").write_text(stderr)
        raise RuntimeError(f"deadline: {command[0]}; stdout={stdout[-2000:]}; stderr={stderr[-2000:]}")
    if process.returncode:
        raise RuntimeError(f"exit {process.returncode}: {stderr[-4000:]}")
    return stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    binaries = {}
    for name in ["AppKit", "SwiftUI"]:
        bundle = OUT / f"Flux{name}ShellProbe.app" / "Contents"
        (bundle / "MacOS").mkdir(parents=True, exist_ok=True)
        executable = f"Flux{name}ShellProbe"
        binaries[name] = bundle / "MacOS" / executable
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": f"com.flux.shellprobe.{name.lower()}",
            "CFBundleName": executable, "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL", "LSUIElement": True,
            "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
        }))
        run(["swiftc", "-swift-version", "6", "-O", "-parse-as-library", "-module-name", f"Flux{name}ShellProbe",
             str(ROOT / "Scripts/rebuild/ShellProbe.swift"),
             str(ROOT / f"Scripts/rebuild/{name}Shell.swift"), "-o", str(binaries[name])], 60)
        run(["codesign", "--force", "--sign", "-", str(bundle.parent)], 10)
    samples = []
    for repeat in range(3):
        for name in (["AppKit", "SwiftUI"] if repeat % 2 == 0 else ["SwiftUI", "AppKit"]):
            if time.monotonic() - start > 160:
                raise RuntimeError("overall deadline")
            lines = run([str(binaries[name])], 20).splitlines()
            phases = [json.loads(line) for line in lines if line.startswith("{")]
            if [item["phase"] for item in phases] != ["closed", "shown", "cycles", "closedAfterCycles"]:
                raise RuntimeError(f"incomplete phases: {name}")
            samples.append({"framework": name, "repeat": repeat, "phases": phases})
    report = {"scope": "Separate optimized app bundles, same20 rows and controls,2-second intervals,20 create/display/release cycles. No real widgets/services, media helpers, wakeup counters or physical UI interaction.", "samples": samples}
    (OUT / "samples.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

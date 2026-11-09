#!/usr/bin/env python3
"""Render the 0.21.35 notch and the native notch with the same fixtures, then
diff them. Offscreen only: no window is shown, no camera or pasteboard is used.

    python3 Scripts/rebuild/render_notch_comparison.py [output-dir]

Writes <output-dir>/old/*.png (0.21.35), <output-dir>/new/*.png (native),
<output-dir>/compare/*.png (old | new | diff) and <output-dir>/report.json.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(command, timeout):
    print("+", " ".join(str(part) for part in command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True, timeout=timeout, stdin=subprocess.DEVNULL)


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/notch-compare"
    output = output.resolve()
    old = output / "old"
    old.mkdir(parents=True, exist_ok=True)
    run(["swift", "build", "--product", "Flux"], 1200)
    run(["swift", "build", "--product", "FluxNotchProbe"], 1200)
    bin_dir = Path(subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True, timeout=120,
                                  capture_output=True, text=True).stdout.strip())
    # 0.21.35's own snapshot harness.
    run([bin_dir / "Flux", "--snapshot-notch", old, "all", "dark"], 300)
    # The remaining states, from the same 0.21.35 sources.
    sources = sorted(str(path) for path in (ROOT / "Sources/Flux").rglob("*.swift") if path.name != "main.swift")
    legacy = output / "LegacyNotchRender"
    run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-Onone",
         "-target", "arm64-apple-macos14.0", "-module-name", "Flux",
         *sources, ROOT / "Scripts/rebuild/LegacyNotchRender/LegacyNotchRender.swift", "-o", legacy], 1200)
    run([legacy, old], 300)
    legacy.unlink(missing_ok=True)
    run([bin_dir / "FluxNotchProbe", output, old], 600)
    report = json.loads((output / "report.json").read_text())
    worst = max((entry.get("differingPercent", 0) for entry in report if entry.get("old")), default=0)
    missing = [entry["state"] for entry in report if not entry.get("old")]
    print(f"Compared {len(report) - len(missing)} states. Largest difference: {worst:.2f}%.")
    if missing:
        print("No 0.21.35 reference for: " + ", ".join(missing))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Stop only the built fixture test process at its exit boundary."""
import os
from pathlib import Path
import signal
import subprocess

root = Path(__file__).resolve().parents[2]
binary = root / ".build/debug/FluxPackageTests.xctest/Contents/MacOS/FluxPackageTests"
if not binary.is_file():
    raise SystemExit("Built test executable absent")
log = root / "build/native-test-logs/exit-backtrace.log"
with log.open("w") as output:
    process = subprocess.Popen(["xcrun", "lldb", "--batch",
        "-o", "breakpoint set --name exit --name _exit",
        "-o", "run", "-o", "thread backtrace all", "-o", "process kill",
        "--", str(binary), "--testing-library", "swift-testing", "--filter", "SettingsCoordinatorTests"],
        cwd=root, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=90)
    except BaseException:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        raise
print(log.read_text(errors="replace"))
raise SystemExit(status)

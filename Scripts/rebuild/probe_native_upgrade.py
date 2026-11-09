#!/usr/bin/env python3
"""Install a built native Flux DMG through the shipped 0.21.35 updater.

The installed app runs the unchanged Sources/Flux/Update code with the real
com.flux.menubar identity. A loopback server offers the DMG as the latest
release. Pass only when the old helper confirms the native startup receipt,
removes its backup and leaves the signed native app running at the same path.
"""
import argparse
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_update import ROOT, SWIFT_PROBE, LoopbackHTTPServer, run, updater_source  # noqa: E402


def serve(dmg, version):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            # Published releases name the image Flux-<version>.dmg (see ci.yml publish).
            name = f"Flux-{version}.dmg"
            if self.path == "/latest":
                body = json.dumps({"tag_name": "v" + version, "name": "Flux " + version,
                                   "html_url": "https://example.invalid/native", "draft": False,
                                   "prerelease": False, "assets": [{"name": name,
                                   "browser_download_url": f"http://127.0.0.1:{self.server.server_port}/{name}"}]}).encode()
            elif self.path == "/" + name:
                body = dmg.read_bytes()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def native_pids(executable):
    listing = subprocess.run(["/bin/ps", "-axo", "pid=,stat=,command="], capture_output=True,
                             text=True, timeout=5).stdout
    pids = []
    for line in listing.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and not parts[1].startswith(("Z", "X")) and parts[2].startswith(str(executable)):
            pids.append(int(parts[0]))
    return pids


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dmg", type=Path)
    parser.add_argument("version")
    parser.add_argument("--output", type=Path, default=ROOT / "build/native-upgrade")
    args = parser.parse_args()
    dmg = args.dmg.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="flux-native-upgrade-") as directory:
        # ps reports /private/var/folders; match the real path.
        temporary = Path(directory).resolve()
        (temporary / "UpdateChecker.swift").write_text(updater_source(None))
        (temporary / "main.swift").write_text(SWIFT_PROBE)
        binary = temporary / "FluxUpdateProbe"
        sources = [temporary / "UpdateChecker.swift", temporary / "main.swift", ROOT / "Sources/Flux/Support/Log.swift"]
        sources += [p for p in sorted((ROOT / "Sources/Flux/Update").glob("*.swift")) if p.name != "UpdateChecker.swift"]
        run(["swiftc", "-swift-version", "5", *map(str, sources), "-o", str(binary)], 180)
        parent = temporary / "installed"
        dest = parent / "Flux.app"
        (dest / "Contents/MacOS").mkdir(parents=True)
        downloads = temporary / "Downloads"
        downloads.mkdir()
        server = serve(dmg, args.version)
        executable = dest / "Contents/MacOS/Flux"
        try:
            run(["/usr/bin/ditto", str(binary), str(dest / "Contents/MacOS/FluxUpdateProbe")], 20)
            info = {"CFBundleIdentifier": "com.flux.menubar", "CFBundleExecutable": "FluxUpdateProbe",
                    "CFBundleName": "Flux", "CFBundlePackageType": "APPL", "LSUIElement": True,
                    "CFBundleShortVersionString": "0.21.35", "CFBundleVersion": "62",
                    "FluxProbeOutput": str(temporary / "probe-output.txt"), "FluxProbeDownloads": str(downloads),
                    "FluxProbeSuite": "com.flux.native-upgrade-probe", "FluxProbeCase": "automatic",
                    "FluxProbeRelease": f"http://127.0.0.1:{server.server_port}/latest",
                    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
            with (dest / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            run(["/usr/bin/codesign", "--force", "--sign", "-", str(dest)], 20)
            started = time.monotonic()
            result = run([str(dest / "Contents/MacOS/FluxUpdateProbe")], 60, check=False)
            (args.output / "old-updater.log").write_text(result.stdout or "")
            print(result.stdout, flush=True)
            deadline = time.monotonic() + 60
            confirmed = False
            while time.monotonic() < deadline:
                version = None
                try:
                    version = plistlib.loads((dest / "Contents/Info.plist").read_bytes()).get("CFBundleShortVersionString")
                except (OSError, plistlib.InvalidFileException):
                    pass
                backups = list(parent.glob(".Flux-backup-*.app"))
                if version == args.version and not backups and native_pids(executable):
                    confirmed = True
                    break
                time.sleep(0.25)
            # The helper writes its verdict after it removes the backup, so wait for it.
            helper = "missing"
            verdict_deadline = time.monotonic() + 15
            while time.monotonic() < verdict_deadline:
                logs = sorted(Path(tempfile.gettempdir()).glob("flux-update-*/install.log"), key=lambda p: p.stat().st_mtime)
                helper = logs[-1].read_text() if logs else "missing"
                if "helper exit=" in helper:
                    break
                time.sleep(0.25)
            (args.output / "install.log").write_text(helper)
            print("helper log:\n" + helper, flush=True)
            print(f"state: version={version} backups={backups} pids={native_pids(executable)}", flush=True)
            if not confirmed or "PASS: installed update and confirmed startup" not in helper:
                raise RuntimeError("FAIL: the 0.21.35 updater did not confirm the native app")
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dest)], 30)
            installed = plistlib.loads((dest / "Contents/Info.plist").read_bytes())
            assert installed["CFBundleIdentifier"] == "com.flux.menubar"
            assert installed.get("FluxNativeApp") is True, "FAIL: installed app is not the native release"
            summary = dict(result="pass", version=installed["CFBundleShortVersionString"],
                           build=installed["CFBundleVersion"], seconds=round(time.monotonic() - started, 2),
                           runningPIDs=native_pids(executable))
            (args.output / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
            print("PASS: 0.21.35 updater installed and confirmed native", json.dumps(summary), flush=True)
        finally:
            for pid in native_pids(executable):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for _ in range(50):
                if not native_pids(executable):
                    break
                time.sleep(0.1)
            for pid in native_pids(executable):
                os.kill(pid, signal.SIGKILL)
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError) as error:
        print(error, file=sys.stderr, flush=True)
        raise SystemExit(1)

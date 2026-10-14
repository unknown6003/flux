#!/usr/bin/env python3
"""Exercise updater entry points with local releases and disposable app bundles."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def stop_tree(process):
    snapshot = subprocess.Popen(["ps", "-axo", "pid=,ppid="], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        rows, _ = snapshot.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(snapshot.pid, signal.SIGTERM)
        try:
            rows, _ = snapshot.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(snapshot.pid, signal.SIGKILL)
            rows, _ = snapshot.communicate(timeout=1)
    parents = [tuple(map(int, row.split())) for row in rows.splitlines() if len(row.split()) == 2]
    owned = {process.pid}
    while True:
        children = {pid for pid, parent in parents if parent in owned}
        if children <= owned:
            break
        owned |= children
    for pid in owned:
        for send in [os.killpg, os.kill]:
            try:
                send(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    try:
        output, _ = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        output = ""
    for pid in owned:
        for send in [os.killpg, os.kill]:
            try:
                send(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if process.poll() is None:
        output, _ = process.communicate(timeout=3)
    return output


def run(command, seconds=60, check=True, **kwargs):
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               start_new_session=True, **kwargs)
    try:
        output, _ = process.communicate(timeout=seconds)
    except BaseException as error:
        output = stop_tree(process)
        print(output[-4000:], flush=True)
        if isinstance(error, subprocess.TimeoutExpired):
            raise RuntimeError(f"FAIL: {command[0]} exceeded {seconds}s; stopped its process group") from error
        raise
    if check and process.returncode:
        raise RuntimeError(f"FAIL: {command[0]} exited {process.returncode}\n{output[-4000:]}")
    return subprocess.CompletedProcess(command, process.returncode, output)


def updater_source(reference=None):
    if reference:
        return run(["git", "show", f"{reference}:Sources/Flux/Update/UpdateChecker.swift"], 20).stdout
    return (ROOT / "Sources/Flux/Update/UpdateChecker.swift").read_text()


def baseline_seams(source):
    # Change only environment bindings. The baseline check/install logic is intact.
    source = source.replace("private let currentVersion: String", """private let currentVersion: String
    private let session: URLSession
    private let releaseURL: URL
    private let installURL: URL
    private let terminate: () -> Void""", 1)
    source = source.replace("""init(currentVersion: String = AppInfo.version) {
        self.currentVersion = currentVersion
    }""", """init(currentVersion: String = AppInfo.version, session: URLSession = .shared,
         releaseURL: URL, installURL: URL, terminate: @escaping () -> Void) {
        self.currentVersion = currentVersion
        self.session = session
        self.releaseURL = releaseURL
        self.installURL = installURL
        self.terminate = terminate
    }""", 1)
    source = source.replace("URLRequest(url: Self.releasesURL)", "URLRequest(url: releaseURL)")
    source = source.replace("URLSession.shared.data(for:", "session.data(for:")
    source = source.replace("URLSession.shared.download(for:", "session.download(for:")
    source = source.replace("let installURL = Bundle.main.bundleURL\n", "")
    source = source.replace("NSApp.terminate(nil)", "self.terminate()")
    return source


def shell_probe(reference=None):
    source = updater_source(reference)
    installer = ROOT / "Sources/Flux/Update/UpdateInstaller.swift"
    if not reference and installer.exists():
        source = installer.read_text()
    match = re.search(r'let script = """\n(.*?)\n        """', source, re.S)
    if not match:
        raise RuntimeError("FAIL: no emitted install helper found")
    template = textwrap.dedent(match.group(1))
    failures = []
    for case in ["success", "parent_alive", "swap_failure", "relaunch_failure", "hung_relaunch"]:
        with tempfile.TemporaryDirectory(prefix="flux-swap-probe-") as directory:
            root = Path(directory)
            dest = root / "Flux 'installed.app"
            dest.mkdir()
            (dest / "version").write_text("0.21.25")
            staged = root / "Flux 'staged.app"
            staged.mkdir()
            (staged / "version").write_text("0.21.26")
            bins = root / "tools"
            bins.mkdir()
            bodies = {
                "ditto": 'if [ "' + case + '" = swap_failure ]; then '
                         'mkdir -p "$2"; echo partial > "$2/version"; exit 1; fi\n'
                         'cp -R "$1" "$2"',
                "xattr": "exit 0",
                "hdiutil": "exit 0",
                "open": 'if [ "' + case + '" = relaunch_failure ] && '
                        '[ "$(cat "$1/version")" = 0.21.26 ]; then exit 1; fi\n'
                        'if [ "' + case + '" = hung_relaunch ] && '
                        '[ "$(cat "$1/version")" = 0.21.26 ]; then '
                        'sleep 30 & child=$!; echo "$child" > '
                        + shlex.quote(str(root / "sleeper.pid")) + '; wait "$child"; fi\n'
                        'cat "$1/version" > ' + shlex.quote(str(root / "relaunched")),
                "mv": 'if [ "' + case + '" = swap_failure ] && [ "$1" = '
                      + shlex.quote(str(staged)) + ' ]; then exit 1; fi\n'
                      '/bin/mv "$@"',
            }
            script = template
            for name, body in bodies.items():
                tool = bins / name
                tool.write_text("#!/bin/bash\n" + body + "\n")
                tool.chmod(0o755)
                script = script.replace("/usr/bin/" + name, shlex.quote(str(tool)))
                script = script.replace("/bin/" + name, shlex.quote(str(tool)))
            replacements = {
                r"\(q(newApp.path))": staged,
                r"\(q(staged.path))": staged,
                r"\(q(installURL.path))": dest,
                r"\(q(mount.path))": root / "mount",
                r"\(q(dmg.path))": root / "fixture.dmg",
                r"\(q(ready.path))": root / "ready",
                r"\(q(backup.path))": root / "backup.app",
                r"\(pid)": os.getpid() if case == "parent_alive" else 2147483647,
            }
            for token, value in replacements.items():
                script = script.replace(token, shlex.quote(str(value)))
            # Bound the test's process-exit wait, without changing its outcome policy.
            script = script.replace("seq 1 50", "seq 1 5").replace("EXIT_WAIT_SECONDS=10", "EXIT_WAIT_SECONDS=1")
            if case == "hung_relaunch":
                script = script.replace("bounded 15", "bounded 1")
            helper = root / "helper.sh"
            helper.write_text(script)
            environment = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ["PATH"])
            result = run(["/bin/bash", str(helper)], 20, check=False, env=environment)
            installed = (dest / "version").read_text() if (dest / "version").exists() else "missing"
            launched = (root / "relaunched").read_text() if (root / "relaunched").exists() else "none"
            expected = "0.21.26" if case == "success" else "0.21.25"
            good = installed == expected and (launched == expected if case != "parent_alive" else launched == "none")
            if case == "hung_relaunch" and (root / "sleeper.pid").exists():
                sleeper = int((root / "sleeper.pid").read_text())
                state = run(["ps", "-p", str(sleeper), "-o", "stat="], 5, check=False).stdout.strip()
                good = good and (not state or state.startswith("Z"))
            print(f"{'PASS' if good else 'FAIL'}: helper {case}, installed={installed}, relaunched={launched}, exit={result.returncode}", flush=True)
            if not good:
                failures.append(case)
    if failures:
        raise RuntimeError("FAIL: helper cases " + ", ".join(failures))


SWIFT_PROBE = r'''
import AppKit
import Combine

enum AppInfo { static let version = "0.21.25" }

@MainActor
func probe() {
    let info = Bundle.main.infoDictionary!
    let output = URL(fileURLWithPath: info["FluxProbeOutput"] as! String)
    let suite = info["FluxProbeSuite"] as! String
    let defaults = UserDefaults(suiteName: suite)!
    let version = info["CFBundleShortVersionString"] as! String
    if version == "0.21.26" {
        let result = "version=\(version) settings=\(defaults.string(forKey: "keep") ?? "missing")"
        try! result.write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }
    defaults.set("unchanged", forKey: "keep")
    let mode = info["FluxProbeCase"] as! String
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = 8
    let updater = UpdateChecker(currentVersion: version, session: URLSession(configuration: config),
        releaseURL: URL(string: info["FluxProbeRelease"] as! String)!,
        installURL: Bundle.main.bundleURL, terminate: { NSApp.terminate(nil) })
    let started = Date()
    Task { @MainActor in
        updater.checkForUpdates(userInitiated: mode == "manual")
        if mode == "overlap" {
            try? await Task.sleep(for: .milliseconds(50))
            updater.checkForUpdates(userInitiated: true)
        }
        while Date().timeIntervalSince(started) < 12 {
            if case .failed(let message) = updater.state {
                print("Updater failure: \(message)")
                if mode == "failure" {
                    try! "failed safely settings=\(defaults.string(forKey: "keep") ?? "missing")"
                        .write(to: output, atomically: true, encoding: .utf8)
                    exit(0)
                }
                exit(1)
            }
            if mode == "manual", let release = updater.pendingRelease {
                updater.downloadAndInstall(release)
            }
            if Date().timeIntervalSince(started) > 4, case .available = updater.state,
               mode == "overlap" {
                print("FAIL: a manual refresh suppressed the background install; still 0.21.25")
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        print("FAIL: updater did not complete before its deadline, state=\(updater.state)")
        exit(1)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
MainActor.assumeIsolated { probe() }
'''


@contextmanager
def fixture_server(dmg):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/latest":
                time.sleep(0.3)
                payload = {"tag_name": "v0.21.26", "name": "Flux 0.21.26",
                           "html_url": "https://example.invalid/fixture", "draft": False,
                           "prerelease": False, "assets": [{"name": "Flux.dmg",
                           "browser_download_url": f"http://127.0.0.1:{self.server.server_port}/Flux.dmg"}]}
                body = json.dumps(payload).encode()
            elif self.path == "/Flux.dmg":
                body = dmg.read_bytes()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/latest"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        if thread.is_alive():
            raise RuntimeError("FAIL: fixture server did not stop")


def mac_probe(reference=None, cases=None):
    if sys.platform != "darwin":
        raise RuntimeError("FAIL: public updater probe requires macOS, Swift, hdiutil, and LaunchServices")
    with tempfile.TemporaryDirectory(prefix="flux-update-probe-") as directory:
        temporary = Path(directory)
        source = temporary / "UpdateChecker.swift"
        content = updater_source(reference)
        source.write_text(baseline_seams(content) if reference else content)
        main = temporary / "main.swift"
        main.write_text(SWIFT_PROBE)
        binary = temporary / "FluxUpdateProbe"
        sources = [str(source), str(main), str(ROOT / "Sources/Flux/Support/Log.swift")]
        if not reference:
            sources += [str(path) for path in sorted((ROOT / "Sources/Flux/Update").glob("*.swift"))
                        if path.name != "UpdateChecker.swift"]
        run(["swiftc", "-swift-version", "5", *sources, "-o", str(binary)], 120)
        for case in cases or ["automatic", "overlap", "manual", "failure"]:
            root = temporary / case
            root.mkdir()
            output = root / "result.txt"
            suite = "com.flux.update-probe." + str(uuid.uuid4())
            dest = root / "Flux 'installed.app"
            candidate = root / "volume" / "Flux.app"
            dmg = root / "fixture.dmg"
            candidate.parent.mkdir()
            with fixture_server(dmg) as endpoint:
                info = {"CFBundleIdentifier": suite, "CFBundleExecutable": "FluxUpdateProbe",
                        "CFBundleName": "FluxUpdateProbe", "CFBundlePackageType": "APPL",
                        "LSUIElement": True, "FluxProbeOutput": str(output),
                        "FluxProbeSuite": suite, "FluxProbeCase": case, "FluxProbeRelease": endpoint,
                        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
                for app, version in [(dest, "0.21.25"), (candidate, "0.21.26")]:
                    contents = app / "Contents"
                    (contents / "MacOS").mkdir(parents=True)
                    run(["/usr/bin/ditto", str(binary), str(contents / "MacOS/FluxUpdateProbe")], 20)
                    info["CFBundleShortVersionString"] = version
                    with (contents / "Info.plist").open("wb") as stream:
                        plistlib.dump(info, stream)
                    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], 20)
                if case == "failure":
                    dmg.write_bytes(b"This fixture is not a disk image.")
                else:
                    run(["/usr/bin/hdiutil", "create", "-srcfolder", str(candidate.parent),
                         "-format", "UDZO", "-volname", "FluxUpdateProbe", str(dmg)], 60)
                initial = (dest / "Contents/MacOS/FluxUpdateProbe").read_bytes()
                try:
                    result = run([str(dest / "Contents/MacOS/FluxUpdateProbe")], 20)
                    print(result.stdout, end="", flush=True)
                    deadline = time.monotonic() + 20
                    while not output.exists() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    if not output.exists():
                        raise RuntimeError(f"FAIL: {case} did not relaunch the installed app")
                    installed = plistlib.loads((dest / "Contents/Info.plist").read_bytes())
                    if case == "failure":
                        assert installed["CFBundleShortVersionString"] == "0.21.25"
                        assert (dest / "Contents/MacOS/FluxUpdateProbe").read_bytes() == initial
                        assert output.read_text() == "failed safely settings=unchanged"
                    else:
                        assert installed["CFBundleShortVersionString"] == "0.21.26"
                        assert output.read_text() == "version=0.21.26 settings=unchanged"
                        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dest)], 20)
                    print(f"PASS: public updater {case}, {output.read_text()}", flush=True)
                finally:
                    run(["/usr/bin/defaults", "delete", suite], 10, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shell-only", action="store_true")
    parser.add_argument("--baseline-ref")
    parser.add_argument("--case", choices=["automatic", "overlap", "manual", "failure"])
    args = parser.parse_args()
    if args.shell_only:
        shell_probe(args.baseline_ref)
    else:
        mac_probe(args.baseline_ref, [args.case] if args.case else None)
        shell_probe(args.baseline_ref)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError) as error:
        print(error, file=sys.stderr, flush=True)
        raise SystemExit(1)

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
from socketserver import TCPServer
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
    except subprocess.TimeoutExpired as error:
        output = error.output or ""
        if isinstance(output, bytes): output = output.decode(errors="replace")
    for pid in owned:
        for send in [os.killpg, os.kill]:
            try:
                send(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        output, _ = process.communicate(timeout=3)
    except subprocess.TimeoutExpired as error:
        partial = error.output or ""
        if isinstance(partial, bytes): partial = partial.decode(errors="replace")
        output = partial or output
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
    elif reference and 'let script = """' not in source:
        source = run(["git", "show", f"{reference}:Sources/Flux/Update/UpdateInstaller.swift"], 20).stdout
    match = re.search(r'let script = """\n(.*?)\n        """', source, re.S)
    if not match:
        raise RuntimeError("FAIL: no emitted install helper found")
    template = textwrap.dedent(match.group(1))
    failures = []
    for case in ["success", "parent_alive", "swap_failure", "relaunch_failure", "hung_relaunch", "accepted_crash", "ready_crash", "alive_unconfirmed", "inspection_failure", "worker_outlives_command"]:
        with tempfile.TemporaryDirectory(prefix="flux-swap-probe-") as directory:
            root = Path(directory)
            install_parent = root / "installed"
            install_parent.mkdir()
            dest = install_parent / "Flux 'installed.app"
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
                "open": 'exit 1',
                "mv": 'if [ "' + case + '" = swap_failure ] && [ "$1" = '
                      + shlex.quote(str(staged)) + ' ]; then exit 1; fi\n'
                      '/bin/mv "$@"',
            }
            if case == "inspection_failure":
                bodies["ps"] = "exit 1"
            if case == "worker_outlives_command":
                bodies["mv"] = '/bin/mv "$@"; result=$?\nif [ "$1" = ' + shlex.quote(str(dest)) + ' ]; then\n' \
                    'sleep 30 >/dev/null 2>&1 & echo $! > ' + shlex.quote(str(root / "worker.pid")) + '\nfi\nexit $result'
            open_tool = bins / "open"
            open_tool.write_text("#!" + sys.executable + "\n" + """
import sys, subprocess, os
from pathlib import Path
args = sys.argv[1:]
dest = Path(args[1] if args[0] == '-n' else args[0])
version = (dest / 'version').read_text()
case = CASE
if version == '0.21.26' and case == 'relaunch_failure': sys.exit(1)
if version == '0.21.26' and case == 'hung_relaunch':
    child = subprocess.Popen(['sleep', '30'])
    Path(SLEEPER).write_text(str(child.pid))
    child.wait()
if version == '0.21.26' and case in ('accepted_crash', 'ready_crash') and '--flux-update-receipt' not in args: sys.exit(0)
if version == '0.21.26' and '--flux-update-receipt' in args:
    receipt = Path(args[args.index('--flux-update-receipt') + 1])
    token = args[args.index('--flux-update-token') + 1]
    if case == 'accepted_crash':
        receipt.write_text(f'{token}\\n{os.getpid()}\\n{dest}\\nstarted\\n')
        sys.exit(0)
    launch = [sys.executable, '-c', 'import time; time.sleep(0.2)'] if case in ('ready_crash', 'inspection_failure') else ['sleep', '30']
    # LaunchServices starts the app outside the requesting open command group.
    child = subprocess.Popen(launch, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    Path(SLEEPER).write_text(str(child.pid))
    phase = 'started' if case == 'alive_unconfirmed' else 'ready'
    receipt.write_text(f'{token}\\n{child.pid}\\n{dest}\\n{phase}\\n')
Path(LAUNCHED).write_text(version)
""".replace('CASE', repr(case)).replace('SLEEPER', repr(str(root / 'sleeper.pid')))
                .replace('LAUNCHED', repr(str(root / 'relaunched'))))
            open_tool.chmod(0o755)
            bodies.pop("open")
            script = template.replace("/usr/bin/open", shlex.quote(str(open_tool)))
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
                r"\(q(token))": "11111111-1111-4111-8111-111111111111",
                r"\(q(receipt.path))": root / "startup",
                r"\(q(executable.path))": dest / "Contents/MacOS/FluxUpdateProbe",
                r"\(q(processes.path))": root / "processes",
                r"\(pid)": os.getpid() if case == "parent_alive" else 2147483647,
            }
            for token, value in replacements.items():
                script = script.replace(token, shlex.quote(str(value)))
            # Bound the test's process-exit wait, without changing its outcome policy.
            script = script.replace("seq 1 50", "seq 1 5").replace("EXIT_WAIT_SECONDS=10", "EXIT_WAIT_SECONDS=1")
            script = script.replace("STARTUP_WAIT_SECONDS=20", "STARTUP_WAIT_SECONDS=1").replace("STABILITY_SECONDS=2", "STABILITY_SECONDS=0")
            if case in ("ready_crash", "inspection_failure"):
                script = script.replace("STABILITY_SECONDS=0", "STABILITY_SECONDS=1").replace("STARTUP_WAIT_SECONDS=1", "STARTUP_WAIT_SECONDS=2")
            if case == "hung_relaunch":
                script = script.replace("bounded 15", "bounded 1")
            helper = root / "helper.sh"
            helper.write_text(script)
            environment = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ["PATH"])
            result = run(["/bin/bash", str(helper)], 20, check=False, env=environment)
            installed = (dest / "version").read_text() if (dest / "version").exists() else "missing"
            launched = (root / "relaunched").read_text() if (root / "relaunched").exists() else "none"
            expected = "0.21.26" if case in ("success", "alive_unconfirmed", "inspection_failure", "worker_outlives_command") else "0.21.25"
            good = installed == expected and (launched == expected if case != "parent_alive" else launched == "none")
            if case in ("alive_unconfirmed", "inspection_failure"):
                backup_version = root / "backup.app/version"
                good = good and backup_version.exists() and backup_version.read_text() == "0.21.25"
            if (root / "sleeper.pid").exists():
                sleeper = int((root / "sleeper.pid").read_text())
                state = run(["ps", "-p", str(sleeper), "-o", "stat="], 5, check=False).stdout.strip()
                if case == "hung_relaunch":
                    good = good and (not state or state.startswith("Z"))
                else:
                    if case == "alive_unconfirmed": good = good and bool(state) and not state.startswith("Z")
                    if case == "inspection_failure": good = good and (not state or state.startswith("Z"))
                    try: os.kill(sleeper, signal.SIGTERM)
                    except ProcessLookupError: pass
            if (root / "worker.pid").exists():
                worker = int((root / "worker.pid").read_text())
                state = run(["ps", "-p", str(worker), "-o", "stat="], 5, check=False).stdout.strip()
                good = good and (not state or state.startswith("Z"))
                try: os.kill(worker, signal.SIGKILL)
                except ProcessLookupError: pass
            print(f"{'PASS' if good else 'FAIL'}: helper {case}, installed={installed}, relaunched={launched}, exit={result.returncode}", flush=True)
            if not good:
                failures.append(case)
    if failures:
        raise RuntimeError("FAIL: helper cases " + ", ".join(failures))


def supervisor_probe(reference=None, leader_exits=False):
    source = (run(["git", "show", f"{reference}:Sources/Flux/Update/UpdateInstaller.swift"], 20).stdout
              if reference else (ROOT / "Sources/Flux/Update/UpdateInstaller.swift").read_text())
    supervisor = textwrap.dedent(re.search(r'let supervisor = """\n(.*?)\n        """', source, re.S).group(1))
    with tempfile.TemporaryDirectory(prefix="flux-supervisor-probe-") as directory:
        root = Path(directory)
        fixture = root / "hang.sh"
        fixture.write_text("#!/bin/bash\necho diagnostic-before-timeout\necho $$ > "
                           + shlex.quote(str(root / "command.pid")) + "\nsleep 30 & child=$!\necho $child > "
                           + shlex.quote(str(root / "descendant.pid")) + ("\nexit 0\n" if leader_exits else "\nwait $child\n"))
        fixture.chmod(0o755)
        arguments = ["/bin/bash", "-c", supervisor, "probe"]
        if "limit=$1" in supervisor:
            arguments += ["1"]
        arguments += [str(fixture)]
        parent = "import subprocess; from pathlib import Path; " \
                 + "log=open(" + repr(str(root / "output")) + ",'w'); " \
                 + "child=subprocess.Popen(" + repr(arguments) + ",stdout=log,stderr=log,start_new_session=True); " \
                 + "Path(" + repr(str(root / "supervisor.pid")) + ").write_text(str(child.pid))"
        run([sys.executable, "-c", parent], 5)
        deadline = time.monotonic() + 4
        while not (root / "descendant.pid").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(2)
        states = []
        try:
            for name in ["supervisor", "command", "descendant"]:
                pid = int((root / (name + ".pid")).read_text())
                state = run(["ps", "-p", str(pid), "-o", "stat="], 5, check=False).stdout.strip()
                states.append(not state or state.startswith("Z"))
            output = (root / "output").read_text()
            good = all(states) and "diagnostic-before-timeout" in output and (leader_exits or "deadline reached" in output)
            print(f"{'PASS' if good else 'FAIL'}: exact supervisor after caller exit, leader_exits={leader_exits}, all descendants stopped={all(states)}", flush=True)
            print(output[-800:], flush=True)
            if not good:
                raise RuntimeError("FAIL: command descendants survived the owner or command exit")
        finally:
            for name in ["command", "supervisor", "descendant"]:
                if (root / (name + ".pid")).exists():
                    pid = int((root / (name + ".pid")).read_text())
                    for sender in [os.killpg, os.kill]:
                        try: sender(pid, signal.SIGTERM)
                        except ProcessLookupError: pass
            time.sleep(0.2)
            for name in ["command", "supervisor", "descendant"]:
                if (root / (name + ".pid")).exists():
                    pid = int((root / (name + ".pid")).read_text())
                    for sender in [os.killpg, os.kill]:
                        try: sender(pid, signal.SIGKILL)
                        except ProcessLookupError: pass


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
    UpdateStartup.registerLaunch()
    let version = info["CFBundleShortVersionString"] as! String
    if version == "0.21.26" {
        let result = "version=\(version) settings=\(defaults.string(forKey: "keep") ?? "missing")"
        UpdateStartup.confirmLaunch()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(12)
            let parent = Bundle.main.bundleURL.deletingLastPathComponent()
            while Date() < deadline {
                let files = try! FileManager.default.contentsOfDirectory(atPath: parent.path)
                if !files.contains(where: { $0.hasPrefix(".Flux-backup-") && $0.hasSuffix(".app") }) {
                    try! result.write(to: output, atomically: true, encoding: .utf8)
                    exit(0)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            var detail = "FAIL: helper did not confirm the running fixture; temp=\(FileManager.default.temporaryDirectory.path)"
            if let index = CommandLine.arguments.firstIndex(of: "--flux-update-receipt"),
               index + 1 < CommandLine.arguments.count {
                let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                detail += "\nreceipt=\(receipt.path)\n" + ((try? String(contentsOf: receipt)) ?? "missing")
                detail += "\nhelper log:\n" + ((try? String(contentsOf: receipt.deletingLastPathComponent().appendingPathComponent("install.log"))) ?? "missing")
            }
            try! detail.write(to: output, atomically: true, encoding: .utf8)
            exit(1)
        }
        NSApplication.shared.run()
        return
    }
    defaults.set("unchanged", forKey: "keep")
    let mode = info["FluxProbeCase"] as! String
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = 8
    let updater = UpdateChecker(currentVersion: version, session: URLSession(configuration: config),
        releaseURL: URL(string: info["FluxProbeRelease"] as! String)!,
        installURL: Bundle.main.bundleURL,
        downloadsURL: URL(fileURLWithPath: info["FluxProbeDownloads"] as! String), terminate: { NSApp.terminate(nil) })
    let started = Date()
    var retries = 0
    var cachedPath: URL?
    var lastFallbackCheck: Date?
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
            if mode == "unwritable", case .readyToInstall(let url) = updater.state,
               lastFallbackCheck != updater.lastChecked {
                lastFallbackCheck = updater.lastChecked
                if let cachedPath, cachedPath != url { print("FAIL: repeated check made another DMG"); exit(1) }
                cachedPath = url
                retries += 1
                if retries == 3 {
                    try! FileManager.default.setAttributes([.posixPermissions: 0o755],
                        ofItemAtPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
                }
                updater.checkForUpdates(userInitiated: false)
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


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


@contextmanager
def fixture_server(dmg):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/latest":
                self.server.checks += 1
                time.sleep(0.3)
                payload = {"tag_name": "v0.21.26", "name": "Flux 0.21.26",
                           "html_url": "https://example.invalid/fixture", "draft": False,
                           "prerelease": False, "assets": [{"name": "Flux.dmg",
                           "browser_download_url": f"http://127.0.0.1:{self.server.server_port}/Flux.dmg"}]}
                body = json.dumps(payload).encode()
            elif self.path == "/Flux.dmg":
                self.server.downloads += 1
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
    server.downloads = 0
    server.checks = 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/latest", server
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
        probe_source = SWIFT_PROBE
        if reference:
            probe_source = probe_source.replace("    UpdateStartup.registerLaunch()\n", "")
            probe_source = probe_source.replace("        UpdateStartup.confirmLaunch()\n", "")
            probe_source = probe_source.replace('        downloadsURL: URL(fileURLWithPath: info["FluxProbeDownloads"] as! String), terminate:', '        terminate:')
        main.write_text(probe_source)
        binary = temporary / "FluxUpdateProbe"
        sources = [str(source), str(main), str(ROOT / "Sources/Flux/Support/Log.swift")]
        if not reference:
            sources += [str(path) for path in sorted((ROOT / "Sources/Flux/Update").glob("*.swift"))
                        if path.name != "UpdateChecker.swift"]
        run(["swiftc", "-swift-version", "5", *sources, "-o", str(binary)], 120)
        for case in cases or ["automatic", "overlap", "manual", "failure", "unwritable"]:
            root = temporary / case
            root.mkdir()
            output = root / "result.txt"
            suite = "com.flux.update-probe." + str(uuid.uuid4())
            install_parent = root / "installed"
            install_parent.mkdir()
            dest = install_parent / "Flux 'installed.app"
            candidate = root / "volume" / "Flux.app"
            dmg = root / "fixture.dmg"
            candidate.parent.mkdir()
            downloads = root / "Downloads"
            downloads.mkdir()
            with fixture_server(dmg) as (endpoint, fixture):
                info = {"CFBundleIdentifier": suite, "CFBundleExecutable": "FluxUpdateProbe",
                        "CFBundleName": "FluxUpdateProbe", "CFBundlePackageType": "APPL",
                        "LSUIElement": True, "FluxProbeOutput": str(output),
                        "FluxProbeDownloads": str(downloads), "FluxProbeSuite": suite + ".preferences", "FluxProbeCase": case, "FluxProbeRelease": endpoint,
                        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
                for app, version in [(dest, "0.21.25"), (candidate, "0.21.26")]:
                    contents = app / "Contents"
                    (contents / "MacOS").mkdir(parents=True)
                    run(["/usr/bin/ditto", str(binary), str(contents / "MacOS/FluxUpdateProbe")], 20)
                    info["CFBundleShortVersionString"] = version
                    with (contents / "Info.plist").open("wb") as stream:
                        plistlib.dump(info, stream)
                    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], 20)
                if not reference and case == "automatic":
                    token = str(uuid.uuid4())
                    workspace = Path(tempfile.gettempdir()) / ("flux-update-" + token)
                    outside = root / "outside" / workspace.name
                    outside.mkdir(parents=True)
                    sentinel = outside / "startup"
                    sentinel.write_text("preserve")
                    workspace.symlink_to(outside, target_is_directory=True)
                    try:
                        run([str(candidate / "Contents/MacOS/FluxUpdateProbe"),
                             "--flux-update-token", token, "--flux-update-receipt", str(workspace / "startup")], 8)
                        assert sentinel.read_text() == "preserve", "FAIL: startup receipt escaped its workspace"
                        print("PASS: native startup receipt rejects a workspace symlink", flush=True)
                    finally:
                        workspace.unlink(missing_ok=True)
                        output.unlink(missing_ok=True)
                if case == "failure":
                    dmg.write_bytes(b"This fixture is not a disk image.")
                else:
                    run(["/usr/bin/hdiutil", "create", "-srcfolder", str(candidate.parent),
                         "-format", "UDZO", "-volname", "FluxUpdateProbe", str(dmg)], 60)
                initial = (dest / "Contents/MacOS/FluxUpdateProbe").read_bytes()
                if case == "unwritable": install_parent.chmod(0o555)
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
                        assert output.read_text() == "version=0.21.26 settings=unchanged", output.read_text()
                        assert not list(install_parent.glob(".Flux-backup-*.app")), "FAIL: native helper did not confirm startup"
                        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dest)], 20)
                    if case == "unwritable":
                        assert len(list(downloads.glob("*.dmg"))) <= 1, "FAIL: duplicate fallback DMGs"
                        assert fixture.downloads == 1, "FAIL: repeated checks downloaded the same release again"
                        assert fixture.checks == 4, "FAIL: did not finish three unwritable checks and one writable retry"
                    print(f"PASS: public updater {case}, {output.read_text()}", flush=True)
                finally:
                    install_parent.chmod(0o755)
                    run(["/usr/bin/defaults", "delete", suite + ".preferences"], 10, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shell-only", action="store_true")
    parser.add_argument("--supervisor-only", action="store_true")
    parser.add_argument("--helper-only", action="store_true")
    parser.add_argument("--baseline-ref")
    parser.add_argument("--case", choices=["automatic", "overlap", "manual", "failure", "unwritable"])
    args = parser.parse_args()
    if args.supervisor_only:
        supervisor_probe(args.baseline_ref)
        supervisor_probe(args.baseline_ref, leader_exits=True)
    elif args.helper_only:
        shell_probe(args.baseline_ref)
    elif args.shell_only:
        supervisor_probe(args.baseline_ref)
        supervisor_probe(args.baseline_ref, leader_exits=True)
        shell_probe(args.baseline_ref)
    else:
        mac_probe(args.baseline_ref, [args.case] if args.case else None)
        supervisor_probe(args.baseline_ref)
        supervisor_probe(args.baseline_ref, leader_exits=True)
        shell_probe(args.baseline_ref)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError) as error:
        print(error, file=sys.stderr, flush=True)
        raise SystemExit(1)

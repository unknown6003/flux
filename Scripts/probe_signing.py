#!/usr/bin/env python3
"""Check whether a self-signed identity keeps a real GUI Accessibility grant."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from probe_tcc import accessibility_grant


def run(command, seconds=60, check=True):
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate(timeout=5)
        raise RuntimeError(f"{Path(command[0]).name} reached its {seconds}s deadline")
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
        raise
    if check and process.returncode != 0:
        raise RuntimeError(
            f"{Path(command[0]).name} failed with exit {process.returncode}:\n{output[-3000:]}"
        )
    return subprocess.CompletedProcess(command, process.returncode, output)


GUI_SOURCE = r'''
import AppKit
import ApplicationServices

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try String(getpid()).write(to: output.appendingPathExtension("pid"),
                          atomically: true, encoding: .utf8)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 28)
item.button?.title = "P"
let deadline = Date().addingTimeInterval(4)

func report() {
    let trusted = AXIsProcessTrusted()
    if !trusted && Date() < deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: report)
        return
    }
    let result: [String: Any] = [
        "build": "BUILD_MARKER",
        "trusted": trusted,
        "pid": getpid(),
        "bundleID": Bundle.main.bundleIdentifier ?? "",
        "bundlePath": Bundle.main.bundleURL.path,
        "registeredPath": NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")?.path ?? "",
    ]
    do {
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: output, options: .atomic)
    } catch {
        fputs("Could not write signing probe result\n", stderr)
        exit(2)
    }
    app.terminate(nil)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: report)
app.run()
'''


REQUIREMENT_SOURCE = r'''
#import <Foundation/Foundation.h>
#import <Security/Security.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        NSURL *app = [NSURL fileURLWithPath:@(argv[2])];
        SecStaticCodeRef code = NULL;
        SecRequirementRef requirement = NULL;
        CFDataRef data = NULL;
        CFStringRef text = NULL;
        OSStatus status = SecStaticCodeCreateWithPath(
            (__bridge CFURLRef)app, kSecCSDefaultFlags, &code);
        if (status == errSecSuccess && strcmp(argv[1], "check") == 0) {
            NSData *bytes = [NSData dataWithContentsOfFile:@(argv[3])];
            if (!bytes) return 2;
            status = SecRequirementCreateWithData(
                (__bridge CFDataRef)bytes, kSecCSDefaultFlags, &requirement);
            if (status == errSecSuccess)
                status = SecStaticCodeCheckValidity(code,
                    kSecCSStrictValidate | kSecCSCheckAllArchitectures, requirement);
        } else if (status == errSecSuccess && strcmp(argv[1], "export") == 0) {
            status = SecCodeCopyDesignatedRequirement(
                (SecCodeRef)code, kSecCSDefaultFlags, &requirement);
            if (status == errSecSuccess)
                status = SecRequirementCopyData(requirement, kSecCSDefaultFlags, &data);
            if (status == errSecSuccess && ![(__bridge NSData *)data
                    writeToFile:@(argv[3]) atomically:YES]) status = errSecIO;
            if (status == errSecSuccess)
                status = SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text);
            if (status == errSecSuccess)
                printf("%s\n", [(__bridge NSString *)text UTF8String]);
        } else if (status == errSecSuccess) {
            status = errSecParam;
        }
        if (text) CFRelease(text);
        if (data) CFRelease(data);
        if (requirement) CFRelease(requirement);
        if (code) CFRelease(code);
        if (status != errSecSuccess) {
            fprintf(stderr, "Requirement operation failed: %d\n", (int)status);
            return 1;
        }
        return 0;
    }
}
'''


def stop_owned_app(app_path):
    executable = str(app_path / "Contents/MacOS/FluxSigningProbe")
    processes = run(["/bin/ps", "-axo", "pid=,comm="], seconds=10).stdout
    owned = []
    for line in processes.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and parts[1] == executable:
            owned.append(int(parts[0]))
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            current = run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                          seconds=10, check=False).stdout.strip()
            if current == executable:
                os.kill(pid, signal.SIGKILL)


def build_app(work, marker, bundle_id, swiftc, sdk):
    source = work / f"main-{marker}.swift"
    source.write_text(GUI_SOURCE.replace("BUILD_MARKER", marker))
    app = work / f"build-{marker}/FluxSigningProbe.app"
    binary = app / "Contents/MacOS/FluxSigningProbe"
    binary.parent.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "FluxSigningProbe",
        "CFBundleName": "Flux signing probe",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(ord(marker) - ord("A") + 1),
        "CFBundleShortVersionString": f"0.0.{ord(marker) - ord('A') + 1}",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run([swiftc, "-sdk", sdk, str(source), "-o", str(binary)], seconds=120)
    return app


def code_hash(app):
    output = run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)], seconds=30).stdout
    match = re.search(r"^CDHash=([0-9a-f]+)$", output, re.MULTILINE)
    if not match:
        raise RuntimeError("codesign did not return a code hash")
    return match.group(1)


def install_and_launch(source, app, bundle_id, result_path, lsregister):
    stop_owned_app(app)
    if app.exists():
        run(["sudo", "-n", "/bin/rm", "-rf", "--", str(app)], seconds=30)
    run(["sudo", "-n", "/usr/bin/ditto", str(source), str(app)], seconds=60)
    run([lsregister, "-f", str(app)], seconds=30)
    run(["/usr/bin/open", "-n", "-g", "-W", str(app), "--args", str(result_path)],
        seconds=20)
    if not result_path.is_file():
        raise RuntimeError("the GUI app exited without reporting its Accessibility access")
    result = json.loads(result_path.read_text())
    if result.get("bundleID") != bundle_id or result.get("bundlePath") != str(app):
        raise RuntimeError("the GUI launch ran a different bundle or app location")
    if result.get("registeredPath") != str(app):
        raise RuntimeError("Launch Services registered a different app location")
    print(f"Build {result['build']}: GUI Accessibility trusted={result['trusted']}", flush=True)
    return result


def main():
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("this probe runs only on a disposable macOS GitHub Actions desktop")
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/signing-probe"))
    args = parser.parse_args()
    version = run(["/usr/bin/sw_vers", "-productVersion"], seconds=10).stdout.strip()
    if int(version.split(".")[0]) < 27:
        raise RuntimeError("this probe needs macOS 27 or newer")
    print(f"Signing probe OS: {version}", flush=True)
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    unique = uuid.uuid4().hex
    bundle_id = f"com.flux.signing-probe.{unique}"
    app = Path(f"/Applications/FluxSigningProbe-{unique}.app")
    if app.exists():
        raise RuntimeError("the probe app path already exists; refusing to replace it")
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    keychain_created = False
    installed = False
    with tempfile.TemporaryDirectory(prefix="flux-signing-probe-") as directory:
        work = Path(directory)
        keychain = work / "probe.keychain-db"
        password = secrets.token_urlsafe(24)
        identity = "Flux disposable signing probe " + unique
        try:
            config = work / "certificate.cnf"
            config.write_text(
                "[req]\nprompt = no\ndistinguished_name = subject\nx509_extensions = signing\n"
                f"[subject]\nCN = {identity}\n"
                "[signing]\nbasicConstraints = critical,CA:FALSE\n"
                "keyUsage = critical,digitalSignature\nextendedKeyUsage = codeSigning\n"
            )
            run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "2",
                 "-nodes", "-config", str(config), "-keyout", str(work / "private.pem"),
                 "-out", str(work / "certificate.pem")], seconds=60)
            run(["openssl", "pkcs12", "-export", "-inkey", str(work / "private.pem"),
                 "-in", str(work / "certificate.pem"), "-out", str(work / "identity.p12"),
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                 "-passout", "pass:" + password], seconds=30)
            run(["/usr/bin/security", "create-keychain", "-p", password, str(keychain)], seconds=30)
            keychain_created = True
            run(["/usr/bin/security", "set-keychain-settings", "-lut", "1800", str(keychain)], seconds=30)
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)], seconds=30)
            run(["/usr/bin/security", "import", str(work / "identity.p12"), "-k", str(keychain),
                 "-P", password, "-T", "/usr/bin/codesign"], seconds=30)
            run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:",
                 "-s", "-k", password, str(keychain)], seconds=30)
            swiftc = run(["/usr/bin/xcrun", "--find", "swiftc"], seconds=30).stdout.strip()
            clang = run(["/usr/bin/xcrun", "--find", "clang"], seconds=30).stdout.strip()
            sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], seconds=30).stdout.strip()
            requirement_source = work / "requirement.m"
            requirement_source.write_text(REQUIREMENT_SOURCE)
            requirement_tool = work / "requirement"
            run([clang, "-isysroot", sdk, "-fobjc-arc", str(requirement_source), "-framework", "Foundation",
                 "-framework", "Security", "-o", str(requirement_tool)], seconds=60)
            apps = {marker: build_app(work, marker, bundle_id, swiftc, sdk) for marker in ("A", "B", "C")}
            for marker, candidate in apps.items():
                command = ["/usr/bin/codesign", "--force", "--timestamp=none", "--sign"]
                command += ["-"] if marker == "C" else [identity, "--keychain", str(keychain)]
                run(command + [str(candidate)], seconds=60)
                run(["/usr/bin/codesign", "--verify", "--strict", str(candidate)], seconds=30)
            hashes = {marker: code_hash(candidate) for marker, candidate in apps.items()}
            if len(set(hashes.values())) != 3:
                raise RuntimeError("the probe builds did not have distinct code hashes")
            requirement_blob = work / "A.requirement"
            requirement_text = run([str(requirement_tool), "export", str(apps["A"]),
                                    str(requirement_blob)], seconds=30).stdout.strip()
            (output / "A.requirement.txt").write_text(requirement_text + "\n")
            requirement = requirement_blob.read_bytes()
            if not requirement:
                raise RuntimeError("build A returned an empty designated requirement")
            run([str(requirement_tool), "check", str(apps["B"]), str(requirement_blob)], seconds=30)
            negative = run([str(requirement_tool), "check", str(apps["C"]), str(requirement_blob)],
                           seconds=30, check=False)
            if negative.returncode == 0:
                raise RuntimeError("the ad-hoc control incorrectly satisfied build A's requirement")
            print("Build B satisfies A's requirement; ad-hoc build C does not.", flush=True)
            print(f"Code hashes differ: A={hashes['A']}, B={hashes['B']}, C={hashes['C']}", flush=True)
            results = {}
            with accessibility_grant(bundle_id, csreq=requirement):
                try:
                    for marker in ("A", "B", "C"):
                        installed = True
                        result = install_and_launch(apps[marker], app, bundle_id,
                                                    output / f"build-{marker}.json", lsregister)
                        results[marker] = result
                        if result.get("build") != marker:
                            raise RuntimeError("Launch Services ran the previous build")
                        if result.get("trusted") != (marker != "C"):
                            raise RuntimeError(f"build {marker} did not return the expected Accessibility access")
                finally:
                    stop_owned_app(app)
            (output / "summary.json").write_text(json.dumps({
                "os": version, "hashes": hashes,
                "requirementBytes": len(requirement), "results": results,
            }, indent=2) + "\n")
        finally:
            failures = []
            actions = [lambda: stop_owned_app(app)]
            if installed:
                actions += [
                    lambda: run([lsregister, "-u", str(app)], seconds=30),
                    lambda: run(["sudo", "-n", "/bin/rm", "-rf", "--", str(app)], seconds=30),
                ]
            if keychain_created:
                actions.append(lambda: run(["/usr/bin/security", "delete-keychain", str(keychain)], seconds=30))
            for action in actions:
                try:
                    action()
                except Exception as error:
                    failures.append(str(error))
            if failures:
                raise RuntimeError("Signing probe cleanup failed: " + "; ".join(failures))
    print("PASS: changed self-signed builds kept GUI Accessibility access; ad-hoc control lost it.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)

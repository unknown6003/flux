#!/usr/bin/env python3
"""Run the real private assessment policy with a headless fake OS backend on macOS."""

import argparse
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Sources/Flux/MenuBar/MacOS27Hider.swift"


def command(arguments, seconds, capture=False):
    process = subprocess.Popen(arguments, cwd=ROOT, start_new_session=True,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.PIPE if capture else None, text=True)
    try:
        output, error = process.communicate(timeout=seconds)
        if process.returncode:
            raise RuntimeError(f"{arguments[0]} exited {process.returncode}\n"
                               f"{output or ''}{error or ''}")
        return output
    finally:
        # Stop the whole group, including children, on timeout or interruption.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def policy(source):
    start = source.index("@objc private protocol MenuBarAssessmentAssertion")
    end = source.index("\n@MainActor\nfinal class MacOS27Hider", start)
    original = source[start:end]
    init_start = original.index("    init() {")
    init_end = original.index("\n    var isAvailable:", init_start)
    resolver = original[init_start:init_end]
    if "dlopen(" not in resolver or "classes = (assertion, configuration)" not in resolver:
        raise RuntimeError("framework resolver changed; inspect the test boundary")
    replacement = "    init() {\n        classes = (FakeAssertion.self, FakeConfiguration.self)\n    }\n"
    result = original[:init_start] + replacement + original[init_end:]
    if any(token in result for token in ("dlopen(", "NSClassFromString(", "NSApp", "NSWorkspace")):
        raise RuntimeError("unexpected OS access in extracted policy")
    print("Policy SHA256:", hashlib.sha256(original.encode()).hexdigest(), flush=True)
    return "import Foundation\nimport os\n" + result + FIXTURE


FIXTURE = r'''
private enum Log {
    static let menuBar = Logger(subsystem: "com.flux.assessment-probe", category: "test")
}

@objc(FluxProbeAssessmentConfiguration)
private final class FakeConfiguration: NSObject {
    static var fail = false
    let bundleIDs: [String]

    @objc(initWithAllowedSystemItems:allowedBundleIdentifiers:)
    init?(allowedSystemItems: NSArray, allowedBundleIdentifiers: NSArray) {
        bundleIDs = allowedBundleIdentifiers as! [String]
        super.init()
        if Self.fail { return nil }
    }
}

@objc(FluxProbeAssessmentAssertion)
private final class FakeAssertion: NSObject, MenuBarAssessmentAssertion {
    static var created: [FakeAssertion] = []
    var invalidations = 0
    var bundleIDs: [String] = []
    var completion: ((NSError?) -> Void)?

    override init() {
        super.init()
        Self.created.append(self)
    }

    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void) {
        bundleIDs = (configuration as! FakeConfiguration).bundleIDs
        completion = completionHandler
    }

    func invalidate() { invalidations += 1 }
    func complete(_ error: NSError? = nil) { completion?(error) }
}

@MainActor private var failures = 0
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor private func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private let backendError = NSError(domain: "FluxProbe", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "fake backend refusal"])

@MainActor private func staleCompletion(error: NSError?) async {
    FakeAssertion.created = []
    let assessment = MenuBarAssessment()
    var statuses: [String?] = []
    assessment.onStatus = { statuses.append($0) }
    let label = error == nil ? "stale success" : "stale error"
    assessment.restrict(to: ["A"])
    let a = FakeAssertion.created[0]
    a.complete()
    await drainMainQueue()
    check(assessment.allowed == ["A"], "\(label): establish active A")
    assessment.restrict(to: ["B"])
    let b = FakeAssertion.created[1]
    check(!assessment.permitsPositionRead(for: "A"), "\(label): pending B blocks reads")
    assessment.restrict(to: ["A"])
    check(assessment.allowed == ["A"], "\(label): return to active A")
    check(a.invalidations == 0, "\(label): original A remains alive")
    check(b.invalidations == 1, "\(label): cancel B immediately")
    check(assessment.permitsPositionRead(for: "A"), "\(label): pending read barrier cleared")
    check(!assessment.permitsPositionRead(for: "B"), "\(label): A still excludes B")
    let count = statuses.count
    b.complete(error)
    await drainMainQueue()
    check(assessment.allowed == ["A"], "\(label): late B completion must not install B")
    check(a.invalidations == 0, "\(label): late B completion must not invalidate original A")
    check(b.invalidations == 1, "\(label): stale callback does not invalidate twice")
    check(statuses.count == count, "\(label): stale callback does not publish status")
    check(assessment.permitsPositionRead(for: "A"), "\(label): A readable after completion")
    check(FakeAssertion.created.count == 2, "\(label): unchanged A creates no assertion")
    assessment.release()
    check(assessment.allowed == nil && !assessment.isRestricting, "\(label): release clears state")
    check(a.invalidations == 1 && b.invalidations == 1, "\(label): release invalidates each once")
}

@MainActor private func failureAndReplacement() async {
    FakeAssertion.created = []
    let assessment = MenuBarAssessment()
    var statuses: [String?] = []
    assessment.onStatus = { statuses.append($0) }
    assessment.restrict(to: ["A"])
    let a = FakeAssertion.created[0]
    a.complete()
    await drainMainQueue()
    assessment.restrict(to: ["B"])
    let b = FakeAssertion.created[1]
    FakeConfiguration.fail = true
    assessment.restrict(to: ["C"])
    FakeConfiguration.fail = false
    check(a.invalidations == 0 && b.invalidations == 0,
          "configuration failure preserves active A and pending B")
    check(assessment.allowed == ["A"] && !assessment.permitsPositionRead(for: "A"),
          "configuration failure preserves pending read barrier")
    check(statuses.last! == "MenuBarAgent could not set up hiding.", "configuration failure status")
    b.complete(backendError)
    await drainMainQueue()
    check(assessment.allowed == ["A"] && a.invalidations == 0 && b.invalidations == 1,
          "activation failure preserves active A and invalidates B")
    check(assessment.permitsPositionRead(for: "A"), "activation failure clears pending read barrier")
    check(statuses.last! == "MenuBarAgent refused hiding: fake backend refusal", "activation failure status")
    assessment.restrict(to: ["C"])
    let c = FakeAssertion.created[2]
    c.complete()
    await drainMainQueue()
    check(assessment.allowed == ["C"] && a.invalidations == 1 && c.invalidations == 0,
          "successful replacement invalidates A and installs C")
    assessment.restrict(to: ["D"])
    let d = FakeAssertion.created[3]
    assessment.release()
    let count = statuses.count
    d.complete()
    await drainMainQueue()
    check(assessment.allowed == nil && !assessment.isRestricting,
          "release rejects late pending completion")
    check(statuses.count == count, "released completion does not publish status")
    check(FakeAssertion.created.allSatisfy { $0.invalidations == 1 },
          "release cleans up every assertion once")
}

Task { @MainActor in
    await staleCompletion(error: nil)
    await staleCompletion(error: backendError)
    await failureAndReplacement()
    if failures > 0 {
        print("FAIL: \(failures) assessment policy checks")
        exit(1)
    }
    print("PASS: assessment cancellation, stale success/error, failures and release")
    exit(0)
}
dispatchMain()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="Read policy source from this exact git commit")
    parser.add_argument("--emit-source", type=Path, help="Write the native fixture without compiling")
    args = parser.parse_args()
    source = (command(["git", "show", f"{args.baseline_ref}:{SOURCE}"], 10, capture=True)
              if args.baseline_ref else (ROOT / SOURCE).read_text())
    fixture = policy(source)
    if args.emit_source:
        args.emit_source.write_text(fixture)
        return
    if sys.platform != "darwin":
        raise RuntimeError("native macOS Swift is required; Linux cannot validate this fixture")
    with tempfile.TemporaryDirectory(prefix="flux-assessment-") as temporary:
        path = Path(temporary)
        (path / "main.swift").write_text(fixture)
        command(["xcrun", "swiftc", "-swift-version", "5", str(path / "main.swift"),
                 "-o", str(path / "probe")], 90)
        command([str(path / "probe")], 15)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        raise SystemExit(f"FAIL: {error}")

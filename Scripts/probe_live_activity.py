#!/usr/bin/env python3
"""Check that a real macOS Live Activity appears in Flux's icon list."""

import argparse
from pathlib import Path
import plistlib
import sys
import tempfile
import uuid

from probe_hidden_transition import run


FIXTURE = r'''
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let agent = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.MenuBarAgent").first else {
        print("SETUP FAIL: MenuBarAgent is not running")
        exit(2)
    }
    let owner = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(owner, 0.2)
    var pills: [CGRect] = []
    var visited = 0
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 6, visited < 100 else { return }
        visited += 1
        if let id = attribute(element, kAXIdentifierAttribute) as? String,
           id.hasPrefix("live-activity-pill-"),
           let position = attribute(element, kAXPositionAttribute),
           let size = attribute(element, kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(),
           CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point),
               AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                pills.append(CGRect(origin: point, size: dimensions))
                print("VISIBLE_ACTIVITY_CONTROL \(id) \(pills.last!)")
            }
            return
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth: depth + 1)
        }
    }
    for name in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute] {
        if let root = attribute(owner, name), CFGetTypeID(root) == AXUIElementGetTypeID() {
            walk(root as! AXUIElement, depth: 0)
        }
    }
    guard !pills.isEmpty else {
        print("SETUP FAIL: no readable Live Activity is present")
        exit(2)
    }
    let manager = MenuBarIconManager(trustProvider: { true })
    manager.refresh()
    for icon in manager.icons {
        print("ICON \(icon.title) | \(icon.source ?? "") | movable=\(icon.isMovable) | \(icon.frame)")
    }
    if CommandLine.arguments.contains("--titles-only") {
        guard !manager.icons.isEmpty, manager.icons.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            print("FAIL: Flux displayed an empty icon title instead of its app name")
            exit(1)
        }
        print("PASS: every icon has a readable title")
        exit(0)
    }
    guard pills.allSatisfy({ pill in manager.icons.contains {
        !$0.isMovable && $0.frame.intersects(pill) && ($0.source?.contains("Live Activity") ?? false)
    } }) else {
        print("FAIL: Flux omitted a readable macOS Live Activity from its management list")
        exit(1)
    }
    print("PASS: real Live Activities appear in the public icon list as system managed")
}
'''


def main():
    if sys.platform != "darwin":
        raise RuntimeError("the activity probe needs a macOS desktop with a Live Activity")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    parser.add_argument("--titles-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manager_path = "Sources/Flux/MenuBar/MenuBarIconManager.swift"
    manager = (run(["git", "show", f"{args.baseline_ref}:{manager_path}"], 15, capture=True)
               if args.baseline_ref else (root / manager_path).read_text())
    with tempfile.TemporaryDirectory(prefix="flux-live-activity-probe-") as directory:
        temporary = Path(directory)
        bundle = temporary / "FluxActivityProbe.app"
        binary = bundle / "Contents/MacOS/FluxActivityProbe"
        binary.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.flux.activity-probe." + uuid.uuid4().hex,
            "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }))
        (temporary / "Manager.swift").write_text(manager)
        (temporary / "main.swift").write_text(FIXTURE)
        dependencies = ["MenuBar/MacOS27Hider.swift", "MenuBar/ControlItem.swift",
                        "MenuBar/MenuBarSection.swift", "MenuBar/MenuBarIconStyle.swift",
                        "MenuBar/MenuBarGeometry.swift", "Support/Theme.swift",
                        "Support/Log.swift", "Support/AccessibilityAccess.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", str(temporary / "main.swift"),
             str(temporary / "Manager.swift"),
             *[str(root / "Sources/Flux" / path) for path in dependencies],
             "-o", str(binary)], 120)
        run(["codesign", "--force", "--sign", "-", str(bundle)], 20)
        run([str(binary)] + (["--titles-only"] if args.titles_only else []), 30)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

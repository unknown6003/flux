import AppKit
import ScreenCaptureKit
import Vision

/// A finite fixture, never the product app. It touches only its three status
/// items and private output files. No preferences, event posting or AX calls.
@main struct MenuBarLayoutProbe {
    @MainActor static func main() async {
        do {
            try await run()
            exit(0)
        } catch {
            // OS descriptions and OCR text can contain unrelated user content.
            print("Layout probe failed. Inspect its private receipt and images.")
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        guard ProcessInfo.processInfo.environment["FLUX_ALLOW_MENU_LAYOUT_PROBE"] == "1",
              Bundle.main.bundleIdentifier == "com.flux.menubar",
              Bundle.main.object(forInfoDictionaryKey: "FluxLayoutProbeOnly") as? Bool == true,
              CommandLine.arguments.count == 2,
              #available(macOS 26.0, *) else { throw Failure.guardRequired }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directory.path.hasPrefix(temporary),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
              CGPreflightScreenCaptureAccess() else { throw Failure.preflight }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              screen.frame.width <= 2048, screen.frame.width >= 800 else { throw Failure.display }
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let region = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 34)
        let statusBar = NSStatusBar.system
        // New items are created from right to left. Names are not autosaved,
        // so this fixture never overwrites the product's preferred positions.
        let right = statusBar.statusItem(withLength: 44)
        let spacer = statusBar.statusItem(withLength: 8)
        let left = statusBar.statusItem(withLength: 44)
        defer {
            spacer.length = 8
            for item in [left, spacer, right] { statusBar.removeStatusItem(item) }
        }
        right.button?.title = "FX-R"
        spacer.button?.title = "|"
        left.button?.title = "FX-L"
        var states: [[String: Any]] = []
        let inspector = FixtureGlyphs()

        func saveReceipt(passed: Bool) throws {
            let receipt: [String: Any] = [
                "probeOnly": true, "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "FluxProbeSourceRevision") as? String ?? "unknown",
                "startedFromApplications": Bundle.main.bundleURL.path.hasPrefix("/Applications/"),
                "screenFrame": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height],
                "captureRect": [region.minX, region.minY, region.width, region.height],
                "displayID": display, "states": states, "passed": passed,
                "noPreferenceWrites": true, "noPostedInput": true,
            ]
            let url = directory.appendingPathComponent("layout.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        func observe(_ name: String) async throws -> (left: Bool, right: Bool) {
            try await Task.sleep(for: .seconds(2))
            let image = try await SCScreenshotManager.captureImage(in: region)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure.capture }
            let imageURL = directory.appendingPathComponent(name + ".png")
            try data.write(to: imageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
            let glyphs = await inspector.read(data)
            func frame(_ item: NSStatusItem) -> [Double]? {
                guard let frame = item.button?.window?.frame else { return nil }
                return [frame.minX, frame.minY, frame.width, frame.height]
            }
            states.append(["name": name, "capturedAt": ISO8601DateFormatter().string(from: .now),
                           "leftGlyph": glyphs.left, "rightGlyph": glyphs.right,
                           "leftFrame": frame(left).map { $0 as Any } ?? NSNull(),
                           "spacerFrame": frame(spacer).map { $0 as Any } ?? NSNull(),
                           "rightFrame": frame(right).map { $0 as Any } ?? NSNull(), "spacerLength": spacer.length])
            try saveReceipt(passed: false)
            return glyphs
        }

        let baseline = try await observe("baseline")
        guard baseline.left, baseline.right,
              let leftFrame = left.button?.window?.frame, let rightFrame = right.button?.window?.frame,
              leftFrame.width > 0, leftFrame.height > 0, leftFrame.midX < rightFrame.midX else { throw Failure.baseline }
        for cycle in 1...3 {
            spacer.button?.title = ""
            spacer.length = max(1, screen.frame.width / 2 - 20)
            let collapsed = try await observe("collapsed-\(cycle)")
            spacer.length = 8
            spacer.button?.title = "|"
            let restored = try await observe("restored-\(cycle)")
            guard !collapsed.left, collapsed.right, restored.left, restored.right else { throw Failure.visibility }
        }
        try saveReceipt(passed: true)
        print("Three fixture hide/show cycles passed. This does not accept the rebuilt app.")
    }

    private enum Failure: Error { case guardRequired, preflight, display, capture, baseline, visibility }
}

private actor FixtureGlyphs {
    /// Return only the two fixture matches. Never retain or log unrelated OCR.
    func read(_ image: Data) -> (left: Bool, right: Bool) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do { try VNImageRequestHandler(data: image).perform([request]) }
        catch { return (false, false) }
        var left = false, right = false
        for result in request.results ?? [] {
            guard let text = result.topCandidates(1).first?.string else { continue }
            let words = text.uppercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|")))
            for word in words {
                let normalized = word.filter(\.isLetter)
                left = left || normalized == "FXL"
                right = right || normalized == "FXR"
            }
        }
        return (left, right)
    }
}

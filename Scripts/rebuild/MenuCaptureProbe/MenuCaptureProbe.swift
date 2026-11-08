import AppKit
import ScreenCaptureKit

/// Diagnostic only. No app delegate, inventory, settings, services or analytics.
/// The caller supplies an explicit top-band rectangle and an empty private folder.
@main struct MenuCaptureProbe {
    @MainActor private static var journal: URL?

    @MainActor static func main() async {
        do {
            let directory = try prepareJournal()
            try record("started")
            try await capture(into: directory)
            try record("complete")
        }
        catch {
            if let check = error as? ProbeError {
                try? record("failed", failure: String(describing: check))
                print("Capture probe check failed: \(check)")
                exit(1)
            }
            let error = error as NSError
            try? record("failed", failure: "system", code: error.code)
            print("Capture probe failed: \(error.domain) \(error.code)")
            exit(1)
        }
    }

    @MainActor private static func capture(into directory: URL) async throws {
        try record("checking-guard")
        guard ProcessInfo.processInfo.environment["FLUX_ALLOW_MENU_CAPTURE_PROBE"] == "1",
              Bundle.main.bundleIdentifier == "com.flux.menubar" else { throw ProbeError.guardRequired }
        let arguments = CommandLine.arguments
        try record("checking-rectangle")
        guard arguments.count == 6,
              let x = Double(arguments[2]), let y = Double(arguments[3]),
              let width = Double(arguments[4]), let height = Double(arguments[5]),
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, width <= 2048,
              height > 0, height <= 40 else { throw ProbeError.invalidRectangle }
        let region = CGRect(x: x, y: y, width: width, height: height)
        try record("creating-application")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try record("checking-access")
        guard CGPreflightScreenCaptureAccess() else { throw ProbeError.screenCaptureNotAllowed }
        try record("reading-content")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(region) }),
              region.minY >= display.frame.minY,
              region.maxY <= display.frame.minY + 40 else { throw ProbeError.invalidRectangle }
        let bounds = CGDisplayBounds(display.displayID)
        let scale = Double(CGDisplayPixelsWide(display.displayID)) / bounds.width
        guard scale.isFinite, scale >= 1, scale <= 4 else { throw ProbeError.invalidRectangle }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: region.minX - display.frame.minX,
                                          y: region.minY - display.frame.minY,
                                          width: region.width, height: region.height)
        configuration.width = Int(ceil(region.width * scale))
        configuration.height = Int(ceil(region.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 15.0, *) { filter.includeMenuBar = true }
        try record("capturing-filter")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try write(image, to: directory.appendingPathComponent("display-filter.png"))
        var methods = ["display-filter"]
        if #available(macOS 26.0, *) {
            try record("capturing-global")
            let image = try await SCScreenshotManager.captureImage(in: region)
            try write(image, to: directory.appendingPathComponent("global-rect.png"))
            methods.append("global-rect")
        }
        let report: [String: Any] = [
            "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "FluxProbeSourceRevision") as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "probeOnly": true, "preflightAllowed": true,
            "displayID": display.displayID, "scale": scale,
            "globalRect": [region.minX, region.minY, region.width, region.height],
            "displayFrame": [display.frame.minX, display.frame.minY, display.frame.width, display.frame.height],
            "sourceRect": [configuration.sourceRect.minX, configuration.sourceRect.minY, region.width, region.height],
            "pixelSize": [image.width, image.height], "methods": methods,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "visualInspectionRequired": true
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = directory.appendingPathComponent("capture.json")
        try data.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        print("Capture-only probe completed. Inspect the two local images before drawing a visibility conclusion.")
    }

    /// Launch Services does not return stdout. A fixed phase receipt makes an
    /// early guard failure distinguishable from a capture that returned black.
    /// It contains no paths, environment values or desktop content.
    @MainActor private static func prepareJournal() throws -> URL {
        guard Bundle.main.bundleIdentifier == "com.flux.menubar",
              Bundle.main.object(forInfoDictionaryKey: "FluxProbeOnly") as? Bool == true,
              CommandLine.arguments.count >= 2 else { throw ProbeError.guardRequired }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard directory.path.hasPrefix(temporary) else { throw ProbeError.privateDirectoryRequired }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw ProbeError.privateDirectoryRequired
        }
        journal = directory.appendingPathComponent("probe-state.json")
        return directory
    }

    @MainActor private static func record(_ phase: String, failure: String? = nil, code: Int? = nil) throws {
        guard let journal else { return }
        var state: [String: Any] = [
            "phase": phase, "argumentCount": CommandLine.arguments.count,
            "allowFlagPresent": ProcessInfo.processInfo.environment["FLUX_ALLOW_MENU_CAPTURE_PROBE"] == "1",
            "processID": getpid(), "at": ISO8601DateFormatter().string(from: Date())
        ]
        if let failure { state["failure"] = failure }
        if let code { state["code"] = code }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    @MainActor private static func write(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ProbeError.encodingFailed }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private enum ProbeError: Error {
        case guardRequired, invalidRectangle, privateDirectoryRequired, screenCaptureNotAllowed, encodingFailed
    }
}

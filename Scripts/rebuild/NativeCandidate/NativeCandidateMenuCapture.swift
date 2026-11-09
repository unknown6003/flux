import AppKit
import Darwin
@preconcurrency import ScreenCaptureKit

/// Test-only observation in the actual signed app and its TCC identity.
/// Explicit --capture-menu-dir enables at most twelve SIGUSR1 captures of
/// the top menu strip. It creates no stream, grants, polling or UI input.
@MainActor final class NativeCandidateMenuCapture {
    private let output: URL
    private var signalSource: (any DispatchSourceSignal)?
    private var task: Task<Void, Never>?
    private var active = true
    private var sequence = 0

    init(output: URL) throws {
        let directory = output.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard directory.path.hasPrefix(temporary.path + "/"),
              lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CaptureError.output
        }
        self.output = directory
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.capture() } }
        signalSource = source
        source.resume()
    }

    func stop() {
        active = false
        task?.cancel(); task = nil
        signalSource?.cancel(); signalSource = nil
    }

    private enum CaptureError: String, Error { case output, permission, display, pixels }

    private func capture() {
        guard active, task == nil, sequence < 12 else { return }
        sequence += 1
        let number = sequence
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var diagnostic: [String: Any] = [:]
            do {
                guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permission }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard self.active, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    throw CaptureError.display
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                let scale = CGFloat(filter.pointPixelScale)
                let height: CGFloat = 34
                let width = display.frame.size.width
                guard width.isFinite, width > 0, width <= 16_384, scale.isFinite, scale >= 1, scale <= 4,
                      width * height * scale * scale <= 4_194_304 else { throw CaptureError.display }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(x: 0, y: 0, width: width, height: height)
                configuration.width = Int(ceil(width * scale))
                configuration.height = Int(ceil(height * scale))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                diagnostic = ["displayID": display.displayID,
                    "globalRect": [display.frame.minX, display.frame.minY, width, height],
                    "expectedPixelSize": [configuration.width, configuration.height]]
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                diagnostic["returnedPixelSize"] = [image.width, image.height]
                try Task.checkCancellation()
                guard self.active, image.width == configuration.width, image.height == configuration.height,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      png.count <= 8 * 1024 * 1024 else { throw CaptureError.pixels }
                let name = String(format: "menu-%03d.png", number)
                try png.write(to: self.output.appendingPathComponent(name), options: .withoutOverwriting)
                try self.receipt(number, phase: "captured", additional: ["image": name,
                    "displayID": display.displayID,
                    "globalRect": [display.frame.minX, display.frame.minY, width, height],
                    "pixelSize": [image.width, image.height]])
            } catch {
                guard self.active, !Task.isCancelled else { return }
                let phase = (error as? CaptureError) == .permission ? "screenCaptureNotAllowed" : "captureFailed"
                diagnostic["failure"] = (error as? CaptureError)?.rawValue ?? "system"
                try? self.receipt(number, phase: phase, additional: diagnostic)
            }
        }
    }

    private func receipt(_ number: Int, phase: String, additional: [String: Any]) throws {
        var value = additional
        value["phase"] = phase
        value["at"] = Date().ISO8601Format()
        value["processID"] = getpid()
        value["source"] = Bundle.main.object(forInfoDictionaryKey: "FluxNativeSourceRevision")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: output.appendingPathComponent(String(format: "receipt-%03d.json", number)), options: .withoutOverwriting)
    }
}

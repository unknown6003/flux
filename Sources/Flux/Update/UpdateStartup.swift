import Foundation

/// The update helper keeps the old app until this launch completes startup.
enum UpdateStartup {
    private static var receipt: URL?
    private static var token: String?

    static func registerLaunch() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--flux-update-token"), index + 1 < arguments.count,
              let pathIndex = arguments.firstIndex(of: "--flux-update-receipt"), pathIndex + 1 < arguments.count,
              UUID(uuidString: arguments[index + 1]) != nil else { return }
        let path = URL(fileURLWithPath: arguments[pathIndex + 1])
        let expected = "flux-update-" + arguments[index + 1]
        guard path.lastPathComponent == "startup", path.deletingLastPathComponent().lastPathComponent == expected,
              path.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
                == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return }
        receipt = path
        token = arguments[index + 1]
        write("started")
    }

    static func confirmLaunch() { write("ready") }

    private static func write(_ state: String) {
        guard let receipt, let token else { return }
        let value = "\(token)\n\(ProcessInfo.processInfo.processIdentifier)\n\(Bundle.main.bundleURL.path)\n\(state)\n"
        do { try value.write(to: receipt, atomically: true, encoding: .utf8) }
        catch { Log.menuBar.error("Couldn't confirm update startup: \(error.localizedDescription)") }
    }
}

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
        let workspace = path.deletingLastPathComponent().resolvingSymlinksInPath()
        guard path.lastPathComponent == "startup", workspace.lastPathComponent == expected,
              workspace.deletingLastPathComponent()
                == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return }
        receipt = workspace.appendingPathComponent("startup")
        token = arguments[index + 1]
        write("started")
    }

    static func confirmLaunch() { write("ready") }

    private static func write(_ state: String) {
        guard let receipt, let token else { return }
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let value = "\(token)\n\(ProcessInfo.processInfo.processIdentifier)\n\(bundlePath)\n\(state)\n"
        do { try value.write(to: receipt, atomically: true, encoding: .utf8) }
        catch { Log.menuBar.error("Couldn't confirm update startup: \(error.localizedDescription)") }
    }
}

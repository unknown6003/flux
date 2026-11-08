import Darwin
import Foundation

public enum StartupPhase: String, Sendable {
    case started, ready
}

public enum StartupReceiptError: Error {
    case invalidProcess, invalidBundlePath, unsafeWorkspace
}

/// Compatible with the four-line receipt read by Flux 0.21.35's installer.
public struct UpdateLaunch: Sendable {
    public let token: String
    public let receiptURL: URL

    public init?(arguments: [String], temporaryDirectory: URL) {
        func argument(_ flag: String) -> String? {
            let matches = arguments.indices.filter { arguments[$0] == flag }
            guard matches.count == 1, let index = matches.first,
                  index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let token = argument("--flux-update-token"),
              UUID(uuidString: token) != nil,
              let path = argument("--flux-update-receipt"),
              path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
        else { return nil }
        let input = URL(fileURLWithPath: path)
        let workspace = input.deletingLastPathComponent().resolvingSymlinksInPath()
        guard input.lastPathComponent == "startup",
              workspace.lastPathComponent == "flux-update-" + token,
              workspace.deletingLastPathComponent() == temporaryDirectory.resolvingSymlinksInPath()
        else { return nil }
        self.token = token
        receiptURL = workspace.appendingPathComponent("startup")
    }

    public func receipt(phase: StartupPhase, processIdentifier: Int32, bundleURL: URL) throws -> Data {
        guard processIdentifier > 1 else { throw StartupReceiptError.invalidProcess }
        let path = bundleURL.resolvingSymlinksInPath().path
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app",
              !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
        else { throw StartupReceiptError.invalidBundlePath }
        return Data("\(token)\n\(processIdentifier)\n\(path)\n\(phase.rawValue)\n".utf8)
    }

    /// No network, feature setup, analytics or UI work belongs before the started receipt.
    public func write(phase: StartupPhase, processIdentifier: Int32, bundleURL: URL) throws {
        let manager = FileManager.default
        let directory = receiptURL.deletingLastPathComponent()
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else { throw StartupReceiptError.unsafeWorkspace }
        if let existing = try? manager.attributesOfItem(atPath: receiptURL.path) {
            guard existing[.type] as? FileAttributeType == .typeRegular,
                  (existing[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { throw StartupReceiptError.unsafeWorkspace }
        }
        let data = try receipt(phase: phase, processIdentifier: processIdentifier, bundleURL: bundleURL)
        try data.write(to: receiptURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }
}

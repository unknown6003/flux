import Darwin
import Foundation

public enum SingleInstanceError: Error, Equatable { case unsafeDirectory, unsafeFile, alreadyRunning, unavailable }

/// One descriptor holds the writer lease until shutdown or process death.
/// LOCK_NB never waits for another Flux process. Helpers cannot inherit it.
public final class SingleInstanceLease: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: URL) throws {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw SingleInstanceError.unsafeDirectory
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("native-session.lock")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SingleInstanceError.unavailable }
        var acquired = false
        defer { if !acquired { close(descriptor) } }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else { throw SingleInstanceError.unsafeFile }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw SingleInstanceError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw SingleInstanceError.alreadyRunning }
            throw SingleInstanceError.unavailable
        }
        self.descriptor = descriptor
        acquired = true
    }

    deinit { close(descriptor) }
}

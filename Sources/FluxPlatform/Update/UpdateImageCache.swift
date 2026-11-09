import CryptoKit
import Darwin
import Foundation
import FluxCore

/// Remember only a disk image whose contained app has already passed the
/// publisher check. Reuse checks the complete file, not only its timestamp.
struct UpdateImageCache: Sendable {
    private let release: ReleaseManifest
    private let file: URL
    private let digest: Data

    init(verifiedFile: URL, release: ReleaseManifest) throws {
        self.release = release; file = verifiedFile
        digest = try Self.hash(verifiedFile, size: release.size)
        if let expected = release.sha256 {
            guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
                throw ReleaseDownloadError.digest
            }
        }
    }

    func validatedFile(for release: ReleaseManifest) throws -> URL? {
        guard self.release.version == release.version, self.release.downloadURL == release.downloadURL,
              self.release.size == release.size, self.release.sha256 == release.sha256 else { return nil }
        return try Self.hash(file, size: release.size) == digest ? file : nil
    }

    private static func hash(_ file: URL, size: Int64) throws -> Data {
        try Task.checkCancellation()
        guard file.isFileURL, size > 0, size <= ReleaseManifest.maximumDownloadBytes else { throw ReleaseDownloadError.file }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReleaseDownloadError.file }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == size else { throw ReleaseDownloadError.size }
        var digest = SHA256()
        var read: Int64 = 0
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            read += Int64(bytes.count)
            guard read <= size else { throw ReleaseDownloadError.size }
            digest.update(data: bytes)
        }
        guard read == size else { throw ReleaseDownloadError.size }
        return Data(digest.finalize())
    }
}

import CryptoKit
import Foundation
import Testing
import FluxCore
@testable import FluxPlatform

private final class ReleaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.contains("v1.0.5") { return } // The cancellation case remains pending.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = url.path.contains("v1.0.2") ? "123456789" : (url.path.contains("v1.0.4") ? "12" : "12345678")
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ReleaseDownloadTests {
    private func manifest(_ version: String, digest: String? = nil) throws -> ReleaseManifest {
        let hex = digest ?? SHA256.hash(data: Data("12345678".utf8)).map { String(format: "%02x", $0) }.joined()
        return try ReleaseManifest(data: JSONSerialization.data(withJSONObject: [
            "tag_name": "v" + version, "draft": false, "prerelease": false,
            "assets": [["name": "Flux.dmg", "state": "uploaded", "size": 8,
                        "browser_download_url": "https://github.com/unknown6003/flux/releases/download/v\(version)/Flux.dmg",
                        "digest": "sha256:" + hex]]
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func streamedDownloadChecksSizeDigestAndKeepsExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Flux.dmg")
        try await ReleaseDownload.fetch(manifest("1.0.1"), to: target, protocols: [ReleaseFixtureProtocol.self])
        #expect(try Data(contentsOf: target) == Data("12345678".utf8))
        do {
            try await ReleaseDownload.fetch(manifest("1.0.1"), to: target, protocols: [ReleaseFixtureProtocol.self])
            Issue.record("An existing download must not be replaced")
        } catch { #expect(error as? ReleaseDownloadError == .file) }
        #expect(try Data(contentsOf: target) == Data("12345678".utf8))
        for version in ["1.0.2", "1.0.3", "1.0.4"] {
            let path = root.appendingPathComponent(version)
            let release = try manifest(version, digest: version == "1.0.3" ? String(repeating: "0", count: 64) : nil)
            do {
                try await ReleaseDownload.fetch(release, to: path, protocols: [ReleaseFixtureProtocol.self])
                Issue.record("Expected rejection for \(version)")
            } catch {
                #expect(error as? ReleaseDownloadError == (version == "1.0.3" ? .digest : .size))
            }
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAnUnfinishedDownloadRemovesItsPartialFile() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("flux-download-\(UUID())")
        defer { try? FileManager.default.removeItem(at: target) }
        let release = try manifest("1.0.5")
        let work = Task { try await ReleaseDownload.fetch(release, to: target, protocols: [ReleaseFixtureProtocol.self]) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: target.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        work.cancel()
        do { try await work.value; Issue.record("Expected cancellation") } catch {}
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

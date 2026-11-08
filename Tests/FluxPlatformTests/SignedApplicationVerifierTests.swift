import Foundation
import Security
import Testing
import FluxCore
@testable import FluxPlatform

struct SignedApplicationVerifierTests {
    @Test func unsignedBundleCannotReachMetadataAcceptance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-signature-\(UUID()).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = SignedApplicationVerifier()
        let version = try #require(ReleaseVersion("0.22.0"))
        await #expect(throws: SignedApplicationError.signature) { try await verifier.verify(root, expectedVersion: version) }
    }

    @Test func validSystemSignatureIsNotTheFluxPublisher() async throws {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSDefaultFlags)
        #expect(SecStaticCodeCreateWithPath(finder as CFURL, flags, &code) == errSecSuccess)
        let signedCode = try #require(code)
        #expect(SecStaticCodeCheckValidity(signedCode, flags, nil) == errSecSuccess)
        let verifier = SignedApplicationVerifier()
        let version = try #require(ReleaseVersion("0.22.0"))
        await #expect(throws: SignedApplicationError.signature) { try await verifier.verify(finder, expectedVersion: version) }
    }
}

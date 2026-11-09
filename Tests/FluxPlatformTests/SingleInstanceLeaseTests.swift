import Foundation
import Darwin
import Testing
@testable import FluxPlatform

struct SingleInstanceLeaseTests {
    @Test func processWriterLeaseRefusesAnotherWriterAndReleasesOnOwnerExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: SingleInstanceLease? = try SingleInstanceLease(directory: root)
        #expect(throws: SingleInstanceError.alreadyRunning) { try SingleInstanceLease(directory: root) }
        first = nil
        let second = try SingleInstanceLease(directory: root)
        withExtendedLifetime(second) {
            #expect(throws: SingleInstanceError.alreadyRunning) { try SingleInstanceLease(directory: root) }
        }
    }

    @Test func ownerReleaseEndsTheLeaseEvenWhileADuplicatedDescriptorIsOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: SingleInstanceLease? = try SingleInstanceLease(directory: root)
        weak var released = first
        guard let descriptor = first?.descriptor else { Issue.record("No owner descriptor"); return }
        // dup has the same shared-lock semantics as a descriptor inherited
        // during fork, before close-on-exec has run in the child.
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw SingleInstanceError.unavailable }
        defer { close(duplicate) }
        first = nil
        #expect(released == nil)
        let replacement = try SingleInstanceLease(directory: root)
        withExtendedLifetime(replacement) {
            #expect(throws: SingleInstanceError.alreadyRunning) { try SingleInstanceLease(directory: root) }
        }
    }

    @Test func writerLeaseDoesNotFollowALinkOrTruncateAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preserve.txt")
        try Data("Keep this file".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("native-session.lock"), withDestinationURL: target)
        #expect(throws: (any Error).self) { try SingleInstanceLease(directory: root) }
        #expect(try Data(contentsOf: target) == Data("Keep this file".utf8))
    }
}

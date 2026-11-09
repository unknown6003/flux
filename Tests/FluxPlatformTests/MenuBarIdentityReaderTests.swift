import Foundation
import Security
import Darwin
import Testing
import FluxCore
@testable import FluxPlatform

private enum IdentityFixtureError: Error {
    case command
    case deadline
    case requirement
}

private func waitForIdentityFixture(_ process: Process, seconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else {
        process.terminate()
        let stop = Date().addingTimeInterval(1)
        while process.isRunning, Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        throw IdentityFixtureError.deadline
    }
}

private func identityRequirement(_ text: String) throws -> Data {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement else { throw IdentityFixtureError.requirement }
    var data: CFData?
    guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else {
        throw IdentityFixtureError.requirement
    }
    return data as Data
}

@Test(.timeLimit(.minutes(1))) func runningIdentityUsesTheSavedRequirementRatherThanBinaryEquality() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-identity-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("fixture")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    let application = try #require(ApplicationID(rawValue: "org.fluxfixture.identity"))
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", "--identifier", application.rawValue, executable.path]
    signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
    try signer.run()
    try waitForIdentityFixture(signer, seconds: 10)
    guard signer.terminationStatus == 0 else { throw IdentityFixtureError.command }
    let fixture = Process()
    fixture.executableURL = executable; fixture.arguments = ["30"]
    try fixture.run()
    defer {
        if fixture.isRunning { fixture.terminate() }
        try? waitForIdentityFixture(fixture, seconds: 2)
    }
    let reader = MenuBarIdentityReader()
    let first = try #require(await reader.read(processID: fixture.processIdentifier, application: application, savedRequirement: nil))
    #expect(first.matchesSaved)
    let pinned = await reader.read(processID: fixture.processIdentifier, application: application, savedRequirement: first.requirement)
    #expect(pinned?.matchesSaved == true)
    let continuity = try identityRequirement("identifier \"org.fluxfixture.identity\"")
    #expect(continuity != first.requirement)
    #expect(await reader.read(processID: fixture.processIdentifier, application: application,
                              savedRequirement: continuity)?.matchesSaved == true)
    let other = try identityRequirement("identifier \"org.fluxfixture.other\"")
    #expect(await reader.read(processID: fixture.processIdentifier, application: application,
                              savedRequirement: other)?.matchesSaved == false)
    #expect(await reader.read(processID: fixture.processIdentifier, application: application,
                              savedRequirement: Data([0, 1, 2])) == nil)
    let wrongOwner = try #require(ApplicationID(rawValue: "org.fluxfixture.other"))
    #expect(await reader.read(processID: fixture.processIdentifier, application: wrongOwner, savedRequirement: nil) == nil)
}

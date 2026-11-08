import Foundation
import Testing
@testable import FluxCore

private let updateToken = "A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD"

@Test func newStartupReceiptMatchesTheInstalledUpdaterProtocol() throws {
    let temporary = FileManager.default.temporaryDirectory
    let path = temporary.appendingPathComponent("flux-update-" + updateToken).appendingPathComponent("startup")
    let launch = try #require(UpdateLaunch(arguments: [
        "Flux", "--flux-update-token", updateToken, "--flux-update-receipt", path.path
    ], temporaryDirectory: temporary))
    let started = try launch.receipt(phase: .started, processIdentifier: 12345, bundleURL: URL(fileURLWithPath: "/Applications/Flux.app"))
    let ready = try launch.receipt(phase: .ready, processIdentifier: 12345, bundleURL: URL(fileURLWithPath: "/Applications/Flux.app"))
    #expect(String(decoding: started, as: UTF8.self) == "A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD\n12345\n/Applications/Flux.app\nstarted\n")
    #expect(String(decoding: ready, as: UTF8.self) == "A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD\n12345\n/Applications/Flux.app\nready\n")
    #expect(throws: StartupReceiptError.self) {
        try launch.receipt(phase: .ready, processIdentifier: 1, bundleURL: URL(fileURLWithPath: "/Applications/Flux.app"))
    }
    #expect(throws: StartupReceiptError.self) {
        try launch.receipt(phase: .ready, processIdentifier: 12345, bundleURL: URL(fileURLWithPath: "/Applications/Flux\nOther.app"))
    }
}

@Test func updateLaunchRefusesAmbiguousArgumentsAndPathsOutsideThePrivateWorkspace() {
    let temporary = FileManager.default.temporaryDirectory
    let valid = temporary.appendingPathComponent("flux-update-" + updateToken).appendingPathComponent("startup").path
    let arguments = ["--flux-update-token", updateToken, "--flux-update-receipt", valid]
    #expect(UpdateLaunch(arguments: arguments, temporaryDirectory: temporary) != nil)
    #expect(UpdateLaunch(arguments: arguments + ["--flux-update-token", updateToken], temporaryDirectory: temporary) == nil)
    #expect(UpdateLaunch(arguments: ["--flux-update-token"], temporaryDirectory: temporary) == nil)
    #expect(UpdateLaunch(arguments: ["--flux-update-token", "not-a-token", "--flux-update-receipt", valid], temporaryDirectory: temporary) == nil)
    for invalid in [
        "flux-update-" + updateToken + "/startup",
        "/Applications/flux-update-" + updateToken + "/startup",
        temporary.appendingPathComponent("unrelated/startup").path,
        valid + "-other"
    ] {
        #expect(UpdateLaunch(arguments: ["--flux-update-token", updateToken, "--flux-update-receipt", invalid], temporaryDirectory: temporary) == nil)
    }
}

@Test func startupWriterProducesBothPhasesAndRefusesASymlinkReceipt() throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory
    let token = UUID().uuidString
    let workspace = temporary.appendingPathComponent("flux-update-" + token)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: workspace) }
    let target = workspace.appendingPathComponent("startup")
    let launch = try #require(UpdateLaunch(arguments: [
        "--flux-update-token", token, "--flux-update-receipt", target.path
    ], temporaryDirectory: temporary))
    let bundle = URL(fileURLWithPath: "/Applications/Flux.app")
    try launch.write(phase: .started, processIdentifier: 12345, bundleURL: bundle)
    #expect(try String(contentsOf: target, encoding: .utf8).hasSuffix("\nstarted\n"))
    try launch.write(phase: .ready, processIdentifier: 12345, bundleURL: bundle)
    #expect(try String(contentsOf: target, encoding: .utf8).hasSuffix("\nready\n"))
    let attributes = try manager.attributesOfItem(atPath: target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try manager.removeItem(at: target)
    let unrelated = workspace.appendingPathComponent("unrelated")
    try Data("keep".utf8).write(to: unrelated)
    try manager.createSymbolicLink(at: target, withDestinationURL: unrelated)
    #expect(throws: StartupReceiptError.self) { try launch.write(phase: .ready, processIdentifier: 12345, bundleURL: bundle) }
    #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
}

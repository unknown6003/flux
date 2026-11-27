import Foundation
import Testing
@testable import FluxPlatform

struct UpdateStageFilesTests {
    @Test func discardSucceedsAfterTheHelperAlreadyRemovedTheStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-stage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingStage = root.appendingPathComponent("removed-stage")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: workspace.appendingPathComponent("install.sh"))
        try UpdateStageFiles.discard(directory: missingStage, workspace: workspace)
        try UpdateStageFiles.discard(directory: missingStage, workspace: workspace)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test func installHandoffScriptPrefixesInlineCodesignRequirementWithEquals() {
        let script = InstallHandoffScript.make(
            staged: URL(fileURLWithPath: "/Applications/.Flux-update-token/Flux.app"),
            installURL: URL(fileURLWithPath: "/Applications/Flux.app"),
            backup: URL(fileURLWithPath: "/Applications/.Flux-backup-token.app"),
            workspace: URL(fileURLWithPath: "/tmp/flux-update-token"),
            parentPID: 4242
        )
        #expect(script.contains(#"-R '=identifier "com.flux.menubar" and certificate leaf = H"A7378EAF65FB4E0A254BAA69167FB772C9DFFBBC"'"#))
    }
}

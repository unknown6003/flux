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
}

import Darwin
import Foundation
import Testing
@testable import FluxPlatform

struct BoundedCommandTests {
    @Test(.timeLimit(.minutes(1))) func commandDeadlineStopsItsShellAndChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-command-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("child")
        let runner = BoundedCommand()
        do {
            try await runner.run(URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", #"echo $$ > "$1"; /bin/sleep 30"#, "fixture", receipt.path], seconds: 1)
            Issue.record("Expected a command deadline")
        } catch { #expect(error as? BoundedCommandError == .timedOut) }
        let raw = try String(contentsOf: receipt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(raw))
        #expect(kill(pid, 0) != 0)
        try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], seconds: 2)
    }
}

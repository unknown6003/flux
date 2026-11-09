#if FLUX_PERFORMANCE_TRACE
import Darwin
import Dispatch
import Foundation
import Testing
@testable import FluxCore

private final class TraceTestDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("flux-performance-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var output: URL { url.appendingPathComponent("trace-\(getpid()).json") }
}

private func traceDocument(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct PerformanceTraceTests {
    @Test func recordsOnlyFixedCodesAndMonotonicTimesWithoutEarlyIO() throws {
        let directory = try TraceTestDirectory()
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for code in PerformanceTraceCode.allCases { recorder.record(code) }
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
        let output = try recorder.finish()
        #expect(output.lastPathComponent == "trace-\(getpid()).json")
        let document = try traceDocument(output)
        #expect(Set(document.keys) == ["processID", "clock", "events", "dropped"])
        #expect(document["processID"] as? Int32 == getpid())
        #expect(document["clock"] as? String == "CLOCK_UPTIME_RAW")
        #expect(document["dropped"] as? UInt64 == 0)
        let events = try #require(document["events"] as? [[String: Any]])
        #expect(events.compactMap { $0["code"] as? String } == PerformanceTraceCode.allCases.map(\.rawValue))
        let times = events.compactMap { ($0["uptimeNanoseconds"] as? NSNumber)?.uint64Value }
        #expect(times.count == events.count)
        #expect(times.allSatisfy { $0 >= start && $0 <= end })
        #expect(times == times.sorted())
        #expect(events.allSatisfy { Set($0.keys) == ["uptimeNanoseconds", "code"] })
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: output).count <= 131_072)
    }

    @Test func boundsEventsAndPermanentlyDiscardsLateRecords() throws {
        let directory = try TraceTestDirectory()
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        for _ in 0..<1_031 { recorder.record(.applicationActivated) }
        let output = try recorder.finish()
        let bytes = try Data(contentsOf: output)
        let document = try traceDocument(output)
        #expect((document["events"] as? [[String: Any]])?.count == 1_024)
        #expect(document["dropped"] as? UInt64 == 7)
        recorder.record(.httpFailed)
        #expect(throws: PerformanceTraceError.alreadyFinished) { try recorder.finish() }
        #expect(try Data(contentsOf: output) == bytes)
        #expect(bytes.count <= 131_072)
    }

    @Test func rejectsOutsideNestedMissingSymlinkAndPublicDirectories() throws {
        let directory = try TraceTestDirectory()
        #expect(throws: PerformanceTraceError.invalidDirectory) {
            try PerformanceTraceRecorder(directory: URL(fileURLWithPath: "/"))
        }
        #expect(throws: PerformanceTraceError.invalidDirectory) {
            try PerformanceTraceRecorder(directory: URL(string: "https://example.com/flux-performance-fixture")!)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("flux-performance-" + UUID().uuidString)
        #expect(throws: PerformanceTraceError.invalidDirectory) { try PerformanceTraceRecorder(directory: missing) }
        let wrongPrefix = FileManager.default.temporaryDirectory.appendingPathComponent("flux-trace-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: wrongPrefix, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: wrongPrefix) }
        #expect(throws: PerformanceTraceError.invalidDirectory) { try PerformanceTraceRecorder(directory: wrongPrefix) }
        let nested = directory.url.appendingPathComponent("flux-performance-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: PerformanceTraceError.invalidDirectory) { try PerformanceTraceRecorder(directory: nested) }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("flux-performance-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.url)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: PerformanceTraceError.invalidDirectory) { try PerformanceTraceRecorder(directory: link) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }
        #expect(throws: PerformanceTraceError.invalidDirectory) { try PerformanceTraceRecorder(directory: directory.url) }
    }

    @Test func preservesPreexistingOutputAndStopsAfterFailure() throws {
        let directory = try TraceTestDirectory()
        let original = Data("keep this existing file".utf8)
        try original.write(to: directory.output)
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        recorder.record(.appReady)
        #expect(throws: PerformanceTraceError.outputExists) { try recorder.finish() }
        recorder.record(.appStop)
        #expect(throws: PerformanceTraceError.alreadyFinished) { try recorder.finish() }
        #expect(try Data(contentsOf: directory.output) == original)
    }

    @Test func refusesOutputSymlinksWithoutTouchingTheirTargets() throws {
        let directory = try TraceTestDirectory()
        let target = directory.url.appendingPathComponent("fixture.txt")
        let original = Data("private fixture".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.output, withDestinationURL: target)
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        #expect(throws: PerformanceTraceError.outputExists) { try recorder.finish() }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func concurrentRecordsAreBoundedAndUseOneClockOrder() throws {
        let directory = try TraceTestDirectory()
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        DispatchQueue.concurrentPerform(iterations: 2_048) { _ in recorder.record(.sessionRefresh) }
        let document = try traceDocument(recorder.finish())
        let events = try #require(document["events"] as? [[String: Any]])
        #expect(events.count == 1_024)
        #expect(document["dropped"] as? UInt64 == 1_024)
        let times = events.compactMap { ($0["uptimeNanoseconds"] as? NSNumber)?.uint64Value }
        #expect(times.count == events.count)
        #expect(times == times.sorted())
    }

    @Test func refusesAReplacedDirectoryWithoutWritingToEitherPath() throws {
        let directory = try TraceTestDirectory()
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("flux-performance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        let recorder = try PerformanceTraceRecorder(directory: directory.url)
        try FileManager.default.moveItem(at: directory.url, to: moved)
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        recorder.record(.appReady)
        #expect(throws: PerformanceTraceError.invalidDirectory) { try recorder.finish() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        #expect(throws: PerformanceTraceError.alreadyFinished) { try recorder.finish() }
    }

    @Test func globalRouterStartsOnceDetachesAtFinishAndIgnoresLateCallbacks() throws {
        #expect(!PerformanceTrace.isEnabled)
        PerformanceTrace.record(.httpFailed)
        #expect(try PerformanceTrace.finish() == nil)
        let directory = try TraceTestDirectory()
        try PerformanceTrace.begin(directory: directory.url)
        defer { _ = try? PerformanceTrace.finish() }
        #expect(PerformanceTrace.isEnabled)
        #expect(throws: PerformanceTraceError.alreadyStarted) { try PerformanceTrace.begin(directory: directory.url) }
        PerformanceTrace.record(.appReady)
        let finishedOutput = try PerformanceTrace.finish()
        let output = try #require(finishedOutput)
        #expect(!PerformanceTrace.isEnabled)
        let bytes = try Data(contentsOf: output)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in PerformanceTrace.record(.appStop) }
        #expect(try PerformanceTrace.finish() == nil)
        #expect(throws: PerformanceTraceError.alreadyStarted) { try PerformanceTrace.begin(directory: directory.url) }
        #expect(try Data(contentsOf: output) == bytes)
        let document = try traceDocument(output)
        #expect((document["events"] as? [[String: Any]])?.count == 1)
    }
}
#endif

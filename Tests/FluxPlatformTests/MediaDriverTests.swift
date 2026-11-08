import Darwin
import Foundation
import Testing
@testable import FluxPlatform

private struct MediaFixture: Sendable {
    let root: URL
    let script: URL

    init(malformed: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-media-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        script = root.appendingPathComponent("fixture.pl")
        // This private helper talks to no system service. It records only its
        // own PID and typed command arguments, then waits for termination.
        let line = malformed ? "invalid" : #"{"type":"data","diff":false,"payload":{"title":"Fixture track","playing":true}}"#
        let source = """
        use strict;
        use warnings;
        $| = 1;
        my ($root, $mode, @values) = @ARGV;
        open(my $pid, '>>', "$root/pids") or die;
        print $pid "$$\\n";
        close($pid);
        if ($mode eq 'stream') {
            print '\(line)', "\\n";
            while (1) { sleep 1; }
        }
        open(my $command, '>', "$root/command") or die;
        print $command join(' ', $mode, @values);
        close($command);
        if ($mode eq 'seek') { while (1) { sleep 1; } }
        exit 0;
        """
        try Data(source.utf8).write(to: script)
    }

    var pids: [pid_t] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { Int32($0) }
    }
    var command: String? { try? String(contentsOf: root.appendingPathComponent("command"), encoding: .utf8) }
    var allStopped: Bool { !pids.isEmpty && pids.allSatisfy { kill($0, 0) != 0 } }

    func cleanUp() {
        // The fixture owns every listed PID. This is a last-resort test cleanup
        // if an assertion or the driver fails before its normal stop path.
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
}

private func mediaEventually(seconds: Double = 3, _ predicate: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await predicate()
}

private actor MediaObservations {
    private var ready = false
    func record(_ state: MediaFeedState) {
        if case .ready(let snapshot) = state, snapshot?.title == "Fixture track" { ready = true }
    }
    func hasReady() -> Bool { ready }
}

@Test(.timeLimit(.minutes(1)))
func mediaDriverReadsEventsSendsTypedCommandsAndStopsItsExactChild() async throws {
    let fixture = try MediaFixture()
    defer { fixture.cleanUp() }
    let driver = MediaDriver(script: fixture.script, framework: fixture.root)
    let seen = MediaObservations()
    let events = Task { for await state in driver.updates { await seen.record(state) } }
    await driver.start()
    #expect(await mediaEventually { await seen.hasReady() })
    #expect(await driver.send(.next))
    #expect(fixture.command == "send 4")
    #expect(await driver.send(.seek(.infinity)) == false)
    await driver.stop()
    await events.value
    #expect(await mediaEventually { fixture.allStopped })
}

@Test(.timeLimit(.minutes(1)))
func mediaStopCompletesPendingCommandAndCancelsScheduledRestart() async throws {
    let fixture = try MediaFixture()
    defer { fixture.cleanUp() }
    let driver = MediaDriver(script: fixture.script, framework: fixture.root)
    await driver.start()
    #expect(await mediaEventually { !fixture.pids.isEmpty })
    let command = Task { await driver.send(.seek(12)) }
    #expect(await mediaEventually { fixture.command == "seek 12000000" })
    await driver.stop()
    #expect(await command.value == false)
    #expect(await mediaEventually { fixture.allStopped })

    let broken = try MediaFixture(malformed: true)
    defer { broken.cleanUp() }
    let retrying = MediaDriver(script: broken.script, framework: broken.root)
    await retrying.start()
    #expect(await mediaEventually { broken.pids.count >= 2 })
    await retrying.stop()
    #expect(await mediaEventually { broken.allStopped })
    let launches = broken.pids.count
    try await Task.sleep(for: .seconds(3.2))
    #expect(broken.pids.count == launches)
}

@Test(.timeLimit(.minutes(1)))
func mediaCommandDeadlineStopsAnUnresponsiveCommand() async throws {
    let fixture = try MediaFixture()
    defer { fixture.cleanUp() }
    let driver = MediaDriver(script: fixture.script, framework: fixture.root)
    await driver.start()
    #expect(await mediaEventually { !fixture.pids.isEmpty })
    let start = ContinuousClock.now
    #expect(await driver.send(.seek(5)) == false)
    #expect(ContinuousClock.now - start < .seconds(7))
    await driver.stop()
    #expect(await mediaEventually { fixture.allStopped })
}

@MainActor @Test(.timeLimit(.minutes(1)))
func releasingMediaFeedStopsItsHelperWithoutAnExplicitStop() async throws {
    let fixture = try MediaFixture()
    defer { fixture.cleanUp() }
    let driver = MediaDriver(script: fixture.script, framework: fixture.root)
    var feed: MediaFeed? = MediaFeed(driver: driver) { _ in }
    weak var released = feed
    #expect(await mediaEventually { !fixture.pids.isEmpty })
    feed = nil
    #expect(released == nil)
    #expect(await mediaEventually { fixture.allStopped })
}

import Foundation
import Testing
@testable import FluxPlatform

struct MediaCommandAuthorizationTests {
    @Test @MainActor func revokedQueuedCommandCannotLaunchWhileTheSharedDriverStaysLive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flux-media-command-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("fixture.pl")
        let source = #"""
        use strict;
        use warnings;
        $| = 1;
        if ($ARGV[1] eq "stream") {
            print '{"type":"data","diff":false,"payload":{}}'."\n";
            sleep 30;
        } else {
            open my $record, ">>", "$ARGV[0]/sent" or die;
            print $record "$ARGV[1]\n";
            close $record;
        }
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let driver = MediaDriver(script: script, framework: directory)
        do {
            await driver.start()
            let live = MediaCommandAuthorization()
            #expect(await driver.send(.toggle, authorization: live))
            let revoked = MediaCommandAuthorization()
            // The task inherits this main actor. Revoke before it can enter
            // the driver's actor, without stopping the shared media helper.
            let queued = Task { await driver.send(.next, authorization: revoked) }
            revoked.revoke()
            #expect(await queued.value == false)
            #expect(await driver.send(.previous, authorization: live))
            let records = try String(contentsOf: directory.appendingPathComponent("sent"), encoding: .utf8)
            #expect(records.split(separator: "\n").count == 2)
        } catch {
            await driver.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await driver.stop()
        try FileManager.default.removeItem(at: directory)
    }
}

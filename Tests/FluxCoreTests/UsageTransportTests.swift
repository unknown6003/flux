import Foundation
import Darwin
import Testing
@testable import FluxCore

private struct TLSFixtureFailure: Error {}

private final class UsageTLSFixture: @unchecked Sendable {
    let directory: URL
    let process: Process
    let port: UInt16
    let caPath: String

    private init(directory: URL, process: Process, port: UInt16, caPath: String) {
        self.directory = directory; self.process = process
        self.port = port; self.caPath = caPath
    }

    static func start(wrongHost: Bool = false) async throws -> UsageTLSFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flux-usage-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [root.appendingPathComponent("Scripts/rebuild/usage_tls_fixture.py").path, directory.path]
            + (wrongHost ? ["--wrong-host"] : [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline, process.isRunning {
                if let data = try? Data(contentsOf: directory.appendingPathComponent("ready.json")),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let port = object["port"] as? Int, let value = UInt16(exactly: port), value > 0,
                   let caPath = object["caPath"] as? String {
                    return UsageTLSFixture(directory: directory, process: process, port: value, caPath: caPath)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw TLSFixtureFailure()
        } catch {
            stop(process)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<50 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<50 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!process.isRunning)
    }

    deinit {
        Self.stop(process)
        try? FileManager.default.removeItem(at: directory)
    }

    func transport(region: PostHogRegion = .eu, trustedCA: String? = nil) -> NativeUsageTransport {
        NativeUsageTransport(region: region, fixturePort: port, fixtureCAPath: trustedCA ?? caPath)
    }

    func requests() throws -> [[String: Any]] {
        guard let data = try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8) else { return [] }
        return try data.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try !requests().isEmpty { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TLSFixtureFailure()
    }
}

private func fixtureRequest(_ endpoint: UsageEndpoint = .events, mode: String = "ok", token: String = "phc_fixture") -> UsageRequest {
    UsageRequest(endpoint: endpoint, body: Data("{\"mode\":\"\(mode)\"}".utf8), projectToken: token)
}

@Suite(.timeLimit(.minutes(1))) struct UsageTransportTests {
    @Test func realTLSMapsBothRegionsAndEveryEndpointWithoutAmbientCredentials() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        for region in [PostHogRegion.eu, .us] {
            let transport = fixture.transport(region: region)
            for endpoint in [UsageEndpoint.events, .flags, .logs] {
                let response = try await transport.send(fixtureRequest(endpoint))
                #expect(response.status == 200)
                #expect(response.body == Data(#"{"status":"Ok"}"#.utf8))
            }
        }
        let requests = try fixture.requests()
        #expect(requests.count == 6)
        for (index, request) in requests.enumerated() {
            #expect(request["path"] as? String == ["/batch/", "/flags/?v=2", "/i/v1/logs"][index % 3])
            let headers = try #require(request["headers"] as? [String: String])
            #expect(headers["Host"] == (index < 3 ? "eu.i.posthog.com" : "us.i.posthog.com"))
            #expect(headers["User-Agent"] == "Flux")
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Cache-Control"] == "no-store")
            #expect(headers["Cookie"] == nil)
            #expect(headers["Authorization"] == (index % 3 == 2 ? "Bearer phc_fixture" : nil))
        }
    }

    @Test func refusesRedirectsAndReturnsHTTPFailuresWithoutTransportRetries() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let transport = fixture.transport()
        #expect(try await transport.send(fixtureRequest(mode: "redirect")).status == 302)
        #expect(try await transport.send(fixtureRequest(mode: "error")).status == 503)
        #expect(try fixture.requests().count == 2)
    }

    @Test func boundsAdvertisedChunkedAndHeaderResponsesBeforeAccumulation() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let transport = fixture.transport()
        #expect(try await transport.send(fixtureRequest(mode: "limit")).body.count == 65_536)
        for mode in ["advertised", "chunked", "headers"] {
            await #expect(throws: PostHogWireError.oversizedResponse) {
                try await transport.send(fixtureRequest(mode: mode))
            }
        }
    }

    @Test func validatesRequestBoundsAndRejectsLogHeaderInjectionBeforeSending() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let transport = fixture.transport()
        for body in [Data(), Data(repeating: 65, count: 65_537)] {
            await #expect(throws: UsageTransportFailure.invalidRequest) {
                try await transport.send(UsageRequest(endpoint: .events, body: body, projectToken: "phc_fixture"))
            }
        }
        await #expect(throws: UsageTransportFailure.invalidRequest) {
            try await transport.send(fixtureRequest(.logs, token: "phc_fixture\r\nCookie: private"))
        }
        #expect(try fixture.requests().isEmpty)
    }

    @Test func verifiesCertificateTrustAndHostIndependently() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let wrongHost = try await UsageTLSFixture.start(wrongHost: true)
        defer { withExtendedLifetime(wrongHost) {} }
        await #expect(throws: UsageTransportFailure.network) {
            try await wrongHost.transport().send(fixtureRequest())
        }
        await #expect(throws: UsageTransportFailure.network) {
            try await fixture.transport(trustedCA: wrongHost.caPath).send(fixtureRequest())
        }
        #expect(try fixture.requests().isEmpty)
        #expect(try wrongHost.requests().isEmpty)
    }

    @Test func cancelsAnActiveTransferAndRefusesConcurrentWorkThenRecovers() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let transport = fixture.transport()
        let task = Task { try await transport.send(fixtureRequest(mode: "stall")) }
        defer { task.cancel() }
        try await fixture.waitForRequest()
        await #expect(throws: UsageTransportFailure.busy) {
            try await transport.send(fixtureRequest())
        }
        task.cancel()
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: .now) < .seconds(8))
        #expect(try await transport.send(fixtureRequest()).status == 200)
        #expect(try fixture.requests().count == 2)
    }

    @Test func preCancelledTaskNeverStartsARequest() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let transport = fixture.transport()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(fixtureRequest())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.requests().isEmpty)
    }

    @Test func timesOutAnUnresponsivePeerWithoutWaitingForServerClose() async throws {
        let fixture = try await UsageTLSFixture.start()
        defer { withExtendedLifetime(fixture) {} }
        let started = ContinuousClock.now
        await #expect(throws: UsageTransportFailure.network) {
            try await fixture.transport().send(fixtureRequest(mode: "stall"))
        }
        let duration = started.duration(to: .now)
        #expect(duration >= .seconds(5))
        #expect(duration < .seconds(11))
    }
}

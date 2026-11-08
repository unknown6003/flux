import Darwin
import Foundation
import FluxCore

private struct RequestResult: Codable, Sendable {
    let endpoint: String
    let status: Int
    let responseBytes: Int
    let rejectedLogRecords: Int
}

private actor ProbeTransport: UsageTransport {
    private let transport = NativeUsageTransport(region: FluxUsageProject.region)
    private var results: [RequestResult] = []

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        let response = try await transport.send(request)
        let name: String
        switch request.endpoint {
        case .events: name = "events"
        case .flags: name = "flags"
        case .logs: name = "logs"
        }
        var rejected = 0
        if request.endpoint == .logs,
           let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let partial = object["partialSuccess"] as? [String: Any] {
            rejected = (partial["rejectedLogRecords"] as? NSNumber)?.intValue
                ?? Int(partial["rejectedLogRecords"] as? String ?? "0") ?? 0
        }
        if request.endpoint == .flags, response.status == 200 {
            _ = try PostHogWire.flagsResponse(response.body)
        }
        results.append(RequestResult(endpoint: name, status: response.status,
                                     responseBytes: response.body.count, rejectedLogRecords: rejected))
        return response
    }

    func capturedResults() -> [RequestResult] { results }
}

private struct ProbeReport: Codable {
    let projectID: Int
    let distinctID: String
    let requests: [RequestResult]
    let transportAccepted: Bool
    let serverReadbackRequired: Bool
}

@main struct TelemetryProbe {
    static func main() async throws {
        guard ProcessInfo.processInfo.environment["FLUX_ALLOW_POSTHOG_PROBE"] == "1" else {
            print("Live probe is off. Set FLUX_ALLOW_POSTHOG_PROBE=1 to send synthetic records.")
            exit(2)
        }
        let identity = UsageIdentity()
        let transport = ProbeTransport()
        let client = try PostHogClient(projectToken: FluxUsageProject.token, identity: identity,
                                      transport: transport, flushDelay: .seconds(120), isVerification: true)
        await client.reloadFlags()
        await client.record(.opened(.settings))
        await client.record(.failed(.serviceUnavailable))
        await client.log(.serviceStarted)
        await client.flush()
        await client.flush()
        await client.disable()
        let requests = await transport.capturedResults()
        let accepted = Set(requests.map(\.endpoint)) == ["flags", "events", "logs"]
            && requests.allSatisfy { (200..<300).contains($0.status) && $0.rejectedLogRecords == 0 }
        let report = ProbeReport(projectID: FluxUsageProject.id, distinctID: identity.value.uuidString.lowercased(),
                                 requests: requests, transportAccepted: accepted, serverReadbackRequired: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        if !accepted { exit(1) }
    }
}

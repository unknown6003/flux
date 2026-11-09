// Diagnostic only. This executable is not bundled in Flux.
import Darwin
import Foundation
@testable import FluxCore

private enum Mode: String {
    case idle
    case direct
    case client
}

private struct Phase: Encodable {
    let phase: String
    let mode: String
    let at: Date
    let uptime: TimeInterval
    let processID: Int32
    let distinctID: String?
    let request: Int?
    let status: Int?
}

private func emit(_ phase: String, mode: Mode, identity: UsageIdentity? = nil,
                  request: Int? = nil, status: Int? = nil) {
    let value = Phase(phase: phase, mode: mode.rawValue, at: Date(),
        uptime: ProcessInfo.processInfo.systemUptime, processID: getpid(),
        distinctID: identity?.value.uuidString.lowercased(), request: request, status: status)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

private actor TracedTransport: UsageTransport {
    private let native = NativeUsageTransport(region: FluxUsageProject.region)
    private let mode: Mode
    private var count = 0

    init(mode: Mode) { self.mode = mode }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        count += 1
        let number = count
        emit("requestStarted", mode: mode, request: number)
        do {
            let response = try await native.send(request)
            emit("requestFinished", mode: mode, request: number, status: response.status)
            return response
        } catch {
            emit("requestFailed", mode: mode, request: number)
            throw error
        }
    }
}

@main private struct TelemetryIdleProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard ProcessInfo.processInfo.environment["FLUX_ALLOW_TELEMETRY_IDLE_PROBE"] == "1",
              arguments.count == 3, let mode = Mode(rawValue: arguments[1]),
              let seconds = Int(arguments[2]), (1...120).contains(seconds) else {
            FileHandle.standardError.write(Data("Expected an enabled diagnostic and idle|direct|client with hold seconds 1...120\n".utf8))
            exit(2)
        }
        if mode == .idle {
            emit("quietStarted", mode: mode)
            try await Task.sleep(for: .seconds(seconds))
            emit("finished", mode: mode)
            return
        }
        let identity = UsageIdentity()
        let transport = TracedTransport(mode: mode)
        var client: PostHogClient?
        emit("ready", mode: mode, identity: identity)
        if mode == .direct {
            let body = try UsageBatchEncoder.encode([
                UsageRecord(event: .launched, isVerification: true)
            ], identity: identity, projectToken: FluxUsageProject.token)
            let response = try await transport.send(.init(endpoint: .events, body: body,
                                                          projectToken: FluxUsageProject.token))
            guard PostHogWire.ratingAcknowledgement(response) == .accepted else {
                emit("rejected", mode: mode)
                exit(1)
            }
        } else {
            let value = try PostHogClient(projectToken: FluxUsageProject.token, identity: identity,
                transport: transport, flushDelay: .seconds(120), isVerification: true)
            client = value
            await value.record(.launched)
            await value.flush()
        }
        emit("quietStarted", mode: mode)
        try await Task.sleep(for: .seconds(seconds))
        await client?.disable()
        withExtendedLifetime(transport) {}
        emit("finished", mode: mode)
    }
}

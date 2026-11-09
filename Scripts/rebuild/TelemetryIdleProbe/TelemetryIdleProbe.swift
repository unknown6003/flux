// Diagnostic only. This executable is not bundled in Flux.
import Darwin
import Foundation
#if FLUX_TELEMETRY_IDLE_DIAGNOSTIC
@testable import FluxCore
import FluxTelemetryCurlProbe

private enum Mode: String {
    case idle
    case direct
    case client
    case curl
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
    let protocolCode: Int?
    let engine: String?
    let failureCode: Int?
}

private func emit(_ phase: String, mode: Mode, identity: UsageIdentity? = nil,
                  request: Int? = nil, status: Int? = nil, protocolCode: Int? = nil,
                  engine: String? = nil, failureCode: Int? = nil) {
    let value = Phase(phase: phase, mode: mode.rawValue, at: Date(),
        uptime: ProcessInfo.processInfo.systemUptime, processID: getpid(),
        distinctID: identity?.value.uuidString.lowercased(), request: request, status: status,
        protocolCode: protocolCode, engine: engine, failureCode: failureCode)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

private struct CurlProbeFailure: Error { let code: Int }

private actor TracedTransport: UsageTransport {
    private let native: NativeUsageTransport?
    private let foundation: FoundationUsageTransport?
    private let mode: Mode
    private var count = 0

    init(mode: Mode) {
        self.mode = mode
        native = mode == .client ? NativeUsageTransport(region: FluxUsageProject.region) : nil
        foundation = mode == .direct ? FoundationUsageTransport(region: FluxUsageProject.region) : nil
    }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        count += 1
        let number = count
        emit("requestStarted", mode: mode, request: number)
        do {
            let response: UsageResponse
            var protocolCode: Int?
            if mode == .curl {
                let result = try await Task.detached(priority: .utility) {
                    guard request.endpoint == .events else { throw CurlProbeFailure(code: -1) }
                    var result = FluxCurlProbeResult()
                    request.body.withUnsafeBytes { bytes in
                        FluxCurlProbePost(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &result)
                    }
                    guard result.code == 0 else { throw CurlProbeFailure(code: Int(result.code)) }
                    let length = Int(result.length)
                    guard length <= PostHogWire.maximumResponseBytes else { throw CurlProbeFailure(code: -2) }
                    var body = Data(count: length)
                    let copied = body.withUnsafeMutableBytes { bytes in
                        FluxCurlProbeCopyBody(&result, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
                    }
                    guard copied == length else { throw CurlProbeFailure(code: -4) }
                    return (UsageResponse(status: Int(result.status), body: body), Int(result.protocol_code))
                }.value
                response = result.0
                protocolCode = result.1
            } else {
                if let foundation { response = try await foundation.send(request) }
                else if let native { response = try await native.send(request) }
                else { throw CurlProbeFailure(code: -3) }
            }
            emit("requestFinished", mode: mode, request: number, status: response.status, protocolCode: protocolCode)
            return response
        } catch {
            emit("requestFailed", mode: mode, request: number, failureCode: (error as? CurlProbeFailure)?.code)
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
            FileHandle.standardError.write(Data("Expected an enabled diagnostic and idle|direct|client|curl with hold seconds 1...120\n".utf8))
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
        let engine = mode == .curl ? String(cString: FluxCurlProbeVersion()) : nil
        emit("ready", mode: mode, identity: identity, engine: engine)
        if mode != .client {
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
#else
@main private struct DisabledTelemetryIdleProbe {
    static func main() {
        FileHandle.standardError.write(Data("The telemetry lifetime diagnostic is not enabled in this build\n".utf8))
        exit(2)
    }
}
#endif

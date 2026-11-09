import Foundation
import FluxHTTP

public enum UsageEndpoint: Sendable, Equatable {
    case events, flags, logs
}

public struct UsageRequest: Sendable {
    public let endpoint: UsageEndpoint
    public let body: Data
    public let projectToken: String
}

public struct UsageResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public protocol UsageTransport: Sendable {
    func send(_ request: UsageRequest) async throws -> UsageResponse
}

public enum UsageTransportFailure: Error, Sendable, Equatable {
    case busy, invalidRequest, network, unavailable
}

private final class UsageTransfer: @unchecked Sendable {
    // The C token permits concurrent cancellation. The worker and cancellation
    // handler retain this owner until neither can access the pointer.
    let pointer: OpaquePointer

    init() throws {
        guard let pointer = FluxHTTPCreate() else { throw UsageTransportFailure.unavailable }
        self.pointer = pointer
    }

    deinit { FluxHTTPDestroy(pointer) }
    func cancel() { FluxHTTPCancel(pointer) }
}

public actor NativeUsageTransport: UsageTransport {
    private let region: PostHogRegion
    private let queue = DispatchQueue(label: "Flux.usage.http", qos: .utility)
    private let fixturePort: UInt16
    private let fixtureCAPath: String
    private var busy = false

    public init(region: PostHogRegion) {
        self.region = region
        fixturePort = 0
        fixtureCAPath = ""
    }

    // A local TLS fixture changes the connection, never the requested host or
    // TLS verification. No app setting, environment variable or public init
    // can supply this override.
    init(region: PostHogRegion, fixturePort: UInt16, fixtureCAPath: String) {
        self.region = region
        self.fixturePort = fixturePort
        self.fixtureCAPath = fixtureCAPath
    }

    public func send(_ payload: UsageRequest) async throws -> UsageResponse {
        try Task.checkCancellation()
        guard !busy else { throw UsageTransportFailure.busy }
        guard !payload.body.isEmpty, payload.body.count <= 65_536 else {
            throw UsageTransportFailure.invalidRequest
        }
        let transfer = try UsageTransfer()
        let regionCode: Int32
        switch region {
        case .eu: regionCode = 0
        case .us: regionCode = 1
        }
        let endpointCode: Int32
        switch payload.endpoint {
        case .events: endpointCode = 0
        case .flags: endpointCode = 1
        case .logs: endpointCode = 2
        }
        let port = fixturePort
        let caPath = fixtureCAPath
        busy = true
        defer { busy = false }
        let response: UsageResponse
        do {
            response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    // Blocking DNS/TLS/HTTP stays off the main actor and Swift's
                    // cooperative executor. One transfer per transport is admitted.
                    queue.async {
#if FLUX_PERFORMANCE_TRACE
                        switch payload.endpoint {
                        case .events: PerformanceTrace.record(.httpEventsStarted)
                        case .flags: PerformanceTrace.record(.httpFlagsStarted)
                        case .logs: PerformanceTrace.record(.httpLogsStarted)
                        }
#endif
                        let code = payload.body.withUnsafeBytes { bytes in
                            payload.projectToken.withCString { token in
                                caPath.withCString { ca in
                                    FluxHTTPPerform(transfer.pointer, regionCode, endpointCode,
                                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
                                        token, port, port == 0 ? nil : ca)
                                }
                            }
                        }
#if FLUX_PERFORMANCE_TRACE
                        if code == Int32(FluxHTTPCancelled.rawValue) {
                            PerformanceTrace.record(.httpCancelled)
                        } else if code == Int32(FluxHTTPSuccess.rawValue) {
                            let status = FluxHTTPStatus(transfer.pointer)
                            if (200..<300).contains(status) { PerformanceTrace.record(.httpSucceeded) }
                            else if status == 429 || status >= 500 { PerformanceTrace.record(.httpRetryable) }
                            else { PerformanceTrace.record(.httpRejected) }
                        } else { PerformanceTrace.record(.httpFailed) }
#endif
                        do {
                            switch code {
                            case Int32(FluxHTTPSuccess.rawValue): break
                            case Int32(FluxHTTPCancelled.rawValue): throw CancellationError()
                            case Int32(FluxHTTPInvalidRequest.rawValue): throw UsageTransportFailure.invalidRequest
                            case Int32(FluxHTTPOversizedResponse.rawValue): throw PostHogWireError.oversizedResponse
                            case Int32(FluxHTTPUnavailable.rawValue): throw UsageTransportFailure.unavailable
                            default: throw UsageTransportFailure.network
                            }
                            let count = FluxHTTPBodyLength(transfer.pointer)
                            guard count <= PostHogWire.maximumResponseBytes else {
                                throw PostHogWireError.oversizedResponse
                            }
                            var body = Data(count: count)
                            let copied = body.withUnsafeMutableBytes { bytes in
                                FluxHTTPCopyBody(transfer.pointer,
                                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
                            }
                            guard copied == count else { throw PostHogWireError.invalidResponse }
                            continuation.resume(returning: UsageResponse(
                                status: Int(FluxHTTPStatus(transfer.pointer)), body: body))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { transfer.cancel() }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return response
    }
}

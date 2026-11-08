import Foundation

/// The only values product code may submit to the analytics client.
/// Content, app identities and arbitrary property dictionaries have no entry point.
public enum UsageEvent: Sendable, Equatable {
    public enum Feature: String, Sendable, CaseIterable {
        case menuBar, notch, nowPlaying, calendar, shelf, mirror, clipboard, settings, timer
    }

    public enum Action: String, Sendable, CaseIterable {
        case reveal, collapse, changeGroup, arrange, permissionRequest, update, resetAnalyticsID
    }

    public enum Result: String, Sendable, CaseIterable {
        case succeeded, declined, cancelled, unavailable, failed
    }

    public enum Failure: String, Sendable, CaseIterable {
        case visibilityUnavailable, policyConflict, permissionDenied, updateFailed, serviceUnavailable
    }

    case launched
    case opened(Feature)
    case completed(Action, Result)
    case failed(Failure)

    var name: String {
        switch self {
        case .launched: "flux_launched"
        case .opened: "flux_feature_opened"
        case .completed: "flux_action_completed"
        case .failed: "flux_operation_failed"
        }
    }

    var properties: [String: String] {
        switch self {
        case .launched: [:]
        case .opened(let feature): ["feature": feature.rawValue]
        case .completed(let action, let result): ["action": action.rawValue, "result": result.rawValue]
        case .failed(let failure): ["failure_code": failure.rawValue]
        }
    }
}

/// A random local identifier. It has no relationship to an account or OS identifier.
/// It still links events, so it must not be described as unlinkable data.
public struct UsageIdentity: Sendable, Equatable {
    public let value: UUID

    public init(value: UUID = UUID()) {
        self.value = value
    }
}

public enum PostHogRegion: Sendable {
    case us, eu

    public var host: URL {
        switch self {
        case .us: URL(string: "https://us.i.posthog.com")!
        case .eu: URL(string: "https://eu.i.posthog.com")!
        }
    }
}

public struct UsageRecord: Sendable, Equatable {
    public let id: UUID
    public let event: UsageEvent
    public let time: Date

    public init(id: UUID = UUID(), event: UsageEvent, time: Date = Date()) {
        self.id = id
        self.event = event
        self.time = time
    }
}

public enum UsageEncodingError: Error {
    case invalidProjectToken, tooManyRecords, invalidTime
}

/// This is an explicit PostHog wire format. Encoding cannot inspect ambient app or device state.
public enum UsageBatchEncoder {
    public static let maximumRecords = 64

    public static func encode(
        _ records: [UsageRecord], identity: UsageIdentity, projectToken: String
    ) throws -> Data {
        guard !projectToken.isEmpty, projectToken.utf8.count <= 256,
              projectToken.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { throw UsageEncodingError.invalidProjectToken }
        guard records.count <= maximumRecords else { throw UsageEncodingError.tooManyRecords }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let events: [[String: Any]] = try records.map { record in
            guard record.time.timeIntervalSince1970.isFinite else { throw UsageEncodingError.invalidTime }
            var properties: [String: Any] = record.event.properties
            properties["$process_person_profile"] = false
            properties["$geoip_disable"] = true
            return [
                "event": record.event.name,
                "distinct_id": identity.value.uuidString.lowercased(),
                "uuid": record.id.uuidString.lowercased(),
                "timestamp": formatter.string(from: record.time),
                "properties": properties
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["api_key": projectToken, "batch": events], options: [.sortedKeys])
    }
}

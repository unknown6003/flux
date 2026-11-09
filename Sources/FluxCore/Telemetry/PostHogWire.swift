import Foundation

/// Remote configuration may choose presentation only. It cannot control permissions,
/// collection policy, native visibility, updates or access to content.
public enum UsageFlag: String, Sendable, CaseIterable, Hashable {
    case welcomeLayout = "flux-welcome-layout"
    case arrangementGuide = "flux-arrangement-guide"
    case notchHints = "flux-notch-hints"
}

public enum UsageVariant: String, Sendable, CaseIterable, Hashable {
    case disabled, enabled, control, compact, guided

    var wireValue: Any {
        switch self {
        case .disabled: false
        case .enabled: true
        case .control, .compact, .guided: rawValue
        }
    }
}

public struct UsageFlagPayload: Sendable, Equatable {
    public let hintDelayMilliseconds: Int
}

public enum UsageRating: String, Sendable, CaseIterable {
    case one = "1", two = "2", three = "3", four = "4", five = "5"
}

public enum UsageLogCode: String, Sendable, CaseIterable {
    case serviceStarted, serviceStopped, visibilityPaused, updateVerified, migrationCompleted
}

public enum UsageLogLevel: Sendable {
    case info, warning, error

    var number: Int {
        switch self {
        case .info: 9
        case .warning: 13
        case .error: 17
        }
    }

    var text: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

public struct UsageLogRecord: Sendable {
    public let code: UsageLogCode
    public let level: UsageLogLevel
    public let time: Date

    public init(code: UsageLogCode, level: UsageLogLevel, time: Date = Date()) {
        self.code = code
        self.level = level
        self.time = time
    }
}

public enum PostHogWireError: Error, Equatable {
    case invalidResponse, quotaLimited, oversizedResponse, invalidTimestamp
}

public enum PostHogWire {
    public static let maximumResponseBytes = 65_536

    public static func flagsRequest(projectToken: String, identity: UsageIdentity) throws -> Data {
        // Reuse token validation. No ambient context is added on this separate request path.
        _ = try UsageBatchEncoder.encode([], identity: identity, projectToken: projectToken)
        return try JSONSerialization.data(withJSONObject: [
            "api_key": projectToken,
            "distinct_id": identity.value.uuidString.lowercased(),
            "geoip_disable": true
        ], options: [.sortedKeys])
    }

    public static func flagsResponse(_ data: Data) throws -> [UsageFlag: UsageVariant] {
        guard data.count <= maximumResponseBytes else { throw PostHogWireError.oversizedResponse }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = object["flags"] as? [String: [String: Any]]
        else { throw PostHogWireError.invalidResponse }
        if let quotas = object["quotaLimited"] as? [String], !quotas.isEmpty {
            throw PostHogWireError.quotaLimited
        }
        if object["errorsWhileComputingFlags"] as? Bool == true {
            throw PostHogWireError.invalidResponse
        }
        var result: [UsageFlag: UsageVariant] = [:]
        for flag in UsageFlag.allCases {
            guard let entry = flags[flag.rawValue], let enabled = entry["enabled"] as? Bool else { continue }
            if !enabled { result[flag] = .disabled }
            else if let raw = entry["variant"] as? String {
                if let variant = UsageVariant(rawValue: raw) { result[flag] = variant }
            } else { result[flag] = .enabled }
        }
        return result
    }

    public static func flagPayloads(_ data: Data) throws -> [UsageFlag: UsageFlagPayload] {
        let accepted = try flagsResponse(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = object["flags"] as? [String: [String: Any]]
        else { throw PostHogWireError.invalidResponse }
        var result: [UsageFlag: UsageFlagPayload] = [:]
        for flag in accepted.keys {
            guard let metadata = flags[flag.rawValue]?["metadata"] as? [String: Any],
                  let raw = metadata["payload"] as? String, raw.utf8.count <= 2_048,
                  let payload = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let delay = payload["hint_delay_ms"] as? Int, (500...5_000).contains(delay)
            else { continue }
            result[flag] = UsageFlagPayload(hintDelayMilliseconds: delay)
        }
        return result
    }

    public static func logs(_ records: [UsageLogRecord], identity: UsageIdentity, isVerification: Bool = false) throws -> Data {
        guard records.count <= UsageBatchEncoder.maximumRecords else { throw UsageEncodingError.tooManyRecords }
        let logs: [[String: Any]] = try records.map { record in
            let seconds = record.time.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < 18_000_000_000 else { throw PostHogWireError.invalidTimestamp }
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            return [
                "timeUnixNano": String(nanoseconds),
                "severityNumber": record.level.number,
                "severityText": record.level.text,
                "body": ["stringValue": record.code.rawValue],
                "attributes": [["key": "posthogDistinctId", "value": ["stringValue": identity.value.uuidString.lowercased()]]]
            ]
        }
        var resourceAttributes: [[String: Any]] = [["key": "service.name", "value": ["stringValue": "Flux"]]]
        if isVerification { resourceAttributes.append(["key": "flux_validation", "value": ["boolValue": true]]) }
        return try JSONSerialization.data(withJSONObject: [
            "resourceLogs": [[
                "resource": ["attributes": resourceAttributes],
                "scopeLogs": [["scope": ["name": "Flux"], "logRecords": logs]]
            ]]
        ], options: [.sortedKeys])
    }
}

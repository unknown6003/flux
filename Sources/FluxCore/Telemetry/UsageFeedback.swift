import Foundation

/// The fixed manual rating configured in Flux's PostHog project. These are
/// public survey identifiers, not credentials or installation identifiers.
public enum FluxRatingSurvey {
    public static let surveyID = UUID(uuidString: "01a1be49-73be-0000-0847-40b0937bb5da")!
    public static let questionID = UUID(uuidString: "3318e47e-87af-444d-9a1d-4e7cd3a8c58b")!
}

/// A retry token bound to one rating and the identity that created it.
/// Its IDs stay inside Core and cannot cross an analytics identity reset.
public struct UsageRatingSubmission: Sendable {
    let id: UUID
    let identity: UsageIdentity
    let rating: UsageRating

    init(rating: UsageRating, identity: UsageIdentity) {
        self.id = UUID()
        self.identity = identity
        self.rating = rating
    }
}

public enum UsageDeliveryResult: String, Sendable {
    case accepted, disabled, busy, limited, cancelled, failed
}

extension PostHogWire {
    static func ratingAcknowledgement(_ response: UsageResponse) -> UsageDeliveryResult {
        guard response.status == 200, response.body.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let status = object["status"] as? NSNumber,
              CFGetTypeID(status) != CFBooleanGetTypeID(), status.doubleValue == 1 else { return .failed }
        if let raw = object["quota_limited"] {
            guard let limited = raw as? [String] else { return .failed }
            if !limited.isEmpty { return .limited }
        }
        return .accepted
    }
}

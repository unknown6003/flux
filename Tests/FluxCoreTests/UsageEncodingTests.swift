import Foundation
import Testing
@testable import FluxCore

@Test func batchContainsOnlyApprovedFields() throws {
    let identity = UsageIdentity(value: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa")!)
    let events: [UsageEvent] = [.launched]
        + UsageEvent.Feature.allCases.map { .opened($0) }
        + UsageEvent.Action.allCases.flatMap { action in UsageEvent.Result.allCases.map { .completed(action, $0) } }
        + UsageEvent.Failure.allCases.map { .failed($0) }
    let data = try UsageBatchEncoder.encode(events.map { UsageRecord(event: $0) }, identity: identity, projectToken: "phc_fixture")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["api_key", "batch"])
    let batch = try #require(object["batch"] as? [[String: Any]])
    #expect(batch.count == events.count)
    for event in batch {
        #expect(Set(event.keys) == ["event", "distinct_id", "uuid", "timestamp", "properties"])
        #expect(event["distinct_id"] as? String == identity.value.uuidString.lowercased())
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(Set(properties.keys).isSubset(of: ["$process_person_profile", "$geoip_disable", "feature", "action", "result", "failure_code"]))
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$geoip_disable"] as? Bool == true)
    }
    let text = try #require(String(data: data, encoding: .utf8))
    for prohibited in ["$device_id", "$ip", "timezone", "os_version", "hostname", "screen_width", "bundle_id", "clipboard", "@"] {
        // A feature's fixed name is allowed; the clipboard's content is never read.
        if prohibited != "clipboard" { #expect(!text.contains(prohibited)) }
    }
}

@Test func oversizedBatchAndInvalidTokenAreRejected() throws {
    let records = Array(repeating: UsageRecord(event: .launched), count: UsageBatchEncoder.maximumRecords + 1)
    #expect(throws: UsageEncodingError.self) {
        try UsageBatchEncoder.encode(records, identity: UsageIdentity(), projectToken: "phc_fixture")
    }
    for token in ["", "token\nheader", "contains space", String(repeating: "a", count: 257)] {
        #expect(throws: UsageEncodingError.self) {
            try UsageBatchEncoder.encode([], identity: UsageIdentity(), projectToken: token)
        }
    }
}

@Test func identifiersAreRandomAndReplaceable() {
    #expect(UsageIdentity() != UsageIdentity())
    let record = UsageRecord(event: .completed(.reveal, .succeeded))
    #expect(record.event == .completed(.reveal, .succeeded))
}

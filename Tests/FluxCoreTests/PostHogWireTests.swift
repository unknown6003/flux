import Foundation
import Testing
@testable import FluxCore

@Test func flagRequestsContainNoAmbientContext() throws {
    let data = try PostHogWire.flagsRequest(projectToken: "phc_fixture", identity: UsageIdentity())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["api_key", "distinct_id", "geoip_disable"])
    #expect(object["geoip_disable"] as? Bool == true)
}

@Test func remoteFlagsCanOnlySelectKnownPresentationChoices() throws {
    let data = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"compact"},"collect-clipboard":{"enabled":true,"variant":"guided"},"flux-notch-hints":{"enabled":true,"variant":"person@example.com"},"flux-arrangement-guide":{"enabled":false,"variant":"guided"}}}"#.utf8)
    #expect(try PostHogWire.flagsResponse(data) == [.welcomeLayout: .compact])
    for response in [#"{"flags":{},"quotaLimited":["feature_flags"]}"#, #"{"flags":{},"errorsWhileComputingFlags":true}"#, #"{}"#] {
        #expect(throws: (any Error).self) { try PostHogWire.flagsResponse(Data(response.utf8)) }
    }
    #expect(throws: PostHogWireError.self) {
        try PostHogWire.flagsResponse(Data(repeating: 32, count: PostHogWire.maximumResponseBytes + 1))
    }
}

@Test func logsHaveOnlyFixedBodiesAndApprovedResourceAttributes() throws {
    let identity = UsageIdentity()
    let data = try PostHogWire.logs(UsageLogCode.allCases.map { UsageLogRecord(code: $0, level: .warning) }, identity: identity)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(root.keys) == ["resourceLogs"])
    let resources = try #require(root["resourceLogs"] as? [[String: Any]])
    #expect(resources.count == 1)
    let resource = try #require(resources[0]["resource"] as? [String: Any])
    let attributes = try #require(resource["attributes"] as? [[String: Any]])
    #expect(attributes.count == 1)
    #expect(attributes[0]["key"] as? String == "service.name")
    let scope = try #require(resources[0]["scopeLogs"] as? [[String: Any]])
    let logs = try #require(scope[0]["logRecords"] as? [[String: Any]])
    #expect(logs.count == UsageLogCode.allCases.count)
    for log in logs {
        #expect(Set(log.keys) == ["timeUnixNano", "severityNumber", "severityText", "body", "attributes"])
        let body = try #require(log["body"] as? [String: String])
        #expect(UsageLogCode(rawValue: try #require(body["stringValue"])) != nil)
        let attributes = try #require(log["attributes"] as? [[String: Any]])
        #expect(attributes.count == 1)
        #expect(attributes[0]["key"] as? String == "posthogDistinctId")
    }
}

@Test func remotePayloadCannotEnableContentOrPassAnArbitraryStringToTheApp() throws {
    let data = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"compact","metadata":{"payload":"{\"hint_delay_ms\":1500,\"collect_clipboard\":true,\"url\":\"https://person@example.com\"}"}},"flux-notch-hints":{"enabled":true,"variant":"guided","metadata":{"payload":"{\"hint_delay_ms\":999999999}"}}}}"#.utf8)
    let payloads = try PostHogWire.flagPayloads(data)
    #expect(payloads.count == 1)
    #expect(payloads[.welcomeLayout]?.hintDelayMilliseconds == 1500)
    #expect(payloads[.notchHints] == nil)
}

@Test func manualErrorGroupingUsesCodesAndNeverErrorDescriptions() throws {
    let data = try UsageBatchEncoder.encode([UsageRecord(event: .failed(.permissionDenied))], identity: UsageIdentity(), projectToken: "phc_fixture")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let batch = try #require(object["batch"] as? [[String: Any]])
    #expect(batch[0]["event"] as? String == "$exception")
    let properties = try #require(batch[0]["properties"] as? [String: Any])
    let exceptions = try #require(properties["$exception_list"] as? [[String: Any]])
    #expect(exceptions.count == 1)
    #expect(Set(exceptions[0].keys) == ["type", "value", "mechanism"])
    #expect(exceptions[0]["value"] as? String == "permissionDenied")
    #expect(properties["$exception_fingerprint"] as? String == "flux.permissionDenied")
}

@Test func surveysAcceptFixedRatingsAndOpaqueQuestionIdentifiersOnly() throws {
    let survey = UUID(), question = UUID(), submission = UUID()
    let data = try UsageBatchEncoder.encode([
        UsageRecord(event: .surveyAnswered(survey: survey, question: question, rating: .four, submission: submission))
    ], identity: UsageIdentity(), projectToken: "phc_fixture")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let batch = try #require(object["batch"] as? [[String: Any]])
    #expect(batch[0]["event"] as? String == "survey sent")
    let properties = try #require(batch[0]["properties"] as? [String: Any])
    #expect(Set(properties.keys) == ["$survey_id", "$survey_response_" + question.uuidString.lowercased(), "$survey_submission_id", "$survey_completed", "$process_person_profile", "$geoip_disable"])
    #expect(properties["$survey_response_" + question.uuidString.lowercased()] as? String == "4")
}

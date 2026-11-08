import Foundation
import Testing
@testable import FluxCore

private func nativeLocation(_ id: String) -> [String: Any] { ["bundle": ["_0": id]] }
private func nativeRow(_ id: String, allowed: Any = true) -> [Any] {
    [nativeLocation(id), ["location": nativeLocation(id), "menuItemLocations": [nativeLocation(id)],
                          "isAllowed": allowed, "future": ["preserve": 42]] as [String: Any]]
}
private func nativeDocument(_ rows: [Any]) throws -> NativeVisibilityDocument {
    try .init(data: PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0))
}
private func nativeArray(_ document: NativeVisibilityDocument) throws -> [Any] {
    try #require(PropertyListSerialization.propertyList(from: document.data, options: [], format: nil) as? [Any])
}

@Test func nativeOverrideChangesOneBooleanAndRestoresAgainstFreshUnrelatedEdits() throws {
    let id = try #require(ApplicationID(rawValue: "org.fluxfixture.alpha"))
    let rows = nativeRow(id.rawValue) + nativeRow("org.fluxfixture.beta")
    let baseline = try nativeDocument(rows)
    let lease = NativeVisibilityLease(application: id, entry: try baseline.inspect(id), written: false)
    let hidden = try baseline.applying(lease)
    #expect(try !hidden.inspect(id).allowed)
    var expected = rows
    var value = try #require(expected[1] as? [String: Any])
    value["isAllowed"] = false
    expected[1] = value
    #expect(try NSArray(array: nativeArray(hidden)).isEqual(to: expected))
    var fresh = try nativeArray(hidden)
    var other = try #require(fresh[3] as? [String: Any])
    other["future"] = ["preserve": 99]
    other["isAllowed"] = false
    fresh[3] = other
    let restored = try nativeDocument(fresh).restoring(lease)
    #expect(try restored.inspect(id).allowed)
    #expect(try NSDictionary(dictionary: #require(nativeArray(restored)[3] as? [String: Any])).isEqual(other))
    let encoded = try JSONEncoder().encode(lease)
    let decoded = try JSONDecoder().decode(NativeVisibilityLease.self, from: encoded)
    #expect(decoded.application == id)
    #expect(decoded.transaction == lease.transaction)
    #expect(try restored.restoring(decoded).data == restored.data)
}

@Test func nativeAliasesAndDuplicateKeysAreRefusedBeforeAnyEdit() throws {
    let id = try #require(ApplicationID(rawValue: "org.fluxfixture.alpha"))
    var alias = nativeRow("org.fluxfixture.beta")
    var value = try #require(alias[1] as? [String: Any])
    value["menuItemLocations"] = [nativeLocation(id.rawValue)]
    alias[1] = value
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(nativeRow(id.rawValue) + alias).inspect(id) }
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(nativeRow(id.rawValue) + nativeRow(id.rawValue)).inspect(id) }
    let path = URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example")
    let binary: [String: Any] = ["adhocBinary": ["_0": ["relative": path.absoluteString]]]
    let binaryRow: [Any] = [binary, ["location": binary, "menuItemLocations": [binary], "isAllowed": true]]
    let document = try nativeDocument(nativeRow(id.rawValue) + binaryRow)
    #expect(throws: NativeVisibilityError.self) { try document.inspect(id, executableURLs: [path]) }
}

@Test func malformedAndNewNativeSchemasDoNotGuessOwnership() throws {
    let id = try #require(ApplicationID(rawValue: "org.fluxfixture.alpha"))
    #expect(throws: NativeVisibilityError.self) { try nativeDocument([nativeLocation(id.rawValue)]) }
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(nativeRow(id.rawValue, allowed: 1)) }
    let system = try #require(ApplicationID(rawValue: "com.apple.controlcenter"))
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(nativeRow(system.rawValue)).inspect(system) }
    var changed = nativeRow(id.rawValue)
    var value = try #require(changed[1] as? [String: Any])
    value["location"] = ["newLocationKind": ["_0": "unknown"]]
    changed[1] = value
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(changed).inspect(id) }
}

@Test func nativeRestoreRejectsChangedLocationIdentityAndStaleExpectation() throws {
    let id = try #require(ApplicationID(rawValue: "org.fluxfixture.alpha"))
    let baseline = try nativeDocument(nativeRow(id.rawValue))
    let lease = NativeVisibilityLease(application: id, entry: try baseline.inspect(id), written: false)
    let hidden = try baseline.applying(lease)
    #expect(throws: NativeVisibilityError.self) { try hidden.applying(lease) }
    var rows = try nativeArray(hidden)
    var value = try #require(rows[1] as? [String: Any])
    value["menuItemLocations"] = [nativeLocation("org.fluxfixture.changed")]
    rows[1] = value
    #expect(throws: NativeVisibilityError.self) { try nativeDocument(rows).restoring(lease) }
}

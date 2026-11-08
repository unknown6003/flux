import CoreFoundation
import Foundation

public struct Preference<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value
    public let newProfileDefault: Value
    private let decode: @Sendable (Any) -> Value?
    private let encode: @Sendable (Value) -> Any

    private init(
        _ key: String, legacy: Value, new: Value? = nil,
        decode: @escaping @Sendable (Any) -> Value?,
        encode: @escaping @Sendable (Value) -> Any
    ) {
        self.key = key
        defaultValue = legacy
        newProfileDefault = new ?? legacy
        self.decode = decode
        self.encode = encode
    }

    public func value(from stored: Any?) -> Value? { stored.flatMap(decode) }

    func propertyList(_ value: Value) throws -> Any {
        let raw = encode(value)
        guard decode(raw) != nil else { throw PreferenceError.invalidValue(key) }
        return raw
    }

    var registration: PreferenceRegistration {
        PreferenceRegistration(key: key) { isNew in
            encode(isNew ? newProfileDefault : defaultValue)
        }
    }
}

extension Preference where Value == Bool {
    static func boolean(_ key: String, _ legacy: Bool, new: Bool? = nil) -> Self {
        Self(key, legacy: legacy, new: new, decode: { raw in
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }, encode: { $0 })
    }
}

extension Preference where Value == Double {
    static func duration(_ key: String, _ legacy: Double) -> Self {
        Self(key, legacy: legacy, decode: { raw in
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue
        }, encode: { $0 })
    }
}

extension Preference where Value == UInt32 {
    static func unsignedInteger(_ key: String, _ legacy: UInt32) -> Self {
        Self(key, legacy: legacy, decode: { raw in
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = UInt32(exactly: number.doubleValue) else { return nil }
            return integer
        }, encode: { Int($0) })
    }
}

extension Preference where Value: RawRepresentable, Value.RawValue == String {
    static func choice(_ key: String, _ legacy: Value) -> Self {
        Self(key, legacy: legacy, decode: { raw in
            (raw as? String).flatMap(Value.init(rawValue:))
        }, encode: { $0.rawValue })
    }
}

extension Preference where Value == [String] {
    static func strings(_ key: String, _ legacy: [String]) -> Self {
        Self(key, legacy: legacy, decode: { $0 as? [String] }, encode: { $0 })
    }
}

struct PreferenceRegistration: Sendable {
    let key: String
    let value: @Sendable (_ isNewProfile: Bool) -> Any
}

public enum PreferenceError: Error {
    case invalidValue(String)
}

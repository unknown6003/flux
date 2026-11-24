public enum VolumeKey: Hashable, Sendable { case up, down, mute }

public enum BrightnessKey: Hashable, Sendable { case up, down }

public struct BrightnessSnapshot: Equatable, Sendable {
    public let level: Float
    public let adjustable: Bool

    public init(level: Float, adjustable: Bool = true) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.adjustable = adjustable
    }
}

/// The sound-key part of an NX auxiliary-control packet. Other key codes and
/// unknown phases stay with macOS. Modifier flags are handled by the tap.
public struct VolumeKeyPacket: Equatable, Sendable {
    public let key: VolumeKey
    public let down: Bool
    public let repeated: Bool

    public init?(data1: Int64) {
        let bits = UInt32(truncatingIfNeeded: data1)
        switch (bits >> 16) & 0xffff {
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return nil
        }
        switch (bits >> 8) & 0xff {
        case 0x0a: down = true
        case 0x0b: down = false
        default: return nil
        }
        repeated = bits & 1 != 0
    }
}

/// The brightness-key part of an NX auxiliary-control packet (`NX_KEYTYPE_BRIGHTNESS_UP = 2`,
/// `NX_KEYTYPE_BRIGHTNESS_DOWN = 3`).
public struct BrightnessKeyPacket: Equatable, Sendable {
    public let key: BrightnessKey
    public let down: Bool
    public let repeated: Bool

    public init?(data1: Int64) {
        let bits = UInt32(truncatingIfNeeded: data1)
        switch (bits >> 16) & 0xffff {
        case 2: key = .up
        case 3: key = .down
        default: return nil
        }
        switch (bits >> 8) & 0xff {
        case 0x0a: down = true
        case 0x0b: down = false
        default: return nil
        }
        repeated = bits & 1 != 0
    }
}

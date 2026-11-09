public enum VolumeKey: Hashable, Sendable { case up, down, mute }

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

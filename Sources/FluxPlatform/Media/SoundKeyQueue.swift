import FluxCore

/// Admission for one key burst. Overflow hands the rest of that burst to
/// macOS, including its bezel, until an explicit access refresh.
struct SoundKeyQueue {
    enum Command: Equatable { case adjust(Float), mute }
    private(set) var commands: [Command] = []
    private(set) var blocked = false

    mutating func offer(_ key: VolumeKey, repeated: Bool, fine: Bool, output: VolumeSnapshot?) -> Bool {
        guard !blocked, output?.supports(key) == true else { return false }
        if key == .mute, repeated { return true }
        guard commands.count < 32 else { blocked = true; return false }
        switch key {
        case .up: commands.append(.adjust(fine ? 1 / 64 : 1 / 16))
        case .down: commands.append(.adjust(fine ? -1 / 64 : -1 / 16))
        case .mute: commands.append(.mute)
        }
        return true
    }

    mutating func next() -> Command? { commands.isEmpty ? nil : commands.removeFirst() }
    mutating func refresh() { blocked = false }
    mutating func fail() { commands.removeAll(); blocked = true }
}

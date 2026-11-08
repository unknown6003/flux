public struct PowerSnapshot: Equatable, Sendable {
    public let percent: Int
    public let charging: Bool
    public let externalPower: Bool

    public init(percent: Int, charging: Bool, externalPower: Bool) {
        self.percent = min(max(percent, 0), 100)
        self.charging = charging
        self.externalPower = externalPower
    }
}

public enum PowerTransition: Equatable, Sendable {
    case connected(Int), disconnected(Int), low(Int), recovered
}

/// Low battery is a current level, including after a service restart. Plug
/// notifications require two samples. The 20/25 band prevents noisy warnings.
public struct PowerTransitions: Sendable {
    private var previous: PowerSnapshot?
    private var low = false
    public init() {}

    public mutating func accept(_ snapshot: PowerSnapshot) -> [PowerTransition] {
        defer { previous = snapshot }
        var events: [PowerTransition] = []
        if let previous, previous.externalPower != snapshot.externalPower {
            events.append(snapshot.externalPower ? .connected(snapshot.percent) : .disconnected(snapshot.percent))
        }
        if snapshot.externalPower || snapshot.percent >= 25 {
            if low { events.append(.recovered) }
            low = false
        } else if snapshot.percent <= 20 {
            if !low || previous?.percent != snapshot.percent { events.append(.low(snapshot.percent)) }
            low = true
        }
        return events
    }
}

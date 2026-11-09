import Foundation
import FluxCore

/// One audio listener plus an optional permitted key filter. Key repeats queue
/// at most 32 small commands; a full queue leaves new input with macOS.
@MainActor public final class SoundHUDFeed: FeatureServiceHandle {
    private enum Command { case adjust(Float), mute }
    private var feed: VolumeFeed?
    private var tap: VolumeKeyTap?
    private var snapshot: VolumeSnapshot?
    private var pending: [Command] = []
    private var command: Task<Void, Never>?
    private var receive: ((VolumeSnapshot?, Bool) -> Void)?
    private var failed: (() -> Void)?
    private var active = true
    private var blocked = false

    public init(receive: @escaping (VolumeSnapshot?, Bool) -> Void, failed: @escaping () -> Void) {
        self.receive = receive; self.failed = failed
        tap = VolumeKeyTap(canControl: { [weak self] in self?.snapshot?.adjustable == true },
                           keyDown: { [weak self] in self?.enqueue($0, repeated: $1, fine: $2) ?? false })
        feed = VolumeFeed { [weak self] in self?.changed($0) }
    }

    deinit { command?.cancel() }

    public func refreshAccess() {
        guard active else { return }
        blocked = false
        updateTap()
    }
    public func adjust(by delta: Float) async -> Bool {
        guard active, let feed else { return false }
        let success = await feed.adjust(by: delta)
        if success, let state = await feed.current(), active { snapshot = state; receive?(state, true) }
        return success
    }
    public func toggleMute() async -> Bool {
        guard active, let feed else { return false }
        let success = await feed.toggleMute()
        if success, let state = await feed.current(), active { snapshot = state; receive?(state, true) }
        return success
    }
    public func stop() {
        guard active else { return }
        active = false
        tap?.stop(); tap = nil
        pending.removeAll(); command?.cancel(); command = nil
        feed?.stop(); feed = nil
        receive = nil; failed = nil; snapshot = nil
    }

    private func changed(_ state: VolumeSnapshot?) {
        guard active else { return }
        let initial = snapshot == nil
        snapshot = state
        updateTap()
        if initial || tap?.isActive == true { receive?(state, false) }
    }
    private func updateTap() {
        if !blocked, snapshot?.adjustable == true { _ = tap?.start() } else { tap?.stop() }
    }
    private func enqueue(_ key: VolumeKey, repeated: Bool, fine: Bool) -> Bool {
        guard active, snapshot?.adjustable == true, pending.count < 32 else { return false }
        if key == .mute, repeated { return true }
        switch key {
        case .up: pending.append(.adjust(fine ? 1 / 64 : 1 / 16))
        case .down: pending.append(.adjust(fine ? -1 / 64 : -1 / 16))
        case .mute: pending.append(.mute)
        }
        drain()
        return true
    }
    private func drain() {
        guard active, command == nil, !pending.isEmpty, let feed else { return }
        let next = pending.removeFirst()
        command = Task { @MainActor [weak self] in
            let success: Bool
            switch next {
            case .adjust(let delta): success = await feed.adjust(by: delta)
            case .mute: success = await feed.toggleMute()
            }
            let state = success ? await feed.current() : nil
            guard let self, self.active, !Task.isCancelled else { return }
            self.command = nil
            if success {
                if let state { self.snapshot = state; self.receive?(state, true) }
                self.drain()
            } else {
                self.pending.removeAll()
                self.blocked = true
                self.tap?.stop()
                self.failed?()
            }
        }
    }
}

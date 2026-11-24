import Foundation
import FluxCore

/// One audio/brightness listener plus an optional permitted key filter. Key repeats
/// queue at most 32 small commands; a full queue leaves new input with macOS.
@MainActor public final class SoundHUDFeed: FeatureServiceHandle {
    private var feed: VolumeFeed?
    private let brightness = BrightnessController()
    private var tap: VolumeKeyTap?
    private var snapshot: VolumeSnapshot?
    private var queue = SoundKeyQueue()
    private var command: Task<Void, Never>?
    private var receive: ((VolumeSnapshot?, Bool) -> Void)?
    private var receiveBrightness: ((BrightnessSnapshot?) -> Void)?
    private var failed: (() -> Void)?
    private var active = true

    public init(receive: @escaping (VolumeSnapshot?, Bool) -> Void,
                receiveBrightness: ((BrightnessSnapshot?) -> Void)? = nil,
                failed: @escaping () -> Void) {
        self.receive = receive
        self.receiveBrightness = receiveBrightness
        self.failed = failed
        tap = VolumeKeyTap(
            canControl: { [weak self] in self?.snapshot.map { $0.adjustable || $0.muteAdjustable } == true },
            keyDown: { [weak self] in self?.enqueue($0, repeated: $1, fine: $2) ?? false },
            canControlBrightness: { [weak self] in self?.canControlBrightness ?? false },
            brightnessKeyDown: { [weak self] in self?.handleBrightness($0, fine: $2) ?? false }
        )
        feed = VolumeFeed { [weak self] in self?.changed($0) }
        updateTap()
    }

    deinit { command?.cancel() }

    private var canControlBrightness: Bool {
        active && receiveBrightness != nil && brightness.isAvailable
    }

    public func refreshAccess() {
        guard active else { return }
        queue.refresh()
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
        queue.fail(); command?.cancel(); command = nil
        feed?.stop(); feed = nil
        receive = nil; receiveBrightness = nil; failed = nil; snapshot = nil
    }

    private func changed(_ state: VolumeSnapshot?) {
        guard active else { return }
        let initial = snapshot == nil
        snapshot = state
        updateTap()
        if initial || tap?.isActive == true { receive?(state, false) }
    }
    private func updateTap() {
        let audioReady = !queue.blocked && snapshot.map({ $0.adjustable || $0.muteAdjustable }) == true
        if audioReady || canControlBrightness { _ = tap?.start() } else { tap?.stop() }
    }
    private func handleBrightness(_ key: BrightnessKey, fine: Bool) -> Bool {
        guard canControlBrightness else { return false }
        let step: Float = fine ? (1 / 64) : (1 / 16)
        let delta: Float = key == .up ? step : -step
        guard let updated = brightness.adjust(by: delta) else { return false }
        receiveBrightness?(updated)
        return true
    }
    private func enqueue(_ key: VolumeKey, repeated: Bool, fine: Bool) -> Bool {
        guard active else { return false }
        guard queue.offer(key, repeated: repeated, fine: fine, output: snapshot) else {
            // Native handling takes over for this burst. Do not draw our HUD
            // over the system bezel while earlier accepted commands drain.
            if queue.blocked { tap?.stop() }
            return false
        }
        drain()
        return true
    }
    private func drain() {
        guard active, command == nil, let feed, let next = queue.next() else { return }
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
                if let state {
                    self.snapshot = state
                    if self.tap?.isActive == true { self.receive?(state, true) }
                }
                self.drain()
            } else {
                self.queue.fail()
                self.tap?.stop()
                self.failed?()
            }
        }
    }
}

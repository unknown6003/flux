import AppKit
import ApplicationServices
import Foundation
import FluxCore

/// Only the monitor token crosses to the final main-actor cleanup task.
private struct CopyMonitorToken: @unchecked Sendable { let value: Any }

/// Runs only while collection is enabled and the session is unlocked.
/// Shortcut checks cover fast copies; a one-second fallback covers menu copies.
@MainActor public final class ClipboardFeed: FeatureServiceHandle {
    private let channel: any ClipboardChannel
    private var onCapture: ((ClipboardSample) -> Void)?
    private var monitors: [CopyMonitorToken] = []
    private var polling: Task<Void, Never>?
    private var shortcut: Task<Void, Never>?
    private var read: Task<Void, Never>?
    private var active = true
    private var lastChange: Int?
    private var suppressedChange: Int?
    private var readAgain = false
    private var writing = false

    public init(channel: any ClipboardChannel, observeShortcuts: Bool = true, onCapture: @escaping (ClipboardSample) -> Void) {
        self.channel = channel
        self.onCapture = onCapture
        if observeShortcuts { installMonitors() }
        polling = Task { @MainActor [weak self, channel] in
            let baseline = await channel.changeCount()
            self?.lastChange = baseline
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, self.active else { return }
                self.check()
            }
        }
    }

    deinit {
        polling?.cancel()
        shortcut?.cancel()
        read?.cancel()
        let tokens = monitors
        if !tokens.isEmpty {
            Task { @MainActor in for token in tokens { NSEvent.removeMonitor(token.value) } }
        }
    }

    public func suppressOwnWrite(changeCount: Int) { suppressedChange = changeCount }

    public func copyBack(_ payload: ClipboardPayload) async -> Bool {
        guard active, !writing else { return false }
        writing = true
        defer { writing = false; check() }
        guard let count = await channel.write(payload), active else { return false }
        suppressedChange = count
        return true
    }

    public func check() {
        guard active, lastChange != nil else { return }
        guard !writing else { readAgain = true; return }
        guard read == nil else { readAgain = true; return }
        let channel = channel
        read = Task { @MainActor [weak self] in
            let count = await channel.changeCount()
            guard !Task.isCancelled else { return }
            if self?.prepareCapture(count) == true {
                let sample = await channel.capture(expectedChange: count)
                guard let self, self.active, !Task.isCancelled else { return }
                if let sample { self.onCapture?(sample) }
            }
            self?.finishRead()
        }
    }

    public func stop() {
        guard active else { return }
        active = false
        onCapture = nil
        polling?.cancel(); polling = nil
        shortcut?.cancel(); shortcut = nil
        read?.cancel(); read = nil
        for token in monitors { NSEvent.removeMonitor(token.value) }
        monitors.removeAll()
        readAgain = false
    }

    private func prepareCapture(_ count: Int) -> Bool {
        guard active else { return false }
        guard !writing else { readAgain = true; return false }
        guard lastChange != count else { return false }
        lastChange = count
        defer { suppressedChange = nil }
        return suppressedChange != count
    }

    private func finishRead() {
        read = nil
        if readAgain { readAgain = false; check() }
    }

    private func installMonitors() {
        let detect: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.contains(.command), event.keyCode == 8 || event.keyCode == 7 else { return }
            Task { @MainActor [weak self] in self?.scheduleShortcutCheck() }
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in detect(event); return event }) {
            monitors.append(.init(value: token))
        }
        if AXIsProcessTrusted(), let token = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: detect) {
            monitors.append(.init(value: token))
        }
    }

    private func scheduleShortcutCheck() {
        shortcut?.cancel()
        shortcut = Task { @MainActor [weak self] in
            for delay in [0.06, 0.18] {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self, self.active else { return }
                self.check()
            }
        }
    }
}

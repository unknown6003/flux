import Foundation
import IOKit.ps
import FluxCore

public protocol PowerReading: Sendable {
    func read() async -> PowerSnapshot?
}

public actor SystemPowerReader: PowerReading {
    public init() {}
    public func read() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list.prefix(32) {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  current.doubleValue.isFinite, maximum.doubleValue.isFinite, maximum.doubleValue > 0 else { continue }
            let ratio = min(max(current.doubleValue / maximum.doubleValue, 0), 1)
            return PowerSnapshot(percent: Int((ratio * 100).rounded()),
                                 charging: (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false,
                                 externalPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

@MainActor private enum PowerCallbacks {
    static var next: UInt = 0
    static var actions: [UInt: @MainActor () -> Void] = [:]
}

/// The C context is an integer token, never a borrowed Swift object pointer.
/// A late callback looks up that token after teardown and finds no action.
private final class PowerSubscription: @unchecked Sendable {
    let id: UInt
    let source: CFRunLoopSource

    @MainActor init?(action: @escaping @MainActor () -> Void) {
        PowerCallbacks.next &+= 1
        if PowerCallbacks.next == 0 { PowerCallbacks.next = 1 }
        id = PowerCallbacks.next
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            let id = UInt(bitPattern: context)
            Task { @MainActor in PowerCallbacks.actions[id]?() }
        }, UnsafeMutableRawPointer(bitPattern: id))?.takeRetainedValue() else { return nil }
        self.source = source
        PowerCallbacks.actions[id] = action
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        CFRunLoopSourceInvalidate(source)
        let id = id
        Task { @MainActor in PowerCallbacks.actions[id] = nil }
    }
}

/// Power-source notifications trigger coalesced actor reads. No battery poll
/// runs while idle, and stopping drops every pending result and callback.
@MainActor public final class BatteryFeed: FeatureServiceHandle {
    private let reader: any PowerReading
    private var onChange: ((PowerSnapshot?) -> Void)?
    private var subscription: PowerSubscription?
    private var task: Task<Void, Never>?
    private var active = true
    private var again = false
    private var previous: PowerSnapshot?
    private var hasResult = false

    public init(reader: any PowerReading = SystemPowerReader(), observeChanges: Bool = true,
                onChange: @escaping (PowerSnapshot?) -> Void) {
        self.reader = reader
        self.onChange = onChange
        if observeChanges { subscription = PowerSubscription { [weak self] in self?.refresh() } }
        refresh()
    }

    deinit { task?.cancel() }

    public func refresh() {
        guard active else { return }
        guard task == nil else { again = true; return }
        let reader = reader
        task = Task { @MainActor [weak self] in
            let result = await reader.read()
            guard let self, self.active, !Task.isCancelled else { return }
            self.task = nil
            if !self.hasResult || self.previous != result {
                self.hasResult = true
                self.previous = result
                self.onChange?(result)
            }
            if self.again { self.again = false; self.refresh() }
        }
    }

    public func stop() {
        active = false
        task?.cancel(); task = nil
        subscription = nil
        onChange = nil
        again = false
    }
}

import Foundation
import Combine
import IOBluetooth
import IOKit
import OSLog

/// Shared logging point for the Bluetooth subsystem — mirrors `shelfLog`'s
/// file-scope-constant pattern rather than adding a new case to `Log.swift`,
/// since this is a self-contained M3 subsystem the notch suite owns.
let bluetoothLog = Logger(subsystem: "com.flux.menubar", category: "bluetooth")

/// A discrete Bluetooth connect/disconnect worth surfacing as a live
/// activity. `batteryPercent` is best-effort (see
/// `BluetoothMonitor.batteryPercent(for:)`) — `nil` just means "not
/// reported," not an error.
enum BluetoothEvent: Equatable {
    case connected(name: String, batteryPercent: Int?)
    case disconnected(name: String)
}

/// Watches `IOBluetoothDevice` connect/disconnect notifications for
/// audio/HID accessories (headphones, AirPods, keyboards, mice — not every
/// paired device; see `isRelevant`) and turns them into `BluetoothEvent`s
/// that `NotchActivityRouter` turns into live activities.
///
/// ## Why `NSObject`
/// IOBluetooth's notification APIs are old-style Cocoa target/selector, not
/// closures — `IOBluetoothDevice.register(forConnectNotifications:selector:)`
/// takes an `Any!` target and a `Selector!`, and delivers the callback as a
/// plain Objective-C message send to an `@objc` method on that target. That
/// target must be an `NSObject` subclass (a bare Swift class has no
/// Objective-C runtime identity to message), hence `BluetoothMonitor: NSObject`
/// rather than the plain `final class` used elsewhere in this codebase. (No
/// `ObservableObject` conformance either — nothing observes this type's state;
/// see the M3 review that dropped it.)
///
/// Unlike `PowerMonitor`'s raw `@convention(c)` callback (which categorically
/// cannot run on the main actor without an explicit assertion — see that
/// type's doc comment), these `@objc` methods are ordinary instance methods
/// on a `@MainActor` class receiving an Objective-C message send. Swift's
/// concurrency checker doesn't (can't) verify the caller's thread for a
/// dynamically-dispatched selector invoked from a C API, so the isolation
/// check is only load-bearing at compile time for statically-typed Swift
/// call sites — this is the same trust boundary as `Timer`'s closure-based
/// target-action or `NotificationCenter`'s block observers elsewhere in the
/// app: correctness rests on the framework's documented behavior (IOBluetooth
/// delivers on the run loop current at registration — main, here, since
/// `start()` is only ever called from app launch on the main actor) rather
/// than a compiler-checked guarantee.
@MainActor
final class BluetoothMonitor: NSObject {
    let events = PassthroughSubject<BluetoothEvent, Never>()

    /// Reconnect-storm dedupe window — see `isDuplicate(address:now:lastEventAt:)`.
    private static let dedupeWindow: TimeInterval = 5

    private var connectNotification: IOBluetoothUserNotification?
    /// Per-device disconnect registrations, keyed by the device's address
    /// string — installed the moment a device connects (`deviceConnected`),
    /// torn down the moment it disconnects or `stop()` runs.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Last time each device address produced an emitted event — the memory
    /// behind `isDuplicate`.
    private var lastEventAt: [String: Date] = [:]

    /// Registers the single, app-wide connect notification. No-op if already
    /// started.
    func start() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:)))
    }

    /// Unregisters every notification this monitor holds — the app-wide
    /// connect notification and every still-open per-device disconnect one —
    /// so a disabled monitor costs IOBluetooth nothing.
    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications.removeAll()
        lastEventAt.removeAll()
    }

    deinit {
        // `IOBluetoothUserNotification.unregister()` is a plain Objective-C
        // message with no dependency on this object's own (about-to-be-torn-
        // down) state, so it's safe to call from `deinit` the same way
        // `HotkeyManager.deinit` calls `RemoveEventHandler` directly.
        connectNotification?.unregister()
        for notification in disconnectNotifications.values { notification.unregister() }
    }

    // MARK: - IOBluetooth callbacks

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isRelevant(device) else { return }
        let name = device.name ?? "Bluetooth Device"
        let address = device.addressString ?? name

        // ALWAYS (re)register this device's disconnect notification, before
        // the dedupe guard below ever gets a chance to `return` early. This
        // registration must not be gated on `shouldEmit`: during a reconnect
        // storm, every connect after the first is deduped out of emitting an
        // event, but the disconnect notification `deviceDisconnected`
        // unregisters unconditionally (regardless of dedupe) the moment the
        // device actually disconnects — so if this connect callback skipped
        // re-registering because it was deduped, the device would end up with
        // no live disconnect observer at all for the rest of its session
        // (see the M3 review that caught this).
        //
        // Idempotent: only register when there's no entry already, i.e. the
        // device hasn't disconnected since it was last registered — there's
        // nothing stale to replace, so this never churns
        // unregister/re-register on every deduped connect in a storm.
        if disconnectNotifications[address] == nil {
            // `register(forDisconnectNotification:...)` returns an implicitly-
            // unwrapped optional that IOBluetooth genuinely can hand back
            // `nil` from (registration failure) — bound with `if let` rather
            // than assigned straight through, since the latter would
            // force-unwrap and crash on that failure path.
            if let disconnectNotification = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:device:))) {
                disconnectNotifications[address] = disconnectNotification
            } else {
                bluetoothLog.error("Failed to register disconnect notification for a connected device")
            }
        }

        guard shouldEmit(address: address) else { return }
        events.send(.connected(name: name, batteryPercent: Self.batteryPercent(for: device)))
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Bluetooth Device"
        let address = device.addressString ?? name
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = nil

        guard isRelevant(device) else { return }
        guard shouldEmit(address: address) else { return }
        events.send(.disconnected(name: name))
    }

    // MARK: - Filtering

    /// Only audio (headphones, AirPods, speakers) and HID (keyboards, mice,
    /// trackpads) accessories are worth a notch wing — every other paired
    /// device class (phones, other Macs, ...) is noise for this feature.
    private func isRelevant(_ device: IOBluetoothDevice) -> Bool {
        let major = device.deviceClassMajor
        return major == kBluetoothDeviceClassMajorAudio || major == kBluetoothDeviceClassMajorPeripheral
    }

    /// Records this address's event time and reports whether it should
    /// actually be emitted (i.e. wasn't a duplicate) — the instance-side
    /// wrapper around the pure `isDuplicate` predicate below.
    private func shouldEmit(address: String, now: Date = Date()) -> Bool {
        // Bound `lastEventAt`'s size: an address whose last event has already
        // aged out of the dedupe window carries no information `isDuplicate`
        // still needs, so it's pruned here rather than letting this
        // dictionary grow by one entry for every distinct device address
        // ever seen across the process's lifetime. No timer needed — this
        // piggybacks on the same call every event already makes.
        let cutoff = Self.dedupeWindow
        lastEventAt = lastEventAt.filter { now.timeIntervalSince($0.value) < cutoff }

        guard !Self.isDuplicate(address: address, now: now, lastEventAt: lastEventAt) else { return false }
        lastEventAt[address] = now
        return true
    }

    /// Pure predicate behind the reconnect-storm dedupe — extracted so
    /// `--selftest` can drive it directly, without a real `IOBluetoothDevice`.
    /// AirPods (and several other BT audio accessories) routinely emit a
    /// rapid disconnect/reconnect pair — switching audio sources, briefly
    /// leaving the case, a power blip — that has nothing to do with the user
    /// actually taking the device off; without this window, that pair would
    /// double-post a `.bluetoothDevice` live activity for a device that, from
    /// the user's perspective, never meaningfully disconnected.
    static func isDuplicate(address: String, now: Date, lastEventAt: [String: Date], window: TimeInterval = dedupeWindow) -> Bool {
        guard let last = lastEventAt[address] else { return false }
        return now.timeIntervalSince(last) < window
    }

    // MARK: - Battery (best-effort)

    /// Best-effort per-device battery percent read straight from IORegistry.
    /// AirPods (and many other Bluetooth HID/audio accessories) report their
    /// battery to macOS via a synthetic `AppleDeviceManagementHIDEventService`
    /// IOService, not through any supported IOBluetooth API — there is no
    /// `IOBluetoothDevice` property for this, so this walks every matching
    /// service in the registry and returns the first whose reported product
    /// name matches the device's own name. Returns `nil` both when nothing
    /// matched and when a matching service simply doesn't publish
    /// `BatteryPercent` — callers (`NotchActivityRouter`) treat both cases
    /// identically: omit the battery reading and fall back to showing the
    /// device name instead.
    static func batteryPercent(for device: IOBluetoothDevice) -> Int? {
        guard let deviceName = device.name else { return nil }
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return nil }

        var iterator: io_iterator_t = 0
        // `kIOMainPortDefault` is the modern (macOS 12+) name for the port
        // IOKit calls formerly spelled `kIOMasterPortDefault` — safe given
        // this app's `LSMinimumSystemVersion` of 14.0.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let productName = IORegistryEntryCreateCFProperty(
                entry, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                productName == deviceName
            else { continue }

            if let percent = IORegistryEntryCreateCFProperty(
                entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                return percent
            }
        }
        return nil
    }
}

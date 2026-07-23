import Foundation
import Combine
import IOKit
import CoreAudio
import OSLog

/// Shared logging point for the device-monitoring subsystem — mirrors
/// `powerLog`'s file-scope-constant pattern rather than adding a new case to
/// `Log.swift`, since this is a self-contained notch-suite subsystem.
let deviceLog = Logger(subsystem: "com.flux.menubar", category: "device")

/// Coarse device-class bucket for `NotchActivityRouter.deviceSymbol` — the
/// audio-vs-HID-peripheral split it switches on. The finer keyboard/mouse/
/// game-controller choice within `.peripheral` is still a name-based guess in
/// the router (there's no single registry field for it); this enum only has
/// to get the coarse bucket right. `.other` is a defensive fallback for a
/// Bluetooth accessory that couldn't be classified either way — the router
/// treats it the same as `.audio` (a generic headphones glyph), a sensible
/// default for the mostly-audio devices this monitor surfaces.
enum BluetoothDeviceCategory: Equatable {
    case audio
    case peripheral
    case other
}

/// A discrete Bluetooth connect/disconnect worth surfacing as a live
/// activity. `batteryPercent` is best-effort (see `DeviceMonitor`) — `nil`
/// just means "not reported," not an error. `category` carries the coarse
/// device class through so `NotchActivityRouter.deviceSymbol` doesn't have to
/// fall back to a name-only guess for the audio-vs-HID split.
///
/// The type/case names are kept from the pre-M10 `BluetoothMonitor` on
/// purpose: `NotchActivityRouter` consumes exactly these, so replacing the
/// TCC-gated monitor underneath with the permission-free `DeviceMonitor`
/// leaves the router's semantics untouched.
enum BluetoothEvent: Equatable {
    case connected(name: String, batteryPercent: Int?, category: BluetoothDeviceCategory)
    case disconnected(name: String, category: BluetoothDeviceCategory)
}

/// Permission-free replacement for the old `BluetoothMonitor`. It surfaces the
/// same audio/HID-accessory connect/disconnect `BluetoothEvent`s (headphones,
/// AirPods, keyboards, mice — see the transport filter) that
/// `NotchActivityRouter` turns into live activities, but **without ever
/// touching `IOBluetooth`** — so it never triggers macOS 12+'s Bluetooth TCC
/// prompt the way `IOBluetoothDevice.register(forConnectNotifications:)` did.
///
/// Two independent, both permission-free, sources feed the same events:
///
/// 1. **IOKit matching notifications** on `AppleDeviceManagementHIDEventService`
///    — the synthetic IOService AirPods and other BT accessories register, and
///    the same place their `BatteryPercent` already comes from (the old
///    monitor read it here too, permission-free). `kIOFirstMatchNotification`
///    fires when such a service appears (connect), `kIOTerminatedNotification`
///    when one vanishes (disconnect). This is the primary source and the only
///    one that can report battery + HID category.
///
/// 2. **CoreAudio** device-list diffing (`kAudioHardwarePropertyDevices`) —
///    catches Bluetooth *audio* devices that may register as a CoreAudio
///    output without exposing the HID service above. Only devices whose
///    `kAudioDevicePropertyTransportType` is Bluetooth/BluetoothLE count.
///
/// Both sources dedupe through the same name-keyed 5s window (`shouldEmit`),
/// so the common case — an AirPods connect that shows up via *both* IOKit and
/// CoreAudio at once — emits a single wing, not two. See `isDuplicate` for the
/// name-keying tradeoff.
///
/// ## The C-callback interop (IOKit)
/// `IOServiceAddMatchingNotification` takes a plain `@convention(c)`
/// `IOServiceMatchingCallback` that categorically cannot capture Swift context
/// — so, exactly like `PowerMonitor.start()`'s
/// `IOPSNotificationCreateRunLoopSource`, this uses the `Unmanaged` dance:
/// `Unmanaged.passUnretained(self).toOpaque()` is passed as the `refCon` at
/// registration, and reconstructed inside the callback via
/// `Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()`.
/// `passUnretained` (not `passRetained`) because `stop()`/`deinit` always
/// tear the notification port down before this object could be deallocated
/// while still registered — there is no ownership cycle to balance.
///
/// The callback fires on whatever run loop the notification port's source was
/// added to. `start()` always adds it to `CFRunLoopGetMain()`, so the callback
/// runs synchronously on the main thread — that guarantee is what makes
/// `MainActor.assumeIsolated` a true assertion, identical to `PowerMonitor`.
///
/// ## Draining (the arming requirement)
/// An IOKit matching-notification iterator MUST be fully drained
/// (`IOIteratorNext` until 0, releasing each entry) or the notification stops
/// firing. Both iterators are also drained once *at registration time* — those
/// initial entries are the already-connected baseline, deliberately **not**
/// emitted as connect events (`isInitialDrain: true`), so already-present
/// devices don't spam wings the instant the monitor starts.
@MainActor
final class DeviceMonitor {
    let events = PassthroughSubject<BluetoothEvent, Never>()

    /// The IOService class both AirPods/BT accessories register under and
    /// where `BatteryPercent` lives — same class the old monitor read battery
    /// from, now also its connect/disconnect signal.
    private static let serviceClass = "AppleDeviceManagementHIDEventService"

    /// Reconnect-storm + cross-source dedupe window — see `isDuplicate`.
    private static let dedupeWindow: TimeInterval = 5

    // MARK: IOKit state
    private var notificationPort: IONotificationPortRef?
    /// The two matching-notification iterators — held only so `stop()`/`deinit`
    /// can `IOObjectRelease` them. The live drains use the iterator IOKit hands
    /// the callback, which is the same handle.
    private var firstMatchIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    // MARK: CoreAudio state
    /// Held once and reused for removal — CoreAudio compares block *identity*,
    /// not equality, so the exact reference passed to `Add` must be handed back
    /// to `Remove` (the same wrinkle documented in `VolumeMonitor`).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    /// The BT audio devices last seen via CoreAudio, `AudioObjectID` → name.
    /// Names are cached because a *removed* device can no longer be queried for
    /// its name at diff time — it's already gone from the system.
    private var knownBluetoothAudioDevices: [AudioObjectID: String] = [:]

    /// Last time each device *name* produced an emitted event — the memory
    /// behind `isDuplicate` (shared across both sources).
    private var lastEventAt: [String: Date] = [:]

    // MARK: - Lifecycle

    /// Registers both IOKit matching notifications and the CoreAudio device-
    /// list listener, draining the initial baseline for each. No-op if already
    /// started. Must run on the main actor (guaranteed — `@MainActor`) since it
    /// adds the notification-port source to the *main* run loop.
    func start() {
        guard notificationPort == nil else { return }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            deviceLog.error("DeviceMonitor: failed to create IOKit notification port — connect/disconnect wings will only come from CoreAudio")
            // CoreAudio can still stand alone as a (BT-audio-only) source even
            // if the IOKit half failed to arm.
            startAudioListener()
            return
        }
        notificationPort = port

        // Deliver on the main run loop — see the type doc comment on why this
        // is what makes `MainActor.assumeIsolated` in the callbacks safe.
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()

        // A fresh matching dict per registration: `IOServiceAddMatchingNotification`
        // *consumes* a reference to the dict it's handed (same ownership rule
        // as `IOServiceGetMatchingServices`), so the two calls can't share one.
        if let firstMatch = IOServiceMatching(Self.serviceClass) {
            let status = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, firstMatch,
                { refCon, iterator in
                    guard let refCon else { return }
                    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()
                    // Safe (not hopeful): the port's source is only ever added
                    // to the main run loop, so this fires on the main thread.
                    MainActor.assumeIsolated { monitor.drain(iterator, isInitialDrain: false, event: .connect) }
                },
                context, &firstMatchIterator)
            if status == KERN_SUCCESS {
                // Arm the notification AND absorb the already-connected devices
                // as baseline (no wings) in one pass.
                drain(firstMatchIterator, isInitialDrain: true, event: .connect)
            } else {
                deviceLog.error("DeviceMonitor: failed to register first-match notification (kern_return_t \(status))")
            }
        }

        if let termMatch = IOServiceMatching(Self.serviceClass) {
            let status = IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification, termMatch,
                { refCon, iterator in
                    guard let refCon else { return }
                    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.drain(iterator, isInitialDrain: false, event: .disconnect) }
                },
                context, &terminatedIterator)
            if status == KERN_SUCCESS {
                drain(terminatedIterator, isInitialDrain: true, event: .disconnect)
            } else {
                deviceLog.error("DeviceMonitor: failed to register terminated notification (kern_return_t \(status))")
            }
        }

        startAudioListener()
    }

    /// Tears down every notification/listener this monitor holds and forgets
    /// all baseline/dedupe state, so a later `start()` begins clean.
    func stop() {
        guard notificationPort != nil || deviceListListenerBlock != nil else { return }

        stopAudioListener()

        if firstMatchIterator != 0 { IOObjectRelease(firstMatchIterator); firstMatchIterator = 0 }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator); terminatedIterator = 0 }
        if let port = notificationPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
        }
        notificationPort = nil

        lastEventAt.removeAll()
    }

    deinit {
        // Plain C/CoreAudio teardown calls with no dependency on this object's
        // own (about-to-be-torn-down) state — safe from a nonisolated `deinit`
        // the same way `PowerMonitor.deinit`/`VolumeMonitor.deinit` call their
        // raw teardown directly rather than routing through an instance method.
        if firstMatchIterator != 0 { IOObjectRelease(firstMatchIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        if let port = notificationPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
        }
        if let block = deviceListListenerBlock {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    // MARK: - IOKit draining + per-entry decision

    private enum EventKind { case connect, disconnect }

    /// Fully drains a matching-notification iterator (the arming requirement —
    /// see the type doc comment), processing each entry. `isInitialDrain` is
    /// `true` only for the registration-time baseline pass, which absorbs
    /// already-present devices without emitting.
    private func drain(_ iterator: io_iterator_t, isInitialDrain: Bool, event: EventKind) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            processEntry(entry, isInitialDrain: isInitialDrain, event: event)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private func processEntry(_ entry: io_registry_entry_t, isInitialDrain: Bool, event: EventKind) {
        let transport = Self.registryString(entry, "Transport")
        let builtIn = Self.registryBool(entry, "Built-In") ?? false
        guard Self.shouldEmitEvent(isInitialDrain: isInitialDrain, transport: transport, isBuiltIn: builtIn) else { return }

        let name = Self.registryString(entry, "Product") ?? "Bluetooth Device"
        guard shouldEmit(name: name) else { return }

        let category = Self.category(name: name, usagePairs: Self.usagePairs(for: entry))
        switch event {
        case .connect:
            // Battery is read straight off this exact entry — no name-walk
            // needed, unlike the CoreAudio path which only has an AudioObjectID.
            events.send(.connected(name: name, batteryPercent: Self.registryInt(entry, "BatteryPercent"), category: category))
        case .disconnect:
            events.send(.disconnected(name: name, category: category))
        }
    }

    /// Pure core of the "is this entry a real, surfaceable connect/disconnect,
    /// or baseline/noise" decision — extracted so `--selftest` drives every
    /// combination without real IOKit state. Absorbed (returns `false`) when:
    /// (1) it's the registration-time baseline drain (already-connected devices
    /// aren't fresh connects — no startup wing spam); (2) the device is
    /// Built-In/internal (Apple Internal Keyboard etc.); or (3) its transport
    /// isn't Bluetooth — which also excludes USB keyboards/mice and anything
    /// wired, exactly the devices a Bluetooth wing shouldn't announce.
    static func shouldEmitEvent(isInitialDrain: Bool, transport: String?, isBuiltIn: Bool) -> Bool {
        guard !isInitialDrain else { return false }
        guard !isBuiltIn else { return false }
        guard let transport, isBluetoothTransport(transport) else { return false }
        return true
    }

    /// Whether an IOKit HID `Transport` property string names a Bluetooth
    /// link. Accepts both "Bluetooth" and "Bluetooth Low Energy" (and is
    /// case-insensitive) via a substring match, which is also what excludes
    /// "USB"/"SPI"/"FIFO" wired and internal transports.
    static func isBluetoothTransport(_ transport: String) -> Bool {
        transport.lowercased().contains("bluetooth")
    }

    // MARK: - Category heuristic (pure, testable)

    /// Maps a device's advertised name + HID usage pairs onto the coarse
    /// `BluetoothDeviceCategory`. There's no single registry field that says
    /// "this is audio vs. a keyboard," so this is a documented best-effort
    /// heuristic, in priority order:
    ///
    /// 1. **Generic-Desktop HID usages win.** A `DeviceUsagePairs` entry on
    ///    usage page `0x01` for pointer/mouse/joystick/gamepad/keyboard/keypad
    ///    is the strongest possible signal it's an input peripheral — even for
    ///    devices that *also* expose consumer/media controls (a keyboard with
    ///    media keys), so this is checked first → `.peripheral`.
    /// 2. **Name audio hints** (airpods/headphone/headset/buds/beats/speaker/
    ///    audio) → `.audio`.
    /// 3. **Consumer-control page (`0x0C`) with no GD peripheral usage** →
    ///    `.audio` — typically a headset/remote control surface (AirPods
    ///    expose exactly this).
    /// 4. **Name peripheral hints** (keyboard/mouse/trackpad/controller/…) →
    ///    `.peripheral`.
    /// 5. Otherwise `.other` (the router treats it as audio — a safe default).
    static func category(name: String, usagePairs: [(page: Int, usage: Int)]) -> BluetoothDeviceCategory {
        let genericDesktop = 0x01
        let peripheralUsages: Set<Int> = [
            0x01, // Pointer
            0x02, // Mouse
            0x04, // Joystick
            0x05, // Game Pad
            0x06, // Keyboard
            0x07, // Keypad
        ]
        if usagePairs.contains(where: { $0.page == genericDesktop && peripheralUsages.contains($0.usage) }) {
            return .peripheral
        }

        let lower = name.lowercased()
        let audioHints = ["airpods", "headphone", "headset", "buds", "beats", "speaker", "audio"]
        if audioHints.contains(where: lower.contains) { return .audio }

        let consumerPage = 0x0C
        if usagePairs.contains(where: { $0.page == consumerPage }) { return .audio }

        let peripheralHints = ["keyboard", "mouse", "trackpad", "controller", "gamepad", "joystick"]
        if peripheralHints.contains(where: lower.contains) { return .peripheral }

        return .other
    }

    // MARK: - Dedupe (pure predicate + instance wrapper)

    /// Records this name's event time and reports whether it should actually be
    /// emitted (i.e. wasn't a duplicate). Also prunes aged-out entries so
    /// `lastEventAt` can't grow unbounded — piggybacking on the same call every
    /// event already makes, no timer needed (same shape as the old monitor).
    private func shouldEmit(name: String, now: Date = Date()) -> Bool {
        let cutoff = Self.dedupeWindow
        lastEventAt = lastEventAt.filter { now.timeIntervalSince($0.value) < cutoff }

        guard !Self.isDuplicate(name: name, now: now, lastEventAt: lastEventAt) else { return false }
        lastEventAt[name] = now
        return true
    }

    /// Pure predicate behind the reconnect-storm + cross-source dedupe.
    /// AirPods (and other BT accessories) routinely emit a rapid disconnect/
    /// reconnect pair that the user never meaningfully caused; without this
    /// window that pair would double-post. It ALSO collapses the same connect
    /// arriving via both IOKit and CoreAudio at once into one event.
    ///
    /// Keyed by **name**, not address: CoreAudio never exposes a device's BT
    /// address, so name is the only identifier both sources share. The
    /// tradeoff: two genuinely distinct devices sharing a name (e.g. two
    /// identical "AirPods") within 5s would be deduped to one wing — a rare,
    /// deliberately-accepted false merge in exchange for reliable cross-source
    /// dedupe of the overwhelmingly common single-device case.
    static func isDuplicate(name: String, now: Date, lastEventAt: [String: Date], window: TimeInterval = dedupeWindow) -> Bool {
        guard let last = lastEventAt[name] else { return false }
        return now.timeIntervalSince(last) < window
    }

    // MARK: - CoreAudio assist (Bluetooth audio devices)

    private func startAudioListener() {
        guard deviceListListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Runs on `DispatchQueue.main` (passed at registration below) — a
            // real guarantee, so `assumeIsolated` is a true assertion, exactly
            // as in `VolumeMonitor`.
            MainActor.assumeIsolated { self.handleAudioDevicesChanged() }
        }
        deviceListListenerBlock = block
        var address = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)

        // Seed the baseline WITHOUT emitting — already-connected BT audio
        // devices at start are not fresh connects.
        knownBluetoothAudioDevices = Self.currentBluetoothAudioDevices()
    }

    private func stopAudioListener() {
        guard let block = deviceListListenerBlock else { return }
        var address = Self.deviceListAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        deviceListListenerBlock = nil
        knownBluetoothAudioDevices.removeAll()
    }

    /// Diffs the current Bluetooth-audio device set against the last-seen one
    /// and emits connect/disconnect for the delta. Removed devices use their
    /// cached name (they're already gone and can't be re-queried).
    private func handleAudioDevicesChanged() {
        let current = Self.currentBluetoothAudioDevices()
        let previous = knownBluetoothAudioDevices

        for (id, name) in current where previous[id] == nil {
            guard shouldEmit(name: name) else { continue }
            // Best-effort battery via the same permission-free IORegistry
            // read the IOKit path uses — `nil` if this audio-only device has
            // no HID service publishing `BatteryPercent`.
            events.send(.connected(name: name, batteryPercent: Self.batteryPercent(forName: name), category: .audio))
        }
        for (id, name) in previous where current[id] == nil {
            guard shouldEmit(name: name) else { continue }
            events.send(.disconnected(name: name, category: .audio))
        }

        knownBluetoothAudioDevices = current
    }

    /// The current default+all audio devices whose transport is Bluetooth /
    /// Bluetooth LE, `AudioObjectID` → name.
    private static func currentBluetoothAudioDevices() -> [AudioObjectID: String] {
        var result: [AudioObjectID: String] = [:]
        for id in allAudioDevices() {
            guard let transport = transportType(id), isBluetoothTransport(transport) else { continue }
            result[id] = deviceName(id) ?? "Bluetooth Device"
        }
        return result
    }

    /// CoreAudio transport-type overload — the four-char-code form of the same
    /// question `isBluetoothTransport(_ transport: String)` answers for IOKit.
    static func isBluetoothTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - IORegistry property reads (pure)

    private static func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func registryInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }

    private static func registryBool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// Parses the HID `DeviceUsagePairs` array (array of
    /// `{DeviceUsagePage, DeviceUsage}` dicts) into plain `(page, usage)`
    /// tuples — empty when the property is absent or malformed.
    private static func usagePairs(for entry: io_registry_entry_t) -> [(page: Int, usage: Int)] {
        guard let raw = IORegistryEntryCreateCFProperty(entry, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let page = dict["DeviceUsagePage"] as? Int, let usage = dict["DeviceUsage"] as? Int else { return nil }
            return (page, usage)
        }
    }

    // MARK: - Battery (best-effort, by name — CoreAudio path only)

    /// Walks every `AppleDeviceManagementHIDEventService` in the registry and
    /// returns the `BatteryPercent` of the first whose `Product` name matches.
    /// Used only by the CoreAudio path, which has a device's name but not its
    /// IORegistry entry (the IOKit path reads battery straight off the entry it
    /// already holds). `nil` when nothing matched or the match publishes no
    /// battery — identical semantics to the old `BluetoothMonitor.batteryPercent`.
    static func batteryPercent(forName name: String) -> Int? {
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard registryString(entry, "Product") == name else { continue }
            if let percent = registryInt(entry, "BatteryPercent") { return percent }
        }
        return nil
    }

    // MARK: - Pure CoreAudio plumbing
    //
    // `nonisolated` where called from `deinit` (`deviceListAddress`) — the same
    // isolation-boundary reason `VolumeMonitor` marks its address constants
    // `nonisolated static`: a class `deinit` can't itself be actor-isolated, so
    // anything it calls must be reachable from a nonisolated context.

    private nonisolated static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                    mScope: kAudioObjectPropertyScopeGlobal,
                                    mElement: kAudioObjectPropertyElementMain)
    }

    private static func allAudioDevices() -> [AudioObjectID] {
        var address = deviceListAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    /// Reads `kAudioObjectPropertyName`, which returns a **+1-retained**
    /// `CFStringRef` in the property buffer (the Copy ownership rule) — hence
    /// the `Unmanaged<CFString>?` buffer + `takeRetainedValue()`, the memory-
    /// correct idiom for a CoreAudio property that hands back a CF object.
    private static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

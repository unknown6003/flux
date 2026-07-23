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
/// Three independent, all permission-free, sources feed the same events:
///
/// 1. **IOKit matching notifications** on `AppleDeviceManagementHIDEventService`
///    — the synthetic IOService AirPods and other BT accessories register, and
///    the same place their `BatteryPercent` already comes from (the old
///    monitor read it here too, permission-free). `kIOFirstMatchNotification`
///    fires when such a service appears (connect), `kIOTerminatedNotification`
///    when one vanishes (disconnect). This is the primary source and the only
///    one that can report battery + HID category.
///
/// 2. **IOKit matching notifications** on the generic `IOHIDDevice` class
///    (M10 review) — catches third-party Bluetooth keyboards/mice/
///    controllers that never register the Apple-accessory-oriented class
///    above. Same matching machinery, same transport/built-in filter, same
///    dedupe — see `genericHIDServiceClass`'s doc comment.
///
/// 3. **CoreAudio** device-list diffing (`kAudioHardwarePropertyDevices`) —
///    catches Bluetooth *audio* devices that may register as a CoreAudio
///    output without exposing either HID service above. Only devices whose
///    `kAudioDevicePropertyTransportType` is Bluetooth/BluetoothLE count.
///
/// All three sources dedupe through the same normalized-name-keyed,
/// session-scoped connected set (`shouldEmitConnect`/`shouldEmitDisconnect`),
/// so the common case — an AirPods connect that shows up via *multiple*
/// sources at once — emits a single wing, not several: once a name is
/// "connected" any further connect report for it is absorbed regardless of
/// how much time has passed (a pure 5s time-window can't catch a slow-to-
/// register audio device that shows up more than 5s after IOKit already
/// reported it). The 5s window still exists, but scoped to only its original
/// purpose — a disconnect→reconnect flap. See `shouldEmitConnect` for the
/// name-keying tradeoff and `dedupeKey(forName:)` for the cross-source name
/// normalization (M10 review) and its residual risk.
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

    /// M10 review: `AppleDeviceManagementHIDEventService` is Apple-accessory-
    /// oriented (AirPods and similar battery-reporting accessories) — a
    /// third-party Bluetooth keyboard, mouse, or game controller typically
    /// never publishes it, so it would otherwise be invisible to this
    /// monitor. `IOHIDDevice` is the class such accessories register under
    /// instead; matched through the exact same `Transport`/`Built-In`/
    /// `Product`/`DeviceUsagePairs` property reads (`IOHIDDevice` nubs expose
    /// the same standard IOHID keys `AppleDeviceManagementHIDEventService`
    /// does) and the same name-keyed dedupe, so a device that happens to
    /// register under both classes at once (absorbed the same way an
    /// IOKit+CoreAudio double-report for AirPods already is) doesn't double-post.
    private static let genericHIDServiceClass = "IOHIDDevice"

    /// Reconnect-storm dedupe window — see `shouldEmitConnect`.
    private static let dedupeWindow: TimeInterval = 5

    // MARK: IOKit state
    private var notificationPort: IONotificationPortRef?
    /// The two matching-notification iterators — held only so `stop()`/`deinit`
    /// can `IOObjectRelease` them. The live drains use the iterator IOKit hands
    /// the callback, which is the same handle.
    private var firstMatchIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    /// The `genericHIDServiceClass` counterparts of the two iterators above —
    /// see that constant's doc comment for why a second matching source exists.
    private var genericFirstMatchIterator: io_iterator_t = 0
    private var genericTerminatedIterator: io_iterator_t = 0

    // MARK: CoreAudio state
    /// Held once and reused for removal — CoreAudio compares block *identity*,
    /// not equality, so the exact reference passed to `Add` must be handed back
    /// to `Remove` (the same wrinkle documented in `VolumeMonitor`).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    /// The BT audio devices last seen via CoreAudio, `AudioObjectID` → name.
    /// Names are cached because a *removed* device can no longer be queried for
    /// its name at diff time — it's already gone from the system.
    private var knownBluetoothAudioDevices: [AudioObjectID: String] = [:]

    /// Name + category captured at CONNECT time, while the IOKit entry is
    /// still live, keyed by `IORegistryEntryGetRegistryEntryID` — the one
    /// identifier that's still retrievable from an already-terminated entry
    /// (the call itself remains valid post-termination even though most
    /// property reads on that entry are not). Fixes an M10 review finding:
    /// `kIOTerminatedNotification` fires with an entry whose `Product`/
    /// `Transport`/`DeviceUsagePairs` can no longer be read, so re-reading
    /// them (the pre-fix behavior) silently dropped or blanked disconnect
    /// wings for HID peripherals — audio devices were rescued only because
    /// `knownBluetoothAudioDevices` already caches by name. Baseline-drain
    /// entries (already connected when Flux launched) are cached too, so
    /// those devices still disconnect cleanly by name. Evicted on terminate
    /// (`processDisconnectEntry`) and cleared in `stop()`.
    private var deviceInfoCache: [UInt64: (name: String, category: BluetoothDeviceCategory)] = [:]

    /// Names currently believed connected — a name enters this set on an
    /// emitted connect and leaves it on the matching emitted disconnect. This
    /// is the session-scoped half of the dedupe (see `shouldEmitConnect`/
    /// `shouldEmitDisconnect`).
    private var connectedNames: Set<String> = []

    /// Last disconnect time per device *name* — kept only to give a
    /// subsequent *reconnect* a 5s grace window (the reconnect-storm case).
    /// Shared across both sources, same as `connectedNames`.
    private var lastDisconnectAt: [String: Date] = [:]

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

        // M10 review: second matching source for generic (non-Apple-
        // accessory) Bluetooth HID devices — see `genericHIDServiceClass`'s
        // doc comment. Same callback bodies as above (they only dispatch on
        // the iterator IOKit hands them, never reference a specific class),
        // just registered against a different service class and iterator.
        if let genericFirstMatch = IOServiceMatching(Self.genericHIDServiceClass) {
            let status = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, genericFirstMatch,
                { refCon, iterator in
                    guard let refCon else { return }
                    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.drain(iterator, isInitialDrain: false, event: .connect) }
                },
                context, &genericFirstMatchIterator)
            if status == KERN_SUCCESS {
                drain(genericFirstMatchIterator, isInitialDrain: true, event: .connect)
            } else {
                deviceLog.error("DeviceMonitor: failed to register generic-HID first-match notification (kern_return_t \(status))")
            }
        }

        if let genericTermMatch = IOServiceMatching(Self.genericHIDServiceClass) {
            let status = IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification, genericTermMatch,
                { refCon, iterator in
                    guard let refCon else { return }
                    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.drain(iterator, isInitialDrain: false, event: .disconnect) }
                },
                context, &genericTerminatedIterator)
            if status == KERN_SUCCESS {
                drain(genericTerminatedIterator, isInitialDrain: true, event: .disconnect)
            } else {
                deviceLog.error("DeviceMonitor: failed to register generic-HID terminated notification (kern_return_t \(status))")
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
        if genericFirstMatchIterator != 0 { IOObjectRelease(genericFirstMatchIterator); genericFirstMatchIterator = 0 }
        if genericTerminatedIterator != 0 { IOObjectRelease(genericTerminatedIterator); genericTerminatedIterator = 0 }
        if let port = notificationPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
        }
        notificationPort = nil

        deviceInfoCache.removeAll()
        connectedNames.removeAll()
        lastDisconnectAt.removeAll()
    }

    deinit {
        // Plain C/CoreAudio teardown calls with no dependency on this object's
        // own (about-to-be-torn-down) state — safe from a nonisolated `deinit`
        // the same way `PowerMonitor.deinit`/`VolumeMonitor.deinit` call their
        // raw teardown directly rather than routing through an instance method.
        if firstMatchIterator != 0 { IOObjectRelease(firstMatchIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        if genericFirstMatchIterator != 0 { IOObjectRelease(genericFirstMatchIterator) }
        if genericTerminatedIterator != 0 { IOObjectRelease(genericTerminatedIterator) }
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
        switch event {
        case .connect:
            processConnectEntry(entry, isInitialDrain: isInitialDrain)
        case .disconnect:
            processDisconnectEntry(entry, isInitialDrain: isInitialDrain)
        }
    }

    /// Handles one entry from the `kIOFirstMatchNotification` iterator — a
    /// fresh connect, or (when `isInitialDrain`) an already-connected baseline
    /// entry. The entry is still live here, so this is the only point where
    /// its name/category can be read reliably — `deviceInfoCache` is
    /// populated *before* the baseline/transport/built-in filtering below
    /// (including for baseline entries) so `processDisconnectEntry` can
    /// resurrect them later even though the entry itself won't be readable by
    /// then. See `deviceInfoCache`'s doc comment for the full M10 review fix.
    private func processConnectEntry(_ entry: io_registry_entry_t, isInitialDrain: Bool) {
        let transport = Self.registryString(entry, "Transport")
        let builtIn = Self.registryBool(entry, "Built-In") ?? false
        guard Self.isTrackableAccessory(transport: transport, isBuiltIn: builtIn) else { return }

        let name = Self.registryString(entry, "Product") ?? "Bluetooth Device"
        let category = Self.category(name: name, usagePairs: Self.usagePairs(for: entry))
        if let id = Self.registryEntryID(entry) {
            deviceInfoCache[id] = (name: name, category: category)
        }

        guard Self.shouldEmitEvent(isInitialDrain: isInitialDrain, transport: transport, isBuiltIn: builtIn) else { return }
        guard shouldEmitConnect(name: name) else { return }

        // Battery is read straight off this exact entry — no name-walk
        // needed, unlike the CoreAudio path which only has an AudioObjectID.
        events.send(.connected(name: name, batteryPercent: Self.registryInt(entry, "BatteryPercent"), category: category))
    }

    /// Handles one entry from the `kIOTerminatedNotification` iterator. By
    /// the time this fires the entry is already torn down, so re-reading
    /// `Product`/`Transport`/`DeviceUsagePairs` off it (the pre-M10-review-fix
    /// behavior) is unreliable — that was the bug: HID-peripheral disconnect
    /// wings were silently dropped or blank. Resolve name + category from
    /// `deviceInfoCache` (captured while the entry was still live via
    /// `processConnectEntry`) instead, only falling back to a live property
    /// read — and then a literal "Unknown device" — when the id isn't in the
    /// cache (e.g. the connect was never observed by this monitor).
    private func processDisconnectEntry(_ entry: io_registry_entry_t, isInitialDrain: Bool) {
        guard !isInitialDrain else { return }

        let id = Self.registryEntryID(entry)
        let cached = id.flatMap { deviceInfoCache[$0] }
        if let id { deviceInfoCache.removeValue(forKey: id) }

        let name = cached?.name ?? Self.registryString(entry, "Product") ?? "Unknown device"
        let category = cached?.category ?? Self.category(name: name, usagePairs: Self.usagePairs(for: entry))
        guard shouldEmitDisconnect(name: name) else { return }

        events.send(.disconnected(name: name, category: category))
    }

    /// Whether an entry is the kind of accessory this monitor tracks at all —
    /// Bluetooth transport and not Built-In/internal. Shared by the emit
    /// decision (`shouldEmitEvent`) and the connect-time cache-population
    /// gate in `processConnectEntry`, which needs the same test but, unlike
    /// the emit decision, must also apply to baseline (`isInitialDrain`)
    /// entries.
    static func isTrackableAccessory(transport: String?, isBuiltIn: Bool) -> Bool {
        guard !isBuiltIn, let transport, isBluetoothTransport(transport) else { return false }
        return true
    }

    /// Pure core of the "is this entry a real, surfaceable connect/disconnect,
    /// or baseline/noise" decision — extracted so `--selftest` drives every
    /// combination without real IOKit state. Absorbed (returns `false`) when:
    /// (1) it's the registration-time baseline drain (already-connected devices
    /// aren't fresh connects — no startup wing spam); or (2) it isn't a
    /// trackable accessory — Built-In/internal (Apple Internal Keyboard etc.)
    /// or non-Bluetooth transport, which also excludes USB keyboards/mice and
    /// anything wired, exactly the devices a Bluetooth wing shouldn't announce.
    static func shouldEmitEvent(isInitialDrain: Bool, transport: String?, isBuiltIn: Bool) -> Bool {
        guard !isInitialDrain else { return false }
        return isTrackableAccessory(transport: transport, isBuiltIn: isBuiltIn)
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

    // MARK: - Dedupe (pure predicates + instance wrappers)

    /// Reports whether a CONNECT for `name` should be emitted and, if so,
    /// marks `name` connected. Prunes aged-out `lastDisconnectAt` entries so
    /// it can't grow unbounded — piggybacking on the same call every event
    /// already makes, no timer needed (same shape as the old monitor).
    private func shouldEmitConnect(name: String, now: Date = Date()) -> Bool {
        lastDisconnectAt = lastDisconnectAt.filter { now.timeIntervalSince($0.value) < Self.dedupeWindow }

        // M10 review: dedupe on the NORMALIZED key, not the raw display name
        // — see `dedupeKey(forName:)`. `connectedNames`/`lastDisconnectAt`
        // therefore always hold keys, never display names, but that's purely
        // internal bookkeeping: the emitted `BluetoothEvent` always carries
        // the original `name` this function was called with, untouched.
        let key = Self.dedupeKey(forName: name)
        guard Self.shouldEmitConnect(name: key, now: now, connectedNames: connectedNames, lastDisconnectAt: lastDisconnectAt) else { return false }
        connectedNames.insert(key)
        return true
    }

    /// Reports whether a DISCONNECT for `name` should be emitted and, if so,
    /// clears `name` from the connected set and records the disconnect time
    /// (the reconnect-storm grace window `shouldEmitConnect` consults).
    private func shouldEmitDisconnect(name: String, now: Date = Date()) -> Bool {
        let key = Self.dedupeKey(forName: name)
        guard Self.shouldEmitDisconnect(name: key, connectedNames: connectedNames) else { return false }
        connectedNames.remove(key)
        lastDisconnectAt[key] = now
        return true
    }

    /// Normalizes a device display name into a stable dedupe key so
    /// cosmetically different strings for the SAME physical accessory across
    /// the two sources — IOKit's `Product` vs CoreAudio's device name, or
    /// either source's `"Bluetooth Device"`/`"Unknown device"` fallback vs the
    /// other's real name — still collapse onto one connect/disconnect
    /// session instead of posting two wings (M10 review finding).
    ///
    /// Deliberately conservative: only case-folding and whitespace
    /// normalization (lowercased, leading/trailing trimmed, internal
    /// whitespace runs collapsed to a single space). No suffix/prefix
    /// stripping — a rule like "strip a trailing possessive" is itself a
    /// footgun (it would merge "Ammar's AirPods" and "Sam's AirPods" into the
    /// same key, turning two distinct devices into one session), so this
    /// intentionally does NOT attempt it.
    ///
    /// Residual risk: this still does not catch every real-world mismatch —
    /// a genuinely different string per source (e.g. a user-renamed CoreAudio
    /// device name vs IOKit's raw `Product`, like "Ammar's AirPods" vs
    /// "AirPods Pro") is not the same key after this normalization and can
    /// still double-post. A stable per-device identifier (a CoreAudio UID or
    /// IORegistry entry id shared across both sources) would close that gap,
    /// but CoreAudio's Bluetooth path here never exposes one — see
    /// `currentBluetoothAudioDevices()`. Name is still the only identifier
    /// both sources share.
    static func dedupeKey(forName name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Pure predicate behind the CONNECT half of the dedupe. Keyed by
    /// **name**, not address: CoreAudio never exposes a device's BT address,
    /// so name is the only identifier both sources share. The tradeoff: two
    /// genuinely distinct devices sharing a name (e.g. two identical
    /// "AirPods") would be merged into one connected/disconnected session — a
    /// rare, deliberately-accepted false merge in exchange for reliable
    /// cross-source dedupe of the overwhelmingly common single-device case.
    ///
    /// Absorbed (returns `false`) when:
    /// (1) `name` is already in `connectedNames` — the cross-source
    ///     double-report case (IOKit and CoreAudio both reporting the same
    ///     live device), absorbed regardless of elapsed time. A pure time
    ///     window can't handle this reliably: a slow-to-register Bluetooth
    ///     audio device can show up in CoreAudio's device list more than 5s
    ///     after IOKit already reported the same connect, which the old
    ///     window-only predicate would double-post; or
    /// (2) `name` disconnected less than `window` ago — the reconnect-storm
    ///     case (AirPods and other BT accessories routinely emit a rapid
    ///     disconnect/reconnect pair the user never meaningfully caused), the
    ///     ORIGINAL and now sole purpose of the 5s window.
    /// Otherwise this is a genuinely new connect: emit.
    static func shouldEmitConnect(name: String, now: Date, connectedNames: Set<String>, lastDisconnectAt: [String: Date], window: TimeInterval = dedupeWindow) -> Bool {
        guard !connectedNames.contains(name) else { return false }
        if let last = lastDisconnectAt[name], now.timeIntervalSince(last) < window { return false }
        return true
    }

    /// Pure predicate behind the DISCONNECT half of the dedupe: a disconnect
    /// only emits for a name currently believed connected, so the same
    /// cross-source double-report (IOKit and CoreAudio both reporting the
    /// same device gone) collapses to a single wing instead of two.
    static func shouldEmitDisconnect(name: String, connectedNames: Set<String>) -> Bool {
        connectedNames.contains(name)
    }

    // MARK: - CoreAudio assist (Bluetooth audio devices)

    private func startAudioListener() {
        guard deviceListListenerBlock == nil else { return }

        // M10 review: seed the on-launch baseline BEFORE the listener is
        // installed, not after. A device that connects in the gap between
        // "listener installed" and "baseline queried" would otherwise be
        // silently absorbed into the baseline itself (the old ordering) —
        // its queued callback later diffs against a snapshot that already
        // contains it, sees no delta, and emits nothing, with no IOKit event
        // to recover the missed connect. Taken WITHOUT emitting: devices
        // already connected before Flux even starts watching are baseline,
        // not fresh connects.
        knownBluetoothAudioDevices = Self.currentBluetoothAudioDevices() ?? [:]

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

        // M10 review (continued): re-query and reconcile ONCE, immediately
        // after the listener is armed, against the pre-listener baseline
        // above. This is a real diff — using `handleAudioDevicesChanged`'s
        // own emit path — so a device that connected in that narrow gap gets
        // a genuine connect wing instead of being lost. `nil` here (a HAL
        // read failure right at startup) just leaves the pre-listener
        // baseline as-is; there is nothing yet to reconcile against.
        if let reconciled = Self.currentBluetoothAudioDevices() {
            reconcileAudioDevices(current: reconciled)
        }
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
    ///
    /// M10 review: a CoreAudio device-list read can fail transiently (the
    /// size query and the data query race a concurrent reconfiguration, or
    /// either HAL call just fails) — `currentBluetoothAudioDevices()` returns
    /// `nil` for that, never an empty dictionary, specifically so this can
    /// tell "nothing is connected" apart from "the read didn't work." A
    /// failed read must never be treated as an authoritative empty list: that
    /// would emit a disconnect for every cached device now, and matching
    /// false connects on the next successful read. `reconciledSnapshot`
    /// (below) is the pure form of that decision — a `nil` read passes
    /// `knownBluetoothAudioDevices` through untouched; only a real (possibly
    /// empty) read ever replaces it.
    private func handleAudioDevicesChanged() {
        let read = Self.currentBluetoothAudioDevices()
        if read == nil {
            deviceLog.error("DeviceMonitor: CoreAudio device-list read failed — preserving the previous snapshot rather than treating it as authoritative (would emit spurious disconnects)")
        }
        reconcileAudioDevices(current: Self.reconciledSnapshot(previous: knownBluetoothAudioDevices, read: read))
    }

    /// The shared diff-and-emit step behind both a listener-driven device-
    /// list change (`handleAudioDevicesChanged`) and the one-time post-seed
    /// reconciliation in `startAudioListener()` — same delta logic, same
    /// dedupe, same snapshot update, just fed a `current` snapshot from a
    /// different call site.
    private func reconcileAudioDevices(current: [AudioObjectID: String]) {
        let previous = knownBluetoothAudioDevices

        for (id, name) in current where previous[id] == nil {
            guard shouldEmitConnect(name: name) else { continue }
            // Best-effort battery via the same permission-free IORegistry
            // read the IOKit path uses — `nil` if this audio-only device has
            // no HID service publishing `BatteryPercent`.
            events.send(.connected(name: name, batteryPercent: Self.batteryPercent(forName: name), category: .audio))
        }
        for (id, name) in previous where current[id] == nil {
            guard shouldEmitDisconnect(name: name) else { continue }
            events.send(.disconnected(name: name, category: .audio))
        }

        knownBluetoothAudioDevices = current
    }

    /// The current default+all audio devices whose transport is Bluetooth /
    /// Bluetooth LE, `AudioObjectID` → name. `nil` — not an empty dictionary —
    /// when the underlying `allAudioDevices()` HAL read itself failed, so
    /// callers can tell "nothing connected" apart from "couldn't read" (M10
    /// review; see `handleAudioDevicesChanged`).
    private static func currentBluetoothAudioDevices() -> [AudioObjectID: String]? {
        guard let ids = allAudioDevices() else { return nil }
        var result: [AudioObjectID: String] = [:]
        for id in ids {
            guard let transport = transportType(id), isBluetoothTransport(transport) else { continue }
            result[id] = deviceName(id) ?? "Bluetooth Device"
        }
        return result
    }

    /// Pure decision behind "should a failed CoreAudio device-list read wipe
    /// the known snapshot" (M10 review) — extracted so `--selftest` can
    /// verify it without a real CoreAudio call. `read` is what
    /// `currentBluetoothAudioDevices()` returned: `nil` means the HAL read
    /// failed and `previous` must pass through unchanged (never overwritten
    /// with an empty/partial result); any non-nil value — including a
    /// genuinely empty dictionary, meaning every BT audio device really is
    /// gone — replaces it.
    static func reconciledSnapshot(previous: [AudioObjectID: String], read: [AudioObjectID: String]?) -> [AudioObjectID: String] {
        read ?? previous
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

    /// The registry entry's stable id — unlike arbitrary property reads via
    /// `IORegistryEntryCreateCFProperty`, `IORegistryEntryGetRegistryEntryID`
    /// remains valid on an already-terminated entry, which is exactly why
    /// `deviceInfoCache` is keyed by this instead of by name-read-at-terminate.
    private static func registryEntryID(_ entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
        return id
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

    /// `nil` — not an empty array — specifically when either HAL call
    /// itself fails, so `currentBluetoothAudioDevices()` can distinguish a
    /// real "zero devices" read from "the read didn't work" (M10 review).
    /// `count == 0` (the property genuinely reports no devices) is a
    /// successful read and returns `[]`, not `nil`.
    private static func allAudioDevices() -> [AudioObjectID]? {
        var address = deviceListAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return nil }
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

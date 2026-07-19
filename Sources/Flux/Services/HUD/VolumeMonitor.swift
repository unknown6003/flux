import Foundation
import Combine
import CoreAudio
import OSLog

/// Shared logging point for the HUD subsystem (M5: volume/brightness) —
/// mirrors `powerLog`'s/`bluetoothLog`'s file-scope-constant pattern rather
/// than adding a new case to `Log.swift`, since this is a self-contained M5
/// subsystem the notch suite owns.
let hudLog = Logger(subsystem: "com.flux.menubar", category: "hud")

/// A discrete volume/mute change worth surfacing as a live activity.
/// `VolumeMonitor` posts one every time CoreAudio reports either changing —
/// whether the user turned a physical key (observe mode), dragged Control
/// Center's slider, or `MediaKeyInterceptor`'s intercept-mode path just
/// applied one via `setVolume`/`adjustVolume`/`toggleMute` (CoreAudio fires
/// the same listener for a programmatic write as for a hardware one — see
/// `NotchActivityRouter`'s dedupe logic for how the double-post this would
/// otherwise cause in intercept mode is suppressed).
enum VolumeEvent: Equatable {
    case volumeChanged(level: Float, muted: Bool)
}

/// Watches the default output device's volume/mute via CoreAudio's
/// block-based property-listener API and turns changes into `VolumeEvent`s
/// (`events`) — the observe-mode data source for the M5 HUD, and also
/// (`setVolume`/`adjustVolume`/`toggleMute`) the thing intercept mode calls
/// to actually apply a swallowed key press.
///
/// ## Why this C interop is simpler than `PowerMonitor`'s
/// `AudioObjectAddPropertyListenerBlock` takes an
/// `AudioObjectPropertyListenerBlock` — a genuine Swift closure
/// (`@convention(block)`), not a `@convention(c)` function pointer — so,
/// unlike `PowerMonitor.start()`'s `IOPSNotificationCreateRunLoopSource`
/// (which categorically cannot capture `self` and needs the `Unmanaged`
/// dance), the listener blocks below simply capture `self` weakly like any
/// other closure in this codebase. The one interop wrinkle that remains:
/// `AudioObjectRemovePropertyListenerBlock` must be called with the *exact
/// same* block reference passed to the matching `Add` call — CoreAudio
/// compares block identity, not equality — so every installed listener block
/// is built once and held (`volumeListener`/`muteListener`/
/// `defaultDeviceListenerBlock`) purely so `stop()`/device-switch
/// re-attachment can hand the identical reference back for removal, together
/// with the exact `AudioObjectPropertyAddress` it was installed against
/// (removal must match both).
///
/// Every listener block runs on `DispatchQueue.main` (passed explicitly at
/// registration) — a real guarantee, not an assumption — which is what makes
/// `MainActor.assumeIsolated` inside each one a true assertion.
@MainActor
final class VolumeMonitor {
    let events = PassthroughSubject<VolumeEvent, Never>()

    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var isListening = false

    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// The address + block actually installed for the volume listener —
    /// tracked together (not just the block) because which address is used
    /// depends on whether the device has `kAudioDevicePropertyVolumeScalarVirtualMainVolume`
    /// (see `addDeviceListeners`); removal must match whichever was chosen.
    private var volumeListener: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?
    private var muteListener: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?

    // MARK: - Lifecycle

    /// No-op if already listening. Installs the system-wide default-output-
    /// device-changed listener (so a later device switch is always caught)
    /// plus the current device's own volume/mute listeners.
    func start() {
        guard !isListening else { return }
        isListening = true
        addDefaultDeviceListener()
        deviceID = Self.defaultOutputDevice()
        addDeviceListeners()
    }

    /// Tears down every listener this monitor holds and forgets the current
    /// device, so a later `start()` begins with a clean baseline.
    func stop() {
        guard isListening else { return }
        removeDeviceListeners()
        removeDefaultDeviceListener()
        deviceID = kAudioObjectUnknown
        isListening = false
    }

    deinit {
        // Plain CoreAudio teardown calls, not `self.stop()` — mirrors
        // `PowerMonitor.deinit`/`BluetoothMonitor.deinit` calling their raw
        // C/Objective-C teardown directly rather than routing through an
        // instance method from a nonisolated `deinit`.
        if let volumeListener {
            var address = volumeListener.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeListener.block)
        }
        if let muteListener {
            var address = muteListener.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteListener.block)
        }
        if let defaultDeviceListenerBlock {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, defaultDeviceListenerBlock)
        }
    }

    // MARK: - Reading + writing (used by observe-mode refresh + intercept mode)

    /// The default output device's live volume/mute, read fresh from
    /// CoreAudio on every call — this is what `MediaKeyInterceptor`'s
    /// intercept-mode path (via `NotchActivityRouter`) consults right after
    /// applying a change, and what `refresh()` reads on every listener fire.
    /// `nil` when there's no default output device at all, or the device
    /// exposes neither the virtual main volume nor a per-channel scalar
    /// volume (some digital/HDMI outputs report no software-controllable
    /// volume whatsoever).
    var current: (level: Float, muted: Bool)? {
        let device = resolvedDeviceID()
        guard device != kAudioObjectUnknown, let level = Self.readVolume(device: device) else { return nil }
        return (level, Self.readMute(device: device) ?? false)
    }

    /// Whether the default output device currently exposes a software-
    /// settable volume scalar at all — `false` for several digital/HDMI
    /// outputs and some external DACs, which only ever publish a fixed or
    /// read-only level. `MediaKeyInterceptor`'s `volumeControllable` closure
    /// (wired by `NotchActivityRouter`) consults this so the volume keys
    /// pass through to the system instead of being silently swallowed with
    /// nothing this app can actually do about them — mirroring
    /// `brightnessAvailable`'s existing pass-through for brightness keys.
    var hasVolumeControl: Bool {
        let device = resolvedDeviceID()
        guard device != kAudioObjectUnknown else { return false }
        return Self.hasSettableVolume(device: device)
    }

    /// Clamps to 0...1 before writing.
    func setVolume(_ level: Float) {
        let device = resolvedDeviceID()
        guard device != kAudioObjectUnknown else { return }
        _ = Self.writeVolume(device: device, level: level)
    }

    /// Reads the current level, applies `delta`, and writes back the result
    /// clamped to 0...1. A no-op when there's currently no readable level at
    /// all (no default output device, or the device is silent about both
    /// volume properties).
    func adjustVolume(by delta: Float) {
        guard let current else { return }
        setVolume(min(max(current.level + delta, 0), 1))
    }

    func toggleMute() {
        let device = resolvedDeviceID()
        guard device != kAudioObjectUnknown else { return }
        let muted = Self.readMute(device: device) ?? false
        _ = Self.writeMute(device: device, muted: !muted)
    }

    /// `deviceID` when listening (`start()` has resolved it); otherwise
    /// re-resolved fresh on demand — so `setVolume`/`adjustVolume`/
    /// `toggleMute` still work even if called before `start()`.
    private func resolvedDeviceID() -> AudioObjectID {
        deviceID != kAudioObjectUnknown ? deviceID : Self.defaultOutputDevice()
    }

    // MARK: - Listener installation

    private func addDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleDefaultDeviceChanged() }
        }
        defaultDeviceListenerBlock = block
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = Self.defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        defaultDeviceListenerBlock = nil
    }

    /// Installs the volume + mute listeners for `deviceID`. The volume
    /// listener's address depends on whether this device exposes the
    /// "virtual main volume" convenience property; devices that only expose
    /// independent per-channel scalar volume (see `readVolume`'s doc
    /// comment) are watched on channel 1 alone — the stereo pairs this
    /// fallback exists for move both channels together, so one is enough to
    /// catch a change.
    private func addDeviceListeners() {
        guard deviceID != kAudioObjectUnknown else { return }

        let volumeAddress = Self.hasVirtualMainVolume(device: deviceID)
            ? Self.volumeAddress
            : Self.channelVolumeAddress(channel: 1)
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        volumeListener = (volumeAddress, volumeBlock)
        var volAddr = volumeAddress
        let volumeStatus = AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, volumeBlock)
        if volumeStatus != noErr {
            hudLog.error("VolumeMonitor: failed to add the volume listener (OSStatus \(volumeStatus)) — observe-mode volume HUD will miss changes on this device")
        }

        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        muteListener = (Self.muteAddress, muteBlock)
        var muteAddr = Self.muteAddress
        let muteStatus = AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, muteBlock)
        if muteStatus != noErr {
            hudLog.error("VolumeMonitor: failed to add the mute listener (OSStatus \(muteStatus)) — observe-mode volume HUD will miss mute toggles on this device")
        }
    }

    private func removeDeviceListeners() {
        guard deviceID != kAudioObjectUnknown else { return }
        if let volumeListener {
            var address = volumeListener.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeListener.block)
        }
        volumeListener = nil
        if let muteListener {
            var address = muteListener.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteListener.block)
        }
        muteListener = nil
    }

    /// The default output device changed out from under a live listening
    /// session (headphones plugged in, an AirPlay/Bluetooth device became
    /// default, ...) — tear down the old device's listeners and re-attach to
    /// the new one. Deliberately posts no event here: a device switch alone
    /// isn't a volume *change* worth flashing the HUD for; the next real
    /// volume/mute listener fire on the newly attached device posts its own
    /// event normally.
    private func handleDefaultDeviceChanged() {
        removeDeviceListeners()
        deviceID = Self.defaultOutputDevice()
        addDeviceListeners()
    }

    private func refresh() {
        guard let current else { return }
        events.send(.volumeChanged(level: current.level, muted: current.muted))
    }

    // MARK: - Pure CoreAudio plumbing (addresses + get/set primitives)
    //
    // Every member below is `nonisolated` — pure struct construction and
    // plain C CoreAudio calls with no dependency on this instance's actor
    // state — deliberately so `deinit` (which, like every class `deinit`,
    // cannot itself be actor-isolated) can call `Self.defaultDeviceAddress`
    // directly without the compiler treating that as crossing an isolation
    // boundary. Without this, the same call from `deinit` that's perfectly
    // fine from any other (MainActor-isolated) instance method below is a
    // hard compile error.

    private nonisolated static let outputScope = kAudioDevicePropertyScopeOutput

    private nonisolated static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal,
                                    mElement: kAudioObjectPropertyElementMain)
    }

    /// The device's overall ("main"/element-0) scalar volume — what most
    /// built-in outputs expose directly, sparing this monitor from having to
    /// average per-channel values itself. There is no separate "virtual main
    /// volume" property selector in CoreAudio's `AudioObjectPropertyAddress`
    /// vocabulary (that convenience belongs to the different, deprecated
    /// `AudioHardwareService` API, which this monitor doesn't use) — the
    /// plain `kAudioDevicePropertyVolumeScalar` selector addressed at
    /// `kAudioObjectPropertyElementMain` (element 0) is CoreAudio's actual
    /// "master volume" address; `channelVolumeAddress` below is the exact
    /// same selector at an explicit per-channel element instead.
    private nonisolated static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                    mScope: outputScope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                    mScope: outputScope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func channelVolumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: outputScope, mElement: channel)
    }

    private nonisolated static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultDeviceAddress
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        // `kAudioObjectSystemObject` imports as a bare `Int32` (it's declared
        // as an untyped C enum case, not a `CF_ENUM(AudioObjectID, ...)`) —
        // a real, widely-hit CoreAudio/Swift interop gotcha distinct from
        // every other constant here, which is why only this one needs an
        // explicit `AudioObjectID(...)` conversion.
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    private nonisolated static func hasVirtualMainVolume(device: AudioObjectID) -> Bool {
        var address = volumeAddress
        return AudioObjectHasProperty(device, &address)
    }

    /// Whether `device` has a volume property this monitor could actually
    /// write to — same virtual-main-volume-first, per-channel-fallback shape
    /// as `readVolume`/`writeVolume`, but checking settability rather than
    /// reading or writing a value. Backs `hasVolumeControl`.
    private nonisolated static func hasSettableVolume(device: AudioObjectID) -> Bool {
        if hasVirtualMainVolume(device: device) {
            var address = volumeAddress
            return isSettable(device, &address)
        }
        var left = channelVolumeAddress(channel: 1)
        var right = channelVolumeAddress(channel: 2)
        return isSettable(device, &left) || isSettable(device, &right)
    }

    private nonisolated static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// Reads the device's volume, preferring the "virtual main volume"
    /// convenience property CoreAudio provides on most devices; falling back
    /// to averaging the per-channel scalar volume (elements 1/2) for the
    /// devices that don't expose it — notably several USB/HDMI outputs,
    /// which only ever publish independently settable per-channel volumes.
    private nonisolated static func readVolume(device: AudioObjectID) -> Float? {
        guard device != kAudioObjectUnknown else { return nil }
        if hasVirtualMainVolume(device: device) {
            var address = volumeAddress
            return readFloat32(device, &address)
        }
        var left = channelVolumeAddress(channel: 1)
        var right = channelVolumeAddress(channel: 2)
        let leftValue = readFloat32(device, &left)
        let rightValue = readFloat32(device, &right)
        switch (leftValue, rightValue) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    private nonisolated static func writeVolume(device: AudioObjectID, level: Float) -> Bool {
        let clamped = min(max(level, 0), 1)
        if hasVirtualMainVolume(device: device) {
            var address = volumeAddress
            return writeFloat32(device, &address, clamped)
        }
        var left = channelVolumeAddress(channel: 1)
        var right = channelVolumeAddress(channel: 2)
        let leftOK = writeFloat32(device, &left, clamped)
        let rightOK = writeFloat32(device, &right, clamped)
        return leftOK || rightOK
    }

    private nonisolated static func readMute(device: AudioObjectID) -> Bool? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    private nonisolated static func writeMute(device: AudioObjectID, muted: Bool) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private nonisolated static func readFloat32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Float? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func writeFloat32(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, _ value: Float) -> Bool {
        guard isSettable(device, &address) else { return false }
        var v = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &v) == noErr
    }
}

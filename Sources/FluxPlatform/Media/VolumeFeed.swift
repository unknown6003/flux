import CoreAudio
import AudioToolbox
import Foundation
import FluxCore

public struct VolumeSnapshot: Equatable, Sendable {
    public let level: Float
    public let muted: Bool
    public let adjustable: Bool
    public let muteAdjustable: Bool

    public init(level: Float, muted: Bool, adjustable: Bool, muteAdjustable: Bool = false) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.muted = muted
        self.adjustable = adjustable
        self.muteAdjustable = muteAdjustable
    }

    public func supports(_ key: VolumeKey) -> Bool {
        switch key {
        case .up, .down: adjustable
        case .mute: muteAdjustable
        }
    }
}

/// CoreAudio removes listeners by the original block identity. All fields
/// are immutable; the C remove call is valid during final-owner teardown.
final class AudioObservation: @unchecked Sendable {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress,
          receive: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        queue = .global(qos: .utility)
        block = { _, _ in receive() }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
    }

    deinit {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

/// Reads and changes the current output device off the UI actor. Listeners
/// cover the default device, mute, and both channels when main volume is absent.
public actor VolumeDriver {
    public var current: VolumeSnapshot? { previous }
    public nonisolated let updates: AsyncStream<VolumeSnapshot?>
    private let output: AsyncStream<VolumeSnapshot?>.Continuation
    private var observers: [AudioObservation] = []
    private var deviceObservers: [AudioObservation] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var active = false
    private var hasReading = false
    private var previous: VolumeSnapshot?

    public init() {
        let channel = AsyncStream<VolumeSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = channel.stream
        output = channel.continuation
    }

    public func start() {
        guard !active else { return }
        active = true
        if let observation = AudioObservation(object: AudioObjectID(kAudioObjectSystemObject), address: Self.defaultDevice, receive: { [weak self] in
            Task { await self?.attachDevice() }
        }) { observers.append(observation) }
        attachDevice()
    }

    public func stop() {
        active = false
        observers.removeAll()
        deviceObservers.removeAll()
        device = AudioObjectID(kAudioObjectUnknown)
        output.finish()
    }

    public func adjust(by delta: Float) -> Bool {
        guard active, delta.isFinite, device != kAudioObjectUnknown else { return false }
        let addresses = volumeAddresses()
        var wrote = false
        for var address in addresses {
            guard isSettable(address), let value = readFloat(address) else { continue }
            var next = min(max(value + delta, 0), 1)
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &next) == noErr { wrote = true }
        }
        if wrote { refresh() }
        return wrote
    }

    public func toggleMute() -> Bool {
        guard active, isSettable(Self.mute), let muted = readMute() else { return false }
        var value: UInt32 = muted ? 0 : 1
        var address = Self.mute
        let wrote = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        if wrote { refresh() }
        return wrote
    }

    private func attachDevice() {
        guard active else { return }
        var address = Self.defaultDevice
        var next = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &next) != noErr {
            next = AudioObjectID(kAudioObjectUnknown)
        }
        if device == next, hasReading { return }
        deviceObservers.removeAll()
        device = next
        if device != kAudioObjectUnknown {
            for address in volumeAddresses() + [Self.mute] {
                if let observer = AudioObservation(object: device, address: address, receive: { [weak self] in
                    Task { await self?.refresh() }
                }) { deviceObservers.append(observer) }
            }
        }
        refresh()
    }

    private func refresh() {
        guard active else { return }
        let values = volumeAddresses().compactMap(readFloat)
        let state: VolumeSnapshot?
        if !values.isEmpty {
            state = .init(level: values.reduce(0, +) / Float(values.count), muted: readMute() ?? false,
                          adjustable: volumeAddresses().contains(where: isSettable),
                          muteAdjustable: readMute() != nil && isSettable(Self.mute))
        } else { state = nil }
        if !hasReading || previous != state {
            hasReading = true
            previous = state
            output.yield(state)
        }
    }

    private func volumeAddresses() -> [AudioObjectPropertyAddress] {
        var main = Self.mainVolume
        if AudioObjectHasProperty(device, &main) { return [main] }
        return [Self.channel(1), Self.channel(2)]
    }

    private func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var value = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &value) == noErr && value.boolValue
    }

    private func readFloat(_ address: AudioObjectPropertyAddress) -> Float? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private func readMute() -> Bool? {
        var address = Self.mute
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static var defaultDevice: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static var mainVolume: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var mute: AudioObjectPropertyAddress {
        .init(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func channel(_ number: UInt32) -> AudioObjectPropertyAddress {
        .init(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: number)
    }
}

@MainActor public final class VolumeFeed: FeatureServiceHandle {
    private let driver: VolumeDriver
    private var events: Task<Void, Never>?
    private var onChange: ((VolumeSnapshot?) -> Void)?
    private var active = true

    public init(driver: VolumeDriver = VolumeDriver(), onChange: @escaping (VolumeSnapshot?) -> Void) {
        self.driver = driver
        self.onChange = onChange
        events = Task { @MainActor [weak self, driver] in
            await driver.start()
            for await state in driver.updates {
                guard let self, self.active, !Task.isCancelled else { return }
                self.onChange?(state)
            }
        }
    }

    deinit { events?.cancel(); let driver = driver; Task { await driver.stop() } }
    public func adjust(by delta: Float) async -> Bool { guard active else { return false }; return await driver.adjust(by: delta) }
    public func toggleMute() async -> Bool { guard active else { return false }; return await driver.toggleMute() }
    public func current() async -> VolumeSnapshot? { guard active else { return nil }; return await driver.current }
    public func stop() {
        active = false
        onChange = nil
        events?.cancel(); events = nil
        let driver = driver
        Task { await driver.stop() }
    }
}

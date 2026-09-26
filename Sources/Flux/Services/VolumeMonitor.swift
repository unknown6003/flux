import Combine
import CoreAudio

enum VolumeEvent: Equatable {
    case volumeChanged(level: Float, muted: Bool)
}

/// Watches the default output device and applies volume/mute changes when the
/// media-key tap is active. It also sees changes made in Control Center or apps.
@MainActor
final class VolumeMonitor {
    let events = PassthroughSubject<VolumeEvent, Never>()

    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var listening = false
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var muteListener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    var current: (level: Float, muted: Bool)? {
        let device = resolvedDevice()
        guard device != kAudioObjectUnknown,
              let level = Self.readVolume(device) else { return nil }
        return (level, Self.readMute(device) ?? false)
    }

    var hasVolumeControl: Bool {
        let device = resolvedDevice()
        guard device != kAudioObjectUnknown else { return false }
        if Self.hasMainVolume(device) {
            var address = Self.volumeAddress
            return Self.isSettable(device, &address)
        }
        var left = Self.channelAddress(1)
        var right = Self.channelAddress(2)
        return Self.isSettable(device, &left) || Self.isSettable(device, &right)
    }

    func start() {
        guard !listening else { return }
        listening = true
        addDefaultDeviceListener()
        deviceID = Self.defaultOutputDevice()
        addDeviceListeners()
    }

    func stop() {
        guard listening else { return }
        removeDeviceListeners()
        removeDefaultDeviceListener()
        deviceID = kAudioObjectUnknown
        listening = false
    }

    func adjustVolume(by delta: Float) {
        let device = resolvedDevice()
        guard device != kAudioObjectUnknown else { return }
        if Self.hasMainVolume(device) {
            var address = Self.volumeAddress
            guard let level = Self.readFloat(device, &address) else { return }
            _ = Self.writeFloat(device, &address, min(max(level + delta, 0), 1))
            return
        }
        var left = Self.channelAddress(1)
        var right = Self.channelAddress(2)
        let targets = Self.perChannelTargets(left: Self.readFloat(device, &left),
                                             right: Self.readFloat(device, &right),
                                             delta: delta)
        if let value = targets.left { _ = Self.writeFloat(device, &left, value) }
        if let value = targets.right { _ = Self.writeFloat(device, &right, value) }
    }

    func toggleMute() {
        let device = resolvedDevice()
        guard device != kAudioObjectUnknown,
              let muted = Self.readMute(device) else { return }
        _ = Self.writeMute(device, !muted)
    }

    nonisolated static func perChannelTargets(left: Float?, right: Float?, delta: Float) -> (left: Float?, right: Float?) {
        (left.map { min(max($0 + delta, 0), 1) }, right.map { min(max($0 + delta, 0), 1) })
    }

    private func resolvedDevice() -> AudioObjectID {
        deviceID == kAudioObjectUnknown ? Self.defaultOutputDevice() : deviceID
    }

    private func addDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleDefaultDeviceChanged() }
        }
        defaultDeviceListener = block
        var address = Self.defaultDeviceAddress
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                DispatchQueue.main, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var address = Self.defaultDeviceAddress
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, block)
        defaultDeviceListener = nil
    }

    private func addDeviceListeners() {
        guard deviceID != kAudioObjectUnknown else { return }
        let address = Self.hasMainVolume(deviceID) ? Self.volumeAddress : Self.channelAddress(1)
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        volumeListener = (address, volumeBlock)
        var volumeAddress = address
        _ = AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, volumeBlock)

        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        muteListener = (Self.muteAddress, muteBlock)
        var muteAddress = Self.muteAddress
        _ = AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, muteBlock)
    }

    private func removeDeviceListeners() {
        guard deviceID != kAudioObjectUnknown else { return }
        if let listener = volumeListener {
            var address = listener.0
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener.1)
        }
        volumeListener = nil
        if let listener = muteListener {
            var address = listener.0
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener.1)
        }
        muteListener = nil
    }

    private func handleDefaultDeviceChanged() {
        removeDeviceListeners()
        deviceID = Self.defaultOutputDevice()
        addDeviceListeners()
    }

    private func refresh() {
        guard let current else { return }
        events.send(.volumeChanged(level: current.level, muted: current.muted))
    }

    private nonisolated static let outputScope = kAudioDevicePropertyScopeOutput

    private nonisolated static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: outputScope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: outputScope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func channelAddress(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: outputScope,
                                   mElement: channel)
    }

    private nonisolated static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultDeviceAddress
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &device)
        return result == noErr ? device : kAudioObjectUnknown
    }

    private nonisolated static func hasMainVolume(_ device: AudioObjectID) -> Bool {
        var address = volumeAddress
        return AudioObjectHasProperty(device, &address)
    }

    private nonisolated static func isSettable(_ device: AudioObjectID,
                                               _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private nonisolated static func readVolume(_ device: AudioObjectID) -> Float? {
        if hasMainVolume(device) {
            var address = volumeAddress
            return readFloat(device, &address)
        }
        var left = channelAddress(1)
        var right = channelAddress(2)
        let values = (readFloat(device, &left), readFloat(device, &right))
        switch values {
        case let (left?, right?): return (left + right) / 2
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private nonisolated static func readMute(_ device: AudioObjectID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
            ? value != 0 : nil
    }

    private nonisolated static func writeMute(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var address = muteAddress
        guard isSettable(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private nonisolated static func readFloat(_ device: AudioObjectID,
                                              _ address: inout AudioObjectPropertyAddress) -> Float? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
            ? value : nil
    }

    private nonisolated static func writeFloat(_ device: AudioObjectID,
                                               _ address: inout AudioObjectPropertyAddress,
                                               _ value: Float) -> Bool {
        guard isSettable(device, &address) else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    deinit {
        if let listener = volumeListener {
            var address = listener.0
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener.1)
        }
        if let listener = muteListener {
            var address = listener.0
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener.1)
        }
        if let listener = defaultDeviceListener {
            var address = Self.defaultDeviceAddress
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                       DispatchQueue.main, listener)
        }
    }
}

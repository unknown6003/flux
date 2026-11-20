import AudioToolbox
import CoreAudio
import Foundation

/// One macOS audio output route that can be selected from the lock screen.
public struct AudioOutputDeviceInfo: Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let name: String
    public let symbolName: String
    public let isDefault: Bool

    public init(id: UInt32, name: String, symbolName: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isDefault = isDefault
    }
}

/// Current default output route, mute state, and selectable output devices.
public struct AudioOutputSnapshot: Equatable, Sendable {
    public let isMuted: Bool
    public let canMute: Bool
    public let currentDevice: AudioOutputDeviceInfo?
    public let devices: [AudioOutputDeviceInfo]

    public init(isMuted: Bool, canMute: Bool, currentDevice: AudioOutputDeviceInfo?, devices: [AudioOutputDeviceInfo]) {
        self.isMuted = isMuted
        self.canMute = canMute
        self.currentDevice = currentDevice
        self.devices = devices
    }
}

/// Pure CoreAudio output device inspection, mute toggle, and route switching.
/// Requires no special TCC permission and works while the screen is locked.
public enum AudioOutputRoute {
    public static func readSnapshot() -> AudioOutputSnapshot {
        let defaultID = defaultOutputDeviceID()
        let allIDs = outputDeviceIDs()
        var devices: [AudioOutputDeviceInfo] = []
        devices.reserveCapacity(allIDs.count)

        for id in allIDs {
            guard let name = deviceName(id), !name.isEmpty else { continue }
            let transport = transportType(id)
            let symbol = symbolName(forName: name, transportType: transport)
            devices.append(AudioOutputDeviceInfo(id: id, name: name, symbolName: symbol, isDefault: id == defaultID))
        }

        let current = devices.first(where: \.isDefault) ?? devices.first
        let muted = defaultID != kAudioObjectUnknown ? (readMute(defaultID) ?? false) : false
        let canMute = defaultID != kAudioObjectUnknown && isMuteSettable(defaultID)
        return AudioOutputSnapshot(isMuted: muted, canMute: canMute, currentDevice: current, devices: devices)
    }

    @discardableResult
    public static func toggleMute() -> Bool {
        let device = defaultOutputDeviceID()
        guard device != kAudioObjectUnknown, isMuteSettable(device), let muted = readMute(device) else { return false }
        var value: UInt32 = muted ? 0 : 1
        var address = muteAddress
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    @discardableResult
    public static func selectDevice(_ id: UInt32) -> Bool {
        guard id != kAudioObjectUnknown, outputDeviceIDs().contains(id) else { return false }
        var target = AudioObjectID(id)
        var address = defaultDeviceAddress
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &target) == noErr
    }

    public static func symbolName(forName name: String, transportType: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods.gen3" }
        if lower.contains("homepod") { return "homepod.fill" }
        if lower.contains("headphone") || lower.contains("beats") || lower.contains("sony") || lower.contains("bose") {
            return "headphones"
        }
        switch transportType {
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeBuiltIn:
            return "display"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker"
        default:
            return "display"
        }
    }

    // MARK: - CoreAudio queries

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
              mScope: kAudioObjectPropertyScopeGlobal,
              mElement: kAudioObjectPropertyElementMain)
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDevices,
              mScope: kAudioObjectPropertyScopeGlobal,
              mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioDevicePropertyMute,
              mScope: kAudioDevicePropertyScopeOutput,
              mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDeviceID() -> AudioObjectID {
        var address = defaultDeviceAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return device
    }

    private static func outputDeviceIDs() -> [AudioObjectID] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { hasOutputStreams($0) }
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
              let name = unmanaged?.takeRetainedValue() as String? else { return nil }
        return name
    }

    private static func transportType(_ id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func readMute(_ id: AudioObjectID) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static func isMuteSettable(_ id: AudioObjectID) -> Bool {
        var address = muteAddress
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }
}

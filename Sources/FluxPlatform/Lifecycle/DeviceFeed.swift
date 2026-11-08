import CoreAudio
import Foundation
import IOKit
import FluxCore

private enum DeviceSignal: Hashable, Sendable { case registry(UInt32), audio }

/// At most four registry iterators and one audio-list change can be pending.
/// Each notification only schedules the first drain; later signals coalesce.
private final class DeviceSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<DeviceSignal> = []
    private var scheduled = false
    private var closed = false

    func insert(_ signal: DeviceSignal) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        pending.insert(signal)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
    func take() -> Set<DeviceSignal>? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty, !closed else { scheduled = false; return nil }
        let result = pending
        pending.removeAll(keepingCapacity: true)
        return result
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; pending.removeAll(); scheduled = false
    }
}

/// C receives an integer token, not a borrowed Swift instance pointer.
private final class DeviceCallbacks: @unchecked Sendable {
    static let shared = DeviceCallbacks()
    private let lock = NSLock()
    private var next: UInt = 0
    private var actions: [UInt: @Sendable (UInt32) -> Void] = [:]
    func add(_ action: @escaping @Sendable (UInt32) -> Void) -> UInt {
        lock.lock(); defer { lock.unlock() }
        repeat { next &+= 1 } while next == 0 || actions[next] != nil
        actions[next] = action
        return next
    }
    func remove(_ token: UInt) { lock.lock(); defer { lock.unlock() }; actions[token] = nil }
    func call(_ token: UInt, iterator: UInt32) {
        lock.lock(); let action = actions[token]; lock.unlock()
        action?(iterator)
    }
}

private final class DeviceRegistryWatch: @unchecked Sendable {
    struct Registration: Sendable { let iterator: UInt32 }
    let registrations: [Registration]
    private let port: IONotificationPortRef
    private let token: UInt
    private let queue = DispatchQueue(label: "com.flux.devices.registry", qos: .utility)

    init?(notify: @escaping @Sendable (UInt32) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        token = DeviceCallbacks.shared.add(notify)
        IONotificationPortSetDispatchQueue(port, queue)
        var registered: [Registration] = []
        for name in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            for connected in [true, false] {
                guard let matching = IOServiceMatching(name) else { continue }
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port,
                    connected ? kIOFirstMatchNotification : kIOTerminatedNotification, matching,
                    { context, iterator in
                        DeviceCallbacks.shared.call(UInt(bitPattern: context), iterator: iterator)
                    }, UnsafeMutableRawPointer(bitPattern: token), &iterator)
                if result == KERN_SUCCESS { registered.append(.init(iterator: iterator)) }
                else if iterator != 0 { IOObjectRelease(iterator) }
            }
        }
        registrations = registered
    }

    deinit {
        DeviceCallbacks.shared.remove(token)
        IONotificationPortDestroy(port)
        for registration in registrations { IOObjectRelease(registration.iterator) }
    }
}

/// Only connected Bluetooth HID and audio devices are read. No IOBluetooth,
/// radio scan, permission request, timer or log contains an accessory name.
/// Registry and HAL calls run on this actor, away from the UI actor.
public actor DeviceDriver {
    public nonisolated let snapshots: AsyncStream<[Accessory]?>
    private let output: AsyncStream<[Accessory]?>.Continuation
    private let signals = DeviceSignals()
    private var watch: DeviceRegistryWatch?
    private var audioObservation: AudioObservation?
    private var inventory = AccessoryInventory()
    private var previous: [Accessory]?
    private var active = false
    private var ended = false

    public init() {
        let channel = AsyncStream<[Accessory]?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = channel.stream; output = channel.continuation
    }

    public func start() -> [Accessory]? {
        guard !active, !ended else { return previous }
        active = true
        inventory.accept(Self.readAudio().map { Array($0.values) }, from: .audio)
        let signals = signals
        watch = DeviceRegistryWatch { [weak self] iterator in
            if signals.insert(.registry(iterator)) { Task { await self?.drainSignals() } }
        }
        for registration in watch?.registrations ?? [] { drain(registration) }
        inventory.accept(Self.readRegistry(), from: .registry)
        publish()
        let baseline = inventory.current
        audioObservation = AudioObservation(object: AudioObjectID(kAudioObjectSystemObject), address: Self.audioList) { [weak self] in
            if signals.insert(.audio) { Task { await self?.drainSignals() } }
        }
        // Reconcile the gap between the baseline and listener registration.
        inventory.accept(Self.readAudio().map { Array($0.values) }, from: .audio)
        publish()
        return baseline
    }

    public func stop() {
        guard !ended else { return }
        active = false; ended = true
        signals.close()
        watch = nil; audioObservation = nil
        inventory = AccessoryInventory(); previous = nil
        output.finish()
    }

    private func drainSignals() {
        guard active else { return }
        var rounds = 0
        while let batch = signals.take() {
            guard active else { return }
            for signal in batch {
                switch signal {
                case .audio: inventory.accept(Self.readAudio().map { Array($0.values) }, from: .audio)
                case .registry(let iterator):
                    if let registration = watch?.registrations.first(where: { $0.iterator == iterator }) { drain(registration) }
                }
            }
            // Notification iterators retain past services. Their order is
            // not current presence. Query the active matched set once after
            // draining; a delayed match cannot reinsert a terminated entry.
            inventory.accept(Self.readRegistry(), from: .registry)
            publish()
            rounds += 1
            if rounds == 16 {
                // Yield under a notification storm without creating one task
                // per event. The signal gate remains armed for this drain.
                Task { [weak self] in await self?.drainSignals() }
                return
            }
        }
    }

    private func drain(_ registration: DeviceRegistryWatch.Registration) {
        while true {
            let entry = IOIteratorNext(registration.iterator)
            guard entry != 0 else { break }
            IOObjectRelease(entry)
        }
    }

    private func publish() {
        guard let snapshot = inventory.current else { output.yield(nil); return }
        guard previous != snapshot else { return }
        previous = snapshot
        output.yield(snapshot)
    }

    private static func property(_ entry: UInt32, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func readRegistry() -> [Accessory]? {
        var result: [Accessory] = []
        for name in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            guard let matching = IOServiceMatching(name) else { return nil }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iterator) }
            var count = 0
            var oversized = false
            while true {
                let entry = IOIteratorNext(iterator)
                guard entry != 0 else { break }
                defer { IOObjectRelease(entry) }
                count += 1
                guard count <= 256 else { oversized = true; continue }
                guard let transport = property(entry, "Transport") as? String,
                      transport.lowercased().contains("bluetooth"),
                      (property(entry, "Built-In") as? NSNumber)?.boolValue != true else { continue }
                let name = property(entry, "Product") as? String ?? "Bluetooth Device"
                let pairs = property(entry, "DeviceUsagePairs") as? [[String: Any]] ?? []
                result.append(Accessory(name: name, kind: kind(name: name, pairs: pairs),
                                        percent: (property(entry, "BatteryPercent") as? NSNumber)?.intValue))
            }
            guard !oversized, result.count <= 256 else { return nil }
        }
        return result
    }
    static func kind(name: String, pairs: [[String: Any]]) -> AccessoryKind {
        for pair in pairs.prefix(32) where (pair["DeviceUsagePage"] as? Int) == 1 {
            switch pair["DeviceUsage"] as? Int {
            case 1?, 2?: return .mouse
            case 4?, 5?: return .controller
            case 6?, 7?: return .keyboard
            default: break
            }
        }
        let lower = name.lowercased()
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") || lower.contains("trackpad") { return .mouse }
        if lower.contains("controller") || lower.contains("gamepad") { return .controller }
        if ["airpods", "headphone", "headset", "buds", "beats", "speaker", "audio"].contains(where: lower.contains) { return .audio }
        if pairs.prefix(32).contains(where: { ($0["DeviceUsagePage"] as? Int) == 12 }) { return .audio }
        return .other
    }

    private static var audioList: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func readAudio() -> [UInt32: Accessory]? {
        var list = audioList
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 1024 else { return nil }
        if size == 0 { return [:] }
        let capacity = size
        var ids = [AudioObjectID](repeating: 0, count: Int(size / 4))
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr,
              size <= capacity, size % 4 == 0 else { return nil }
        var result: [UInt32: Accessory] = [:]
        for id in ids.prefix(Int(size / 4)) {
            var transport: UInt32 = 0
            var bytes: UInt32 = 4
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &transport) == noErr, bytes == 4 else { return nil }
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { continue }
            address.mSelector = kAudioObjectPropertyName
            var value: Unmanaged<CFString>?
            bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &value)
            let name = value?.takeRetainedValue()
            guard status == noErr, let name else { return nil }
            result[id] = Accessory(name: name as String, kind: .audio, percent: nil)
        }
        return result
    }
}

@MainActor public final class DeviceFeed: FeatureServiceHandle {
    private let driver: DeviceDriver
    private var task: Task<Void, Never>?
    private var receive: ((AccessoryConnection) -> Void)?
    private var presence = AccessoryPresence()
    private var active = true

    public init(driver: DeviceDriver = DeviceDriver(), receive: @escaping (AccessoryConnection) -> Void) {
        self.driver = driver; self.receive = receive
        task = Task { @MainActor [weak self, driver] in
            let baseline = await driver.start()
            if let owner = self, owner.active, !Task.isCancelled { _ = owner.presence.accept(baseline) }
            for await snapshot in driver.snapshots {
                guard let self, self.active, !Task.isCancelled else { return }
                for event in self.presence.accept(snapshot) { self.receive?(event) }
            }
        }
    }
    deinit { task?.cancel(); let driver = driver; Task { await driver.stop() } }
    public func stop() {
        guard active else { return }
        active = false
        receive = nil; task?.cancel(); task = nil
        let driver = driver
        Task { await driver.stop() }
    }
}

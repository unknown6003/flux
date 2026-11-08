import AppKit
import FluxCore
import FluxPlatform
import FluxUI

public enum NotchRuntimeFailure: Sendable {
    case service(FeatureService)
    case widget(WidgetFailure)
}

/// Owns the demand, feeds and window together. Construction opens no hardware,
/// reads no pasteboard and creates no window. The application calls start once
/// its menu and shortcut owners exist, and stop before ending its session.
@MainActor
public final class NotchRuntime: WidgetEffects {
    public struct Callbacks {
        public var report: @MainActor (NotchRuntimeFailure) -> Void
        public var event: @MainActor (WidgetEvent) -> Void
        public var battery: @MainActor (PowerSnapshot?) -> Void
        public var volume: @MainActor (VolumeSnapshot?) -> Void
        public var device: @MainActor (AccessoryConnection) -> Void
        public var compactAction: @MainActor (CompactNotchAction) -> Void
        public var cameraRunning: @MainActor (Bool) -> Void
        public var accessChanged: @MainActor () -> Void
        /// Required platform owner for the lock-screen bridge.
        /// A failure remains visible to the application; it is never a no-op.
        public var makeAdditionalService: @MainActor (FeatureService) throws -> any FeatureServiceHandle

        public init(report: @escaping @MainActor (NotchRuntimeFailure) -> Void,
                    event: @escaping @MainActor (WidgetEvent) -> Void,
                    battery: @escaping @MainActor (PowerSnapshot?) -> Void,
                    volume: @escaping @MainActor (VolumeSnapshot?) -> Void,
                    device: @escaping @MainActor (AccessoryConnection) -> Void,
                    compactAction: @escaping @MainActor (CompactNotchAction) -> Void,
                    cameraRunning: @escaping @MainActor (Bool) -> Void,
                    accessChanged: @escaping @MainActor () -> Void,
                    makeAdditionalService: @escaping @MainActor (FeatureService) throws -> any FeatureServiceHandle) {
            self.report = report; self.event = event; self.battery = battery
            self.volume = volume; self.device = device; self.compactAction = compactAction
            self.cameraRunning = cameraRunning; self.accessChanged = accessChanged
            self.makeAdditionalService = makeAdditionalService
        }
    }

    private let preferences: PreferenceStore
    private let callbacks: Callbacks
    private let shelf: ShelfFiles
    private let clipboard: ClipboardRepository
    private let pasteboard: PasteboardChannel
    private let mediaScript: URL
    private let mediaFramework: URL
    private let permission: @MainActor (SystemPermission) -> SystemAccess
    private let serviceOverride: FeatureRuntime.Factory?
    private var active = false
    private var visibleWidget: Widget?
    private var phase: SessionPhase = .locked
    private var monitor: SessionMonitor?
    private weak var volumeFeed: VolumeFeed?

    private lazy var widgets = WidgetCoordinator(
        preferences: preferences, shelf: shelf, clipboard: clipboard, pasteboard: pasteboard,
        mediaScript: mediaScript, mediaFramework: mediaFramework, effects: self)
    private lazy var services = FeatureRuntime { [unowned self] in try self.makeService($0) }
    private lazy var window = NotchWindowCoordinator(callbacks: .init(
        willShowWidget: { [unowned self] _, next in
            self.visibleWidget = next
            self.applyDemand()
        },
        makeWidget: { [unowned self] in self.widgets.makeWidget($0) },
        willDismissWidget: { [unowned self] _ in
            self.visibleWidget = nil
            self.applyDemand()
            self.widgets.dismiss()
        },
        compactAction: { [unowned self] in self.callbacks.compactAction($0) }))

    public convenience init(preferences: PreferenceStore, files: ApplicationFiles,
                            mediaScript: URL, mediaFramework: URL, callbacks: Callbacks) {
        self.init(preferences: preferences, files: files, mediaScript: mediaScript,
                  mediaFramework: mediaFramework, callbacks: callbacks,
                  permission: PermissionAccess.status, serviceOverride: nil)
    }

    init(preferences: PreferenceStore, files: ApplicationFiles, mediaScript: URL,
         mediaFramework: URL, callbacks: Callbacks,
         permission: @escaping @MainActor (SystemPermission) -> SystemAccess,
         serviceOverride: FeatureRuntime.Factory?) {
        self.preferences = preferences; self.callbacks = callbacks
        shelf = ShelfFiles(root: files.shelf)
        clipboard = ClipboardRepository(historyURL: files.clipboardHistory)
        pasteboard = PasteboardChannel()
        self.mediaScript = mediaScript; self.mediaFramework = mediaFramework
        self.permission = permission; self.serviceOverride = serviceOverride
    }

    public var activeServices: Set<FeatureService> { active ? services.active : [] }
    public var presentation: NotchWindowCoordinator.Presentation { active ? window.presentation : .hidden }

    public func start() {
        guard !active else { refresh(); return }
        let monitor = SessionMonitor(onPhase: { [weak self] in self?.setPhase($0) },
                                     onEnvironmentChange: { [weak self] in self?.refresh() })
        self.monitor = monitor
        begin(phase: monitor.phase)
        refresh()
    }

    /// Start the demand transaction separately from session observation and UI.
    /// Native tests drive lock transitions through this same owner.
    func begin(phase: SessionPhase) {
        guard !active else { return }
        active = true
        self.phase = phase
        applyDemand()
    }

    public func stop() {
        guard active else { return }
        active = false
        monitor?.stop(); monitor = nil
        services.stop()
        callbacks.cameraRunning(false)
        window.stop()
        widgets.dismiss()
        visibleWidget = nil
    }

    /// Re-read saved options and current grants after an explicit change or
    /// an environment notification. This is not a polling entry point.
    public func refresh() {
        guard active else { return }
        applyDemand()
        if preferences.value(for: Preferences.notchEnabled), let screen = NSScreen.main ?? NSScreen.screens.first {
            let configuration = FeatureConfiguration(preferences: preferences)
            let order = WidgetOrder(saved: preferences.value(for: Preferences.widgetOrder)).widgets
            window.start(screen: screen, widgets: order.filter { configuration.enabledWidgets.contains($0) })
            window.setSessionLocked(phase != .unlocked)
            window.setHover(enabled: preferences.value(for: Preferences.expansionTrigger) == .hover,
                            closeDelay: preferences.value(for: Preferences.hoverCloseDelay))
        } else { window.stop() }
        widgets.refresh()
    }

    public func toggle() { guard active else { return }; window.toggle() }
    public func collapse() { guard active else { return }; window.collapse() }
    public func updateActivity(_ item: ActivityItem?, artwork: NSImage?, count: Int, restorableCount: Int) {
        guard active else { return }
        window.updateActivity(item, artwork: artwork, queueCount: count, restorableCount: restorableCount)
    }

    public func clearClipboardHistory() async throws { try await widgets.clearClipboardHistory() }
    public func setClipboardPersistence(_ enabled: Bool) async throws { try await widgets.setClipboardPersistence(enabled) }

    public func adjustVolume(by delta: Float) async -> Bool {
        guard active, phase == .unlocked, let volumeFeed else { return false }
        return await volumeFeed.adjust(by: delta)
    }
    public func toggleMute() async -> Bool {
        guard active, phase == .unlocked, let volumeFeed else { return false }
        return await volumeFeed.toggleMute()
    }

    func setPhase(_ next: SessionPhase) {
        guard active else { return }
        phase = next
        // Stop private services before the old view can be removed or redrawn.
        applyDemand()
        window.setSessionLocked(next != .unlocked)
        widgets.refresh()
    }

    private var demand: FeatureDemand {
        FeatureDemand(configuration: FeatureConfiguration(preferences: preferences), phase: phase,
                      visibleWidget: visibleWidget, cameraAllowed: permission(.camera) == .allowed,
                      calendarAllowed: permission(.calendar) == .allowed)
    }

    private func applyDemand() {
        guard active else { return }
        for failure in services.apply(demand) { callbacks.report(.service(failure)) }
    }

    private func makeService(_ service: FeatureService) throws -> any FeatureServiceHandle {
        if let serviceOverride { return try serviceOverride(service) }
        switch service {
        case .camera: return widgets.startCameraFeed()
        case .clipboard: return widgets.startClipboardFeed()
        case .media: return widgets.startMediaFeed()
        case .calendar: return widgets.startCalendarFeed()
        case .battery: return BatteryFeed(onChange: callbacks.battery)
        case .volume:
            let feed = VolumeFeed(onChange: callbacks.volume)
            volumeFeed = feed
            return feed
        case .devices: return DeviceFeed(receive: callbacks.device)
        case .lockScreen: return try callbacks.makeAdditionalService(service)
        }
    }

    // MARK: WidgetEffects

    public func requestAccess(_ permission: WidgetPermission) async {
        let system: SystemPermission = switch permission { case .calendar: .calendar; case .camera: .camera }
        _ = await PermissionAccess.request(system)
        guard active else { return }
        monitor?.refresh()
        refresh()
        callbacks.accessChanged()
    }

    public func openSettings(_ permission: WidgetPermission) {
        let system: SystemPermission = switch permission { case .calendar: .calendar; case .camera: .camera }
        PermissionAccess.openSettings(system)
    }

    public func retry(_ service: FeatureService) {
        guard active else { return }
        // Remove the requested service for one transaction. A ready-looking
        // but failed handle must not suppress a new explicit retry.
        var stopped = demand
        switch service {
        case .media:
            stopped.configuration.enabledWidgets.remove(.nowPlaying)
            stopped.configuration.lockScreenMediaEnabled = false
        case .calendar:
            stopped.calendarAllowed = false
        case .camera:
            stopped.cameraAllowed = false
        case .clipboard:
            stopped.configuration.enabledWidgets.remove(.clipboard)
        case .battery: stopped.configuration.batteryEnabled = false
        case .devices: stopped.configuration.devicesEnabled = false
        case .volume: stopped.configuration.soundHUDEnabled = false
        case .lockScreen: stopped.configuration.lockScreenEnabled = false
        }
        services.apply(stopped)
        applyDemand()
        widgets.refresh()
    }

    public func report(_ failure: WidgetFailure) { callbacks.report(.widget(failure)) }
    public func widgetEvent(_ event: WidgetEvent) {
        if case .camera(let state) = event { callbacks.cameraRunning(state == .running) }
        callbacks.event(event)
    }
}

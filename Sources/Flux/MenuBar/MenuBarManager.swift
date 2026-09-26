import AppKit
import Combine

/// Owns Flux's two status items and the single hidden drawer boundary.
@MainActor
final class MenuBarManager {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let timerService: TimerService?
    private let onOpenSettings: () -> Void

    private let chevron: ControlItem
    private let hiddenDivider: ControlItem
    private var revealHidden = false

    private var rehideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var overflowTimer: Timer?
    private var overflowRefreshWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private static let overflowSlack: CGFloat = 2

    init(settings: SettingsStore,
         arranger: MenuBarArranger,
         timerService: TimerService? = nil,
         onOpenSettings: @escaping () -> Void) {
        self.settings = settings
        self.arranger = arranger
        self.timerService = timerService
        self.onOpenSettings = onOpenSettings

        if !ControlItem.usesMacOS27Model {
            ControlItem.sanitizePersistedPositions(autosaveNames: ControlItem.allAutosaveNames)
            ControlItem.migrateLayoutIfNeeded(autosaveNames: ControlItem.allAutosaveNames)
            ControlItem.assignDefaultPositionsIfUnset()
        }

        self.chevron = ControlItem(role: .chevron, autosaveName: "flux.chevron")
        self.hiddenDivider = ControlItem(role: .divider, autosaveName: "flux.divider.hidden")

        wireChevron()
        observeSettings()
        arranger.onChange = { [weak self] on in self?.applyArrangeMode(on) }
        applyState()
        Log.menuBar.info("MenuBarManager initialised with one hidden drawer")
    }

    // MARK: Setup

    private func wireChevron() {
        chevron.onToggle = { [weak self] in self?.handleToggle() }
        chevron.onShowMenu = { [weak self] in self?.showMenu() }
        chevron.setStyle(settings.iconStyle)
    }

    private func observeSettings() {
        settings.$iconStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] style in self?.chevron.setStyle(style) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyState() }
            .store(in: &cancellables)
    }

    // MARK: Reveal state

    private var isAnyRevealed: Bool { revealHidden }

    private func handleToggle() {
        if arranger.isArranging {
            arranger.setArranging(false)
            return
        }
        if isAnyRevealed {
            collapse()
        } else {
            revealHidden = true
            applyState()
            scheduleAutoRehideIfNeeded()
        }
    }

    func toggleReveal() {
        if arranger.isArranging {
            arranger.setArranging(false)
        } else if isAnyRevealed {
            collapse()
        } else {
            revealHidden = true
            applyState()
            scheduleAutoRehideIfNeeded()
        }
    }

    func collapse() {
        revealHidden = false
        applyState()
    }

    func beginIconManagement() {
        revealHidden = true
        hiddenDivider.setCollapsed(false)
        chevron.setChevron(revealed: true)
    }

    func endIconManagement() {
        revealHidden = false
        applyState()
    }

    /// Kept as a small compatibility entry point for the hotkey/menu self-test.
    /// There is only one drawer now, so "all" means the same as "hidden".
    func revealAll() {
        revealHidden = true
        applyState()
        scheduleAutoRehideIfNeeded()
    }

    private func applyState() {
        guard !arranger.isArranging else { return }
        hiddenDivider.setCollapsed(!revealHidden)
        chevron.setChevron(revealed: revealHidden)
        updateOutsideClickMonitor(active: revealHidden)
        scheduleOverflowRefresh()
    }

    private func scheduleOverflowRefresh() {
        overflowRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.arranger.isArranging else { return }
            self.refreshOverflow()
        }
        overflowRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Legacy live-bar marker bridge

    /// The Settings drawer is the normal management path. This small bridge keeps
    /// the old overflow activity safe if a stale activity or external caller enters
    /// the transient marker state during an upgrade.
    private func applyArrangeMode(_ entering: Bool) {
        if entering {
            rehideTimer?.invalidate()
            rehideTimer = nil
            updateOutsideClickMonitor(active: false)
            revealHidden = true
            chevron.setArranging(true)
            hiddenDivider.setArrangingMarker(true, zone: .hidden)
            startOverflowMonitor()
        } else {
            stopOverflowMonitor()
            chevron.setArranging(false)
            hiddenDivider.setArrangingMarker(false)
            revealHidden = false
            applyState()
        }
    }

    // MARK: Notch overflow

    private func startOverflowMonitor() {
        refreshOverflow()
        overflowTimer?.invalidate()
        overflowTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOverflow() }
        }
    }

    private func stopOverflowMonitor() {
        overflowTimer?.invalidate()
        overflowTimer = nil
    }

    private var shouldMonitorOverflow: Bool { arranger.isArranging || revealHidden }

    private func refreshOverflow() {
        guard shouldMonitorOverflow else {
            arranger.setOverflow(arrange: false, notch: false, iconCount: 0)
            return
        }
        guard let deficit = computeOverflowDeficit() else {
            if !arranger.isArranging { scheduleOverflowRefresh() }
            return
        }
        let over = deficit > 0
        arranger.setOverflow(arrange: arranger.isArranging && over,
                             notch: over,
                             iconCount: Self.iconsToClear(deficit, compact: MenuBarSpacing.isCompact))
    }

    private func computeOverflowDeficit() -> CGFloat? {
        guard let screen = menuBarScreen() else { return 0 }
        guard let frame = hiddenDivider.statusItem.button?.window?.frame else { return 0 }
        guard frame.width <= screen.frame.width else { return nil }
        guard frame.width >= 1 else { return .greatestFiniteMagnitude }
        return max(0, (screen.statusItemRegion.minX + Self.overflowSlack) - frame.minX)
    }

    static func iconsToClear(_ deficit: CGFloat, compact: Bool) -> Int {
        guard deficit > 0 else { return 0 }
        let perIcon: CGFloat = compact ? 28 : 38
        return max(1, Int(min(deficit / perIcon, 99).rounded(.up)))
    }

    private func menuBarScreen() -> NSScreen? {
        if let window = chevron.statusItem.button?.window {
            let mid = NSPoint(x: window.frame.midX, y: window.frame.midY)
            return NSScreen.screens.first { $0.frame.contains(mid) } ?? window.screen ?? NSScreen.main
        }
        return NSScreen.main
    }

    /// The x boundary used by `MenuBarIconManager` to split Shown and Hidden.
    var drawerBoundaryX: CGFloat? {
        hiddenDivider.statusItem.button?.window?.frame.maxX
            ?? chevron.statusItem.button?.window?.frame.minX
    }

    // MARK: Auto-hide

    private func scheduleAutoRehideIfNeeded() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        guard !arranger.isArranging, settings.autoRehide, revealHidden else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoRehideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
    }

    private func updateOutsideClickMonitor(active: Bool) {
        if active, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    if self.clickIsInMenuBar(location) { self.scheduleAutoRehideIfNeeded() }
                    else { self.collapse() }
                }
            }
        } else if !active, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func clickIsInMenuBar(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main else { return false }
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return location.y >= screen.frame.maxY - height
    }

    // MARK: Menu

    var pendingUpdateVersion: (() -> String?)?
    var onOpenSettingsTab: ((SettingsTab) -> Void)?

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Flux")
        menu.autoenablesItems = false

        if let version = pendingUpdateVersion?() {
            let item = makeItem("Update to \(version)…", #selector(menuOpenUpdateSettings))
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if arranger.isArranging {
            menu.addItem(makeItem("Done", #selector(menuToggleArrange)))
        } else {
            menu.addItem(makeItem(isAnyRevealed ? "Hide Menu Bar Items" : "Reveal Hidden Items", #selector(menuToggle)))
            menu.addItem(.separator())
            menu.addItem(makeItem("Manage Menu Bar Icons…", #selector(menuOpenMenuBarSettings)))
        }
        if timerService != nil {
            menu.addItem(.separator())
            menu.addItem(makeTimerMenuItem())
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Flux Settings…", #selector(menuOpenSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Flux", #selector(menuQuit), key: "q"))
        return menu
    }

    private func showMenu() {
        let menu = makeMenu()
        if let button = chevron.statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func makeTimerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Start Timer", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Start Timer")
        submenu.autoenablesItems = false
        for minutes in TimerActivity.presetMinutes {
            let timerItem = makeItem("\(minutes) minutes", #selector(menuStartTimer(_:)))
            timerItem.representedObject = NSNumber(value: minutes)
            submenu.addItem(timerItem)
        }
        if timerService?.timers.isEmpty == false {
            submenu.addItem(.separator())
            submenu.addItem(makeItem("Stop All Timers", #selector(menuStopAllTimers)))
        }
        item.submenu = submenu
        return item
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuToggle() { toggleReveal() }
    @objc private func menuToggleArrange() { arranger.setArranging(false) }
    @objc private func menuOpenMenuBarSettings() { onOpenSettingsTab?(.menuBar) ?? onOpenSettings() }

    @objc private func menuStartTimer(_ sender: NSMenuItem) {
        guard let minutes = (sender.representedObject as? NSNumber)?.intValue,
              TimerActivity.presetMinutes.contains(minutes) else { return }
        timerService?.start(duration: TimeInterval(minutes * 60),
                            label: TimerActivity.defaultLabel(minutes: minutes))
    }

    @objc private func menuStopAllTimers() {
        guard let timerService else { return }
        for timer in timerService.timers { timerService.cancel(timer.id) }
    }

    // MARK: Diagnostics

    struct Diagnostics: Equatable {
        var revealHidden: Bool
        var hiddenDividerLength: CGFloat
        var chevronRevealed: Bool
        var isArranging: Bool
        var hiddenMarkerShown: Bool
    }

    var diagnostics: Diagnostics {
        Diagnostics(revealHidden: revealHidden,
                    hiddenDividerLength: hiddenDivider.statusItem.length,
                    chevronRevealed: chevron.isRevealed,
                    isArranging: arranger.isArranging,
                    hiddenMarkerShown: hiddenDivider.isArranging)
    }

    @objc private func menuOpenSettings() { onOpenSettings() }

    @objc private func menuOpenUpdateSettings() {
        if let onOpenSettingsTab { onOpenSettingsTab(.general) } else { onOpenSettings() }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    deinit {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        overflowTimer?.invalidate()
        overflowRefreshWork?.cancel()
    }
}

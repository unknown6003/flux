import AppKit
import Combine

/// Owns Flux's controls and the three-zone drawer state machine.
@MainActor
final class MenuBarManager {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let timerService: TimerService?
    private let onOpenSettings: () -> Void

    private let chevron: ControlItem
    private let hiddenDivider: ControlItem
    private let alwaysHiddenDivider: ControlItem

    private var revealHidden = false
    private var revealAlwaysHidden = false
    private var managingIcons = false

    private var rehideTimer: Timer?
    private var outsideClickMonitor: Any?
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
        self.alwaysHiddenDivider = ControlItem(role: .divider, autosaveName: "flux.divider.alwaysHidden")

        wireChevron()
        observeSettings()
        applyState()
        Log.menuBar.info("MenuBarManager initialised with the three-zone drawer")
    }

    // MARK: Setup

    private func wireChevron() {
        chevron.onToggle = { [weak self] in self?.handleToggle() }
        chevron.onShowMenu = { [weak self] in self?.showMenu() }
        chevron.setStyle(settings.iconStyle)
    }

    private func observeSettings() {
        settings.$showAlwaysHiddenSection
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled { self.revealAlwaysHidden = false }
                self.alwaysHiddenDivider.setVisible(enabled)
                self.applyState()
            }
            .store(in: &cancellables)

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

    private var isAnyRevealed: Bool { revealHidden || revealAlwaysHidden }

    private func handleToggle() {
        let optionDown = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if optionDown && settings.showAlwaysHiddenSection {
            revealHidden = true
            revealAlwaysHidden = true
        } else if isAnyRevealed {
            collapse()
            return
        } else {
            revealHidden = true
            revealAlwaysHidden = false
        }
        applyState()
        scheduleAutoRehideIfNeeded()
    }

    /// Public entry point for the hotkey and menu.
    func toggleReveal() {
        if isAnyRevealed {
            collapse()
        } else {
            revealHidden = true
            revealAlwaysHidden = false
            applyState()
            scheduleAutoRehideIfNeeded()
        }
    }

    func collapse() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        revealHidden = false
        revealAlwaysHidden = false
        applyState()
    }

    /// Keep every zone open while the Settings drawer reads the real bar.
    func beginIconManagement() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        managingIcons = true
        revealHidden = true
        revealAlwaysHidden = settings.showAlwaysHiddenSection
        applyState()
    }

    func endIconManagement() {
        managingIcons = false
        collapse()
    }

    func revealAll() {
        revealHidden = true
        revealAlwaysHidden = settings.showAlwaysHiddenSection
        applyState()
        scheduleAutoRehideIfNeeded()
    }

    private func applyState() {
        alwaysHiddenDivider.setVisible(settings.showAlwaysHiddenSection)
        let showHidden = revealHidden || revealAlwaysHidden
        let showAlwaysHidden = revealAlwaysHidden && settings.showAlwaysHiddenSection
        hiddenDivider.setCollapsed(!showHidden)
        alwaysHiddenDivider.setCollapsed(!showAlwaysHidden)
        chevron.setChevron(revealed: isAnyRevealed)
        updateOutsideClickMonitor(active: isAnyRevealed && !managingIcons)
        scheduleOverflowRefresh()
    }

    private func scheduleOverflowRefresh() {
        overflowRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshOverflow() }
        overflowRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Notch overflow

    private func refreshOverflow() {
        guard isAnyRevealed else {
            arranger.setOverflow(arrange: false, notch: false, iconCount: 0)
            return
        }
        guard let deficit = computeOverflowDeficit() else { return }
        let over = deficit > 0
        arranger.setOverflow(arrange: false,
                             notch: over,
                             iconCount: Self.iconsToClear(deficit, compact: MenuBarSpacing.isCompact))
    }

    private func computeOverflowDeficit() -> CGFloat? {
        guard let screen = menuBarScreen() else { return 0 }
        let boundary = revealAlwaysHidden ? alwaysHiddenDivider : hiddenDivider
        guard let frame = boundary.statusItem.button?.window?.frame else { return nil }
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

    /// Boundaries used by the Settings drawer to classify and move real icons.
    var drawerBoundaries: (hidden: CGFloat?, alwaysHidden: CGFloat?) {
        (hidden: hiddenDivider.statusItem.button?.window?.frame.maxX,
         alwaysHidden: settings.showAlwaysHiddenSection
            ? alwaysHiddenDivider.statusItem.button?.window?.frame.maxX
            : nil)
    }

    // MARK: Auto-hide

    private func scheduleAutoRehideIfNeeded() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        guard !managingIcons, settings.autoRehide, isAnyRevealed else { return }
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

        menu.addItem(makeItem(isAnyRevealed ? "Hide Menu Bar Items" : "Reveal Hidden Items", #selector(menuToggle)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Manage Menu Bar Icons…", #selector(menuOpenMenuBarSettings)))
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
        var revealAlwaysHidden: Bool
        var hiddenDividerLength: CGFloat
        var alwaysHiddenDividerLength: CGFloat
        var chevronRevealed: Bool
        var managingIcons: Bool
    }

    var diagnostics: Diagnostics {
        Diagnostics(revealHidden: revealHidden,
                    revealAlwaysHidden: revealAlwaysHidden,
                    hiddenDividerLength: hiddenDivider.statusItem.length,
                    alwaysHiddenDividerLength: alwaysHiddenDivider.statusItem.length,
                    chevronRevealed: chevron.isRevealed,
                    managingIcons: managingIcons)
    }

    @objc private func menuOpenSettings() { onOpenSettings() }

    @objc private func menuOpenUpdateSettings() {
        if let onOpenSettingsTab { onOpenSettingsTab(.general) } else { onOpenSettings() }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    deinit {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        overflowRefreshWork?.cancel()
    }
}

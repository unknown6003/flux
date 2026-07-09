import AppKit
import Combine

/// Owns Flux's control items and the reveal/collapse state machine.
///
/// State is two booleans:
///   • `revealHidden`        — the Hidden section is showing
///   • `revealAlwaysHidden`  — the Always-Hidden section is showing (implies the
///                             Hidden section is showing too, since it sits to
///                             the left of the Hidden divider)
@MainActor
final class MenuBarManager {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let onOpenSettings: () -> Void

    private let chevron: ControlItem
    private let hiddenDivider: ControlItem
    private var alwaysHiddenDivider: ControlItem?

    private var revealHidden = false
    private var revealAlwaysHidden = false

    private var rehideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore,
         arranger: MenuBarArranger,
         onOpenSettings: @escaping () -> Void) {
        self.settings = settings
        self.arranger = arranger
        self.onOpenSettings = onOpenSettings

        // Before creating any status items: (1) drop any off-screen-corrupt saved
        // positions so a polluted layout can't strand the chevron off-screen, then
        // (2) seed a sane default layout (chevron rightmost, next to the clock) for
        // any item the user hasn't positioned themselves.
        ControlItem.sanitizePersistedPositions(autosaveNames: [
            "flux.chevron", "flux.divider.hidden", "flux.divider.alwaysHidden",
        ])
        ControlItem.assignDefaultPositionsIfUnset()

        // Created right-to-left so creation order matches visual order on first
        // launch: chevron nearest the clock, dividers to its left.
        self.chevron = ControlItem(role: .chevron, autosaveName: "flux.chevron")
        self.hiddenDivider = ControlItem(role: .divider, autosaveName: "flux.divider.hidden")

        wireChevron()
        configureAlwaysHiddenSection()
        observeSettings()

        // Arrange Mode can be toggled from the Settings window or the menu; route
        // both through the engine so it owns the real menu-bar side effects.
        arranger.onChange = { [weak self] on in self?.applyArrangeMode(on) }

        // Start collapsed (the default): hide everything in the Hidden /
        // Always-Hidden zones. If the user disabled auto-hide-on-launch, begin
        // with the Hidden section revealed so nothing disappears until they ask.
        if !settings.autoHideOnLaunch {
            revealHidden = true
        }
        applyState(animated: false)
        Log.menuBar.info("MenuBarManager initialised (alwaysHidden=\(self.settings.showAlwaysHiddenSection))")
    }

    // MARK: Setup

    private func wireChevron() {
        chevron.onToggle = { [weak self] in self?.handleToggle() }
        chevron.onShowMenu = { [weak self] in self?.showMenu() }
        chevron.setStyle(settings.iconStyle)
    }

    private func configureAlwaysHiddenSection() {
        if settings.showAlwaysHiddenSection {
            if alwaysHiddenDivider == nil {
                alwaysHiddenDivider = ControlItem(role: .divider,
                                                  autosaveName: "flux.divider.alwaysHidden")
            }
        } else {
            alwaysHiddenDivider?.removeFromStatusBar()
            alwaysHiddenDivider = nil
            revealAlwaysHidden = false
        }
    }

    private func observeSettings() {
        settings.$showAlwaysHiddenSection
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.configureAlwaysHiddenSection()
                // While arranging, re-apply markers so a newly created (or removed)
                // Always-Hidden divider joins the arrange layout instead of the
                // normal collapsed geometry.
                if self.arranger.isArranging {
                    self.applyArrangeMode(true)
                } else {
                    self.applyState(animated: true)
                }
            }
            .store(in: &cancellables)

        settings.$iconStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                self?.chevron.setStyle(style)
            }
            .store(in: &cancellables)
    }

    // MARK: State machine

    private var isAnyRevealed: Bool { revealHidden || revealAlwaysHidden }

    private func handleToggle() {
        // In Arrange Mode the chevron is a "Done" button — a left-click finishes.
        if arranger.isArranging {
            arranger.setArranging(false)
            return
        }

        let optionDown = NSApp.currentEvent?.modifierFlags.contains(.option) == true

        if optionDown, settings.showAlwaysHiddenSection {
            // Option-click reveals absolutely everything.
            revealHidden = true
            revealAlwaysHidden = true
        } else if isAnyRevealed {
            revealHidden = false
            revealAlwaysHidden = false
        } else {
            revealHidden = true
            revealAlwaysHidden = false
        }
        applyState(animated: true)
        scheduleAutoRehideIfNeeded()
    }

    /// Public entry point for the hotkey and menu.
    func toggleReveal() {
        // The hotkey shouldn't reveal/hide mid-arrange — treat it as "Done".
        if arranger.isArranging {
            arranger.setArranging(false)
            return
        }
        if isAnyRevealed {
            collapse(animated: true)
        } else {
            revealHidden = true
            revealAlwaysHidden = false
            applyState(animated: true)
            scheduleAutoRehideIfNeeded()
        }
    }

    func collapse(animated: Bool) {
        revealHidden = false
        revealAlwaysHidden = false
        applyState(animated: animated)
    }

    /// Reveal every section, including Always-Hidden. Entry point for the menu,
    /// the option-click path, and the self-test.
    func revealAll() {
        revealHidden = true
        revealAlwaysHidden = settings.showAlwaysHiddenSection
        applyState(animated: true)
        scheduleAutoRehideIfNeeded()
    }

    private func applyState(animated: Bool) {
        // Arrange Mode owns the bar geometry (labeled markers, everything shown);
        // don't let a stray settings change collapse a marker mid-arrange.
        guard !arranger.isArranging else { return }

        let showHidden = revealHidden || revealAlwaysHidden
        let showAlwaysHidden = revealAlwaysHidden

        hiddenDivider.setCollapsed(!showHidden, animated: animated)
        alwaysHiddenDivider?.setCollapsed(!showAlwaysHidden, animated: animated)
        chevron.setChevron(revealed: showHidden)

        updateOutsideClickMonitor(active: showHidden)
    }

    // MARK: Arrange Mode

    /// Enter or leave **Arrange Menu Bar** mode. On entry every icon is revealed
    /// and each divider shows a labeled marker so the user can ⌘-drag icons into
    /// the right zone; auto-rehide and the outside-click monitor are suspended so
    /// the bar stays put while they drag. On exit the markers disappear and the
    /// new arrangement takes effect (collapse back to the resting state).
    ///
    /// Called only via `arranger.onChange`, so `arranger.isArranging` already
    /// reflects `entering` by the time we run.
    private func applyArrangeMode(_ entering: Bool) {
        if entering {
            rehideTimer?.invalidate()
            rehideTimer = nil
            updateOutsideClickMonitor(active: false)

            // Reveal everything so all icons are on the bar to be dragged.
            revealHidden = true
            revealAlwaysHidden = settings.showAlwaysHiddenSection

            chevron.setArranging(true)
            // Each divider names the zone to its left, so the right-to-left order
            // (Shown │ Hidden │ Always-Hidden) reads straight off the bar. Shown
            // owns no divider — it's simply the area to the right of ◀ Hidden.
            hiddenDivider.setArrangingMarker(true, zone: .hidden)
            if settings.showAlwaysHiddenSection {
                alwaysHiddenDivider?.setArrangingMarker(true, zone: .alwaysHidden)
            } else {
                alwaysHiddenDivider?.setArrangingMarker(false)
            }
            Log.menuBar.info("Entered Arrange Mode")
        } else {
            chevron.setArranging(false)
            hiddenDivider.setArrangingMarker(false)
            alwaysHiddenDivider?.setArrangingMarker(false)

            // Apply the new arrangement: collapse back to the resting state.
            revealHidden = false
            revealAlwaysHidden = false
            applyState(animated: true)
            Log.menuBar.info("Exited Arrange Mode")
        }
    }

    // MARK: Auto-rehide

    private func scheduleAutoRehideIfNeeded() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        guard !arranger.isArranging else { return }
        guard settings.autoRehide, isAnyRevealed, settings.autoRehideDelay > 0 else { return }

        rehideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoRehideDelay,
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.collapse(animated: true) }
        }
    }

    /// While items are revealed, a click in the *content area* (below the menu
    /// bar) re-hides them, matching Bartender's behaviour. A click **on the menu
    /// bar itself keeps the reveal open** — the user is interacting with a
    /// just-revealed item, and re-hiding it out from under the click is exactly
    /// the bug this avoids; instead we give it a fresh auto-rehide window so it
    /// collapses only once they're done. Uses a global monitor (passive — it does
    /// not consume the click) so the click still reaches its target.
    private func updateOutsideClickMonitor(active: Bool) {
        if active, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                // Capture the location synchronously — the cursor may move before
                // the hop to the main actor below.
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    if self.clickIsInMenuBar(location) {
                        self.scheduleAutoRehideIfNeeded()
                    } else {
                        self.collapse(animated: true)
                    }
                }
            }
        } else if !active, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Whether a screen-coordinate point falls within the menu-bar strip at the
    /// top of whichever screen contains it. `NSScreen.frame.maxY` is the top edge;
    /// `visibleFrame.maxY` sits just below the menu bar, so their difference is the
    /// menu-bar height (correct on notched Macs too). Falls back to the status-bar
    /// thickness if a screen reports no inset.
    private func clickIsInMenuBar(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? NSScreen.main else { return false }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY,
                                NSStatusBar.system.thickness)
        return location.y >= screen.frame.maxY - menuBarHeight
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()

        if arranger.isArranging {
            // Mid-arrange the reveal/hide actions don't apply — offer only "Done".
            menu.addItem(makeItem("Done Arranging", #selector(menuToggleArrange)))
        } else {
            let toggleTitle = isAnyRevealed ? "Hide Menu Bar Items" : "Reveal Hidden Items"
            menu.addItem(makeItem(toggleTitle, #selector(menuToggle)))

            if settings.showAlwaysHiddenSection {
                menu.addItem(makeItem("Reveal Always-Hidden Items", #selector(menuRevealAll)))
            }
            menu.addItem(.separator())
            menu.addItem(makeItem("Arrange Menu Bar Items…", #selector(menuToggleArrange)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Flux Settings…", #selector(menuOpenSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Flux", #selector(menuQuit), key: "q"))

        // Pop the menu directly under the chevron. Using popUp(positioning:…)
        // avoids assigning statusItem.menu, which would otherwise suppress the
        // left-click toggle action.
        if let button = chevron.statusItem.button {
            let origin = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuToggle() { toggleReveal() }

    @objc private func menuRevealAll() { revealAll() }

    @objc private func menuToggleArrange() { arranger.toggle() }

    // MARK: Diagnostics

    /// A snapshot of the engine's live geometry. Used by `--selftest` to assert the
    /// hide/reveal state machine end-to-end, and available for future in-app
    /// diagnostics. Reads the *actual* `NSStatusItem.length` values, so it verifies
    /// the real bar state — not just the internal booleans.
    struct Diagnostics: Equatable {
        var revealHidden: Bool
        var revealAlwaysHidden: Bool
        var hiddenDividerLength: CGFloat
        var alwaysHiddenDividerLength: CGFloat?
        var alwaysHiddenSectionPresent: Bool
        var chevronRevealed: Bool
        var isArranging: Bool
        var hiddenMarkerShown: Bool
        var alwaysHiddenMarkerShown: Bool
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            revealHidden: revealHidden,
            revealAlwaysHidden: revealAlwaysHidden,
            hiddenDividerLength: hiddenDivider.statusItem.length,
            alwaysHiddenDividerLength: alwaysHiddenDivider?.statusItem.length,
            alwaysHiddenSectionPresent: alwaysHiddenDivider != nil,
            chevronRevealed: chevron.isRevealed,
            isArranging: arranger.isArranging,
            hiddenMarkerShown: hiddenDivider.isArranging,
            alwaysHiddenMarkerShown: alwaysHiddenDivider?.isArranging ?? false
        )
    }

    @objc private func menuOpenSettings() { onOpenSettings() }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

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
    private var overflowTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// How close the leftmost arrange marker may sit to the notch's right edge
    /// before we treat the bar as full. Set to one whole inter-icon gap (macOS's
    /// default `NSStatusItemSpacing` is 16 pt) so the warning fires while there's
    /// still a full icon-slot of clearance — we'd rather warn a touch early than
    /// let a zone slip behind the notch unannounced.
    private static let overflowSlack: CGFloat = 2

    init(settings: SettingsStore,
         arranger: MenuBarArranger,
         onOpenSettings: @escaping () -> Void) {
        self.settings = settings
        self.arranger = arranger
        self.onOpenSettings = onOpenSettings

        // Before creating any status items: (1) drop any off-screen-corrupt saved
        // positions so a polluted layout can't strand the chevron off-screen, (2)
        // migrate installs from an older seeded layout so a corrected default takes
        // hold once, then (3) seed a sane default layout (chevron rightmost next to the
        // clock; Always-Hidden divider far left so its zone starts empty) for any item
        // the user hasn't positioned themselves.
        let controlItemNames = ["flux.chevron", "flux.divider.hidden", "flux.divider.alwaysHidden"]
        ControlItem.sanitizePersistedPositions(autosaveNames: controlItemNames)
        ControlItem.migrateLayoutIfNeeded(autosaveNames: controlItemNames)
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
                // While arranging, re-apply the focus so a newly created (or removed)
                // Always-Hidden divider joins the arrange layout instead of the
                // normal collapsed geometry.
                if self.arranger.isArranging {
                    self.applyArrangeFocus()
                    self.refreshOverflow()
                } else {
                    self.applyState(animated: true)
                }
            }
            .store(in: &cancellables)

        // Incremental arranging: when the user changes which zones are revealed,
        // re-lay the markers and re-check whether it now fits beside the notch.
        arranger.$focus
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.arranger.isArranging else { return }
                self.applyArrangeFocus()
                self.refreshOverflow()
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

        // Track the notch highlight across normal reveals too: after the bar reflows
        // (macOS posts no notification), re-measure whether the revealed icons clip
        // behind the notch. Collapsing back here clears the glow.
        scheduleOverflowRefresh()
    }

    /// Re-measure overflow once the bar has settled after a reveal/collapse. Normal
    /// reveals are discrete events, so a single delayed check is enough — no need for
    /// the continuous poll the drag-heavy arrange flow uses.
    private func scheduleOverflowRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.arranger.isArranging else { return }
            self.refreshOverflow()
        }
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

            chevron.setArranging(true)
            applyArrangeFocus()
            startOverflowMonitor()
            Log.menuBar.info("Entered Arrange Mode")
        } else {
            stopOverflowMonitor()
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

    /// Reveal the zones — and show the compact markers — that the current arrange
    /// focus calls for. Each focus collapses the zone that isn't involved and shows
    /// a single marker for the edge being sorted, so the fewest icons compete for
    /// the scarce space to the right of the notch:
    ///
    /// - `.all` — reveal Shown │ Hidden │ Always-Hidden; both ◀ markers.
    /// - `.shownHidden` — reveal Shown │ Hidden; ◀Hidden marker; balloon the
    ///   Always-Hidden divider so that zone's icons are pushed off-screen.
    /// - `.hiddenAlwaysHidden` — reveal Shown │ Hidden │ Always-Hidden but show only
    ///   the ◀Always marker (the ◀Hidden divider drops to a 1pt spacer), reclaiming
    ///   the Hidden marker's width for the Always-Hidden edge.
    ///
    /// Each divider names the zone to its left, so the right-to-left order
    /// (Shown │ Hidden │ Always-Hidden) reads straight off the bar. Shown owns no
    /// divider — it's simply the area to the right of ◀ Hidden.
    private func applyArrangeFocus() {
        // With no Always-Hidden section there's only one edge to sort.
        let hasAlways = settings.showAlwaysHiddenSection && alwaysHiddenDivider != nil
        let focus: MenuBarArranger.Focus = hasAlways ? arranger.focus : .shownHidden

        switch focus {
        case .all:
            revealHidden = true
            revealAlwaysHidden = true
            hiddenDivider.setArrangingMarker(true, zone: .hidden)
            alwaysHiddenDivider?.setArrangingMarker(true, zone: .alwaysHidden)

        case .shownHidden:
            revealHidden = true
            revealAlwaysHidden = false
            hiddenDivider.setArrangingMarker(true, zone: .hidden)
            // Balloon the Always-Hidden divider so its icons are pushed off-screen,
            // freeing their width for the Shown ↔ Hidden edge.
            alwaysHiddenDivider?.setArrangingMarker(false)
            alwaysHiddenDivider?.setCollapsed(true, animated: true)

        case .hiddenAlwaysHidden:
            revealHidden = true
            revealAlwaysHidden = true
            // Drop the Hidden marker to a 1pt spacer — Hidden still shows, but its
            // marker's width is reclaimed for the Always-Hidden edge, which needs
            // every point (Shown + Hidden already sit to its right).
            hiddenDivider.setArrangingMarker(false)
            hiddenDivider.setCollapsed(false, animated: true)
            alwaysHiddenDivider?.setArrangingMarker(true, zone: .alwaysHidden)
        }

        // Reclaim the chevron's ~30pt whenever the Always-Hidden edge is on the bar
        // (.all / .hiddenAlwaysHidden). That edge is furthest from the clock and
        // first to fall behind the notch, so trimming right-side width pulls its
        // marker back into view. Shown ↔ Hidden already fits, so keep the chevron.
        chevron.setArrangeCollapsed(revealAlwaysHidden)
    }

    // MARK: Notch overflow

    /// While arranging, poll the live bar and publish whether Flux's revealed items
    /// still fit beside the notch. Menu-bar item frames shift as the user ⌘-drags
    /// icons and macOS posts no notification for it, so a light poll (only while
    /// arranging, a transient mode) keeps the warning honest.
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

    /// Whether the leftmost thing the user is currently trying to *see* could be
    /// clipped behind the notch: while arranging (a revealed edge marker), or during
    /// a normal reveal (revealed icons spill past it). When nothing is revealed the
    /// hidden zones sit behind the notch *by design*, so there's nothing to warn about.
    private var shouldMonitorOverflow: Bool { arranger.isArranging || isAnyRevealed }

    private func refreshOverflow() {
        guard shouldMonitorOverflow else {
            arranger.setOverflow(arrange: false, notch: false, iconCount: 0)
            return
        }
        let deficit = computeOverflowDeficit()
        let over = deficit > 0
        let count = iconsToClear(deficit)
        // The drawer's arrange coaching only makes sense while arranging; the notch
        // glow applies to both. So a normal-reveal overflow lights the notch without
        // surfacing the (focus-specific) drawer warning.
        arranger.setOverflow(arrange: arranger.isArranging && over, notch: over, iconCount: count)
    }

    /// How far (in points) the leftmost revealed marker sits *left* of where it would
    /// clear the notch — `0` when it already fits. Items fill the bar from the clock
    /// leftward, so the leftmost marker crosses into the notch exactly when the
    /// revealed zones run out of room beside it; the shortfall is how much width must
    /// move off this edge before it comes back into view.
    private func computeOverflowDeficit() -> CGFloat {
        guard let screen = menuBarScreen() else { return 0 }
        guard let frame = leftmostOverflowMarker()?.statusItem.button?.window?.frame else { return 0 }
        guard frame.width >= 1 else { return .greatestFiniteMagnitude }   // couldn't place — deeply overflowed
        return max(0, (screen.statusItemRegion.minX + Self.overflowSlack) - frame.minX)
    }

    /// Convert an overflow shortfall in points into an icon count for the cascade
    /// coaching. Each menu-bar icon occupies roughly one slot's width plus spacing;
    /// compact spacing tightens that, so fewer moves are needed per point. This is
    /// an estimate — it only needs to be in the right ballpark to say "about N".
    private func iconsToClear(_ deficit: CGFloat) -> Int {
        guard deficit > 0 else { return 0 }
        let perIcon: CGFloat = MenuBarSpacing.isCompact ? 28 : 38
        return max(1, Int((deficit / perIcon).rounded(.up)))
    }

    /// The leftmost marker Flux is showing under the current focus — the one that
    /// hits the notch first. `.shownHidden` shows only ◀Hidden; `.all` and
    /// `.hiddenAlwaysHidden` both show ◀Always as their leftmost marker.
    private func leftmostArrangeMarker() -> ControlItem {
        if settings.showAlwaysHiddenSection, arranger.focus != .shownHidden, let ah = alwaysHiddenDivider {
            return ah
        }
        return hiddenDivider
    }

    /// The leftmost item whose clipping means "the user can't see what they wanted".
    /// While arranging that's the focus's leftmost marker; during a normal reveal
    /// it's the leftmost *revealed* divider — the boundary the revealed icons sit
    /// left of, so if it's behind the notch those icons are clipped. Returns `nil`
    /// when nothing relevant is revealed (collapsed zones hide by design).
    private func leftmostOverflowMarker() -> ControlItem? {
        if arranger.isArranging { return leftmostArrangeMarker() }
        if revealAlwaysHidden, let ah = alwaysHiddenDivider { return ah }
        if revealHidden { return hiddenDivider }
        return nil
    }

    /// The screen whose menu bar currently hosts Flux's items — found from the
    /// chevron's own window so notch geometry is read from the right display.
    private func menuBarScreen() -> NSScreen? {
        if let window = chevron.statusItem.button?.window {
            let mid = NSPoint(x: window.frame.midX, y: window.frame.midY)
            return NSScreen.screens.first { $0.frame.contains(mid) } ?? window.screen ?? NSScreen.main
        }
        return NSScreen.main
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
        overflowTimer?.invalidate()
    }
}

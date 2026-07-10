import AppKit

/// A single status item owned by Flux. Two roles:
///
/// - `.chevron`  — the visible toggle the user clicks. Stays a fixed small width.
/// - `.divider`  — an invisible expandable spacer. When *collapsed* its width
///                 balloons, shoving every item to its left off the visible bar.
///
/// This is the whole trick: we never touch other apps' status items, we just
/// consume horizontal space next to them. No private APIs, no screen capture,
/// no Accessibility permission — which is exactly why it's stable and cheap.
@MainActor
final class ControlItem {
    enum Role {
        case chevron
        case divider
    }

    /// Width a collapsed divider expands to. Larger than any conceivable menu
    /// bar, so left-neighbours are pushed fully off-screen behind the app menus.
    private static let collapsedWidth: CGFloat = 10_000
    /// A revealed divider shrinks to a hairline so it doesn't waste bar space.
    private static let revealedWidth: CGFloat = 1

    /// A menu-bar `NSStatusItem`'s saved "Preferred Position" is a distance-from-the-
    /// right-edge in points, so any legitimate value is at most the screen width plus
    /// a little slack — up to ~6 000pt on a 6K display, and we deliberately seed the
    /// Always-Hidden divider near the widest screen's edge (see `farLeftPosition`). The
    /// expandable-divider trick pushes *polluted* values far higher: when macOS persists
    /// a position while a divider is at its 10 000pt collapsed width, the divider (and
    /// its neighbours — including the chevron) inherit an absurd position (~10 462pt →
    /// thousands of points off the left of the screen, so the user sees *nothing*). This
    /// ceiling sits above any real screen width but below the 10 000pt-based pollution,
    /// so legitimate far-left seeds survive while corrupt positions are caught.
    private static let maxPlausiblePosition: CGFloat = 8_000

    /// UserDefaults key macOS uses to persist a status item's Cmd-drag position.
    private static func positionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// Guard against the pollution described above. If *any* of Flux's control items
    /// has a persisted position beyond the plausible ceiling, clear *all* of them so
    /// they fall back to clean, on-screen, creation-order placement (chevron rightmost,
    /// dividers to its left) instead of restoring a corrupt, off-screen layout.
    ///
    /// Must run **before** the status items are created — macOS reads these keys at
    /// creation time. Returns `true` if it reset anything.
    @discardableResult
    static func sanitizePersistedPositions(autosaveNames: [String],
                                           defaults: UserDefaults = .standard) -> Bool {
        let keys = autosaveNames.map(positionKey)
        let polluted = keys.contains { key in
            guard let value = defaults.object(forKey: key) as? Double else { return false }
            return value > Double(maxPlausiblePosition) || value < 0
        }
        guard polluted else { return false }
        for key in keys { defaults.removeObject(forKey: key) }
        Log.menuBar.info("Reset polluted status-item positions → clean creation-order placement")
        return true
    }

    /// A distance-from-the-right-edge seed that lands an item at the far **left** of the
    /// bar, past every real icon. A saved position can never exceed a screen's width, so
    /// seeding the widest attached screen's width guarantees the item sits left of all
    /// the user's icons; macOS clamps it to the leftmost slot. Falls back to a generous
    /// constant for headless/test runs where no screen is attached.
    private static var farLeftPosition: Double {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 2_000
        return Double(widest)
    }

    /// Bump when the seeded default layout changes in a way existing installs must pick
    /// up — not just fresh ones. `migrateLayoutIfNeeded` compares this against a stored
    /// marker and, on an increase, clears the saved positions once so the corrected
    /// defaults take hold.
    ///
    /// - v1: original layout (both dividers seeded near the clock).
    /// - v2: Always-Hidden divider seeded far left so its zone starts **empty** and the
    ///       user's icons default into the chevron-toggled Hidden zone.
    private static let layoutVersion = 2
    private static let layoutVersionKey = "flux.layoutVersion"

    /// Seed a sensible default layout the first time (or after a reset). The three
    /// control items, **right → left**, are:
    ///
    ///   `[clock] [chevron] [Shown] [hiddenDivider] [Hidden] [alwaysHiddenDivider] […]`
    ///
    /// A saved position is a distance-from-the-right-edge in points, so a *lower* value
    /// sits further right. The chevron gets the lowest (rightmost, next to the clock).
    /// The Hidden divider sits just to its left, **right of every real icon**, so by
    /// default all the user's icons fall into the Hidden zone — revealed by a plain
    /// chevron click. The Always-Hidden divider is seeded **far left, past every icon**,
    /// so the Always-Hidden zone starts empty and is opt-in (drag an icon left of it).
    /// Seeding it near the clock instead (the old v1 bug) trapped *every* icon in
    /// Always-Hidden and left the Hidden zone empty, so the chevron revealed nothing.
    ///
    /// Only fills in items the user hasn't positioned themselves, so a manual Cmd-drag
    /// arrangement is always preserved. Run after `sanitizePersistedPositions` /
    /// `migrateLayoutIfNeeded` and before the items are created.
    static func assignDefaultPositionsIfUnset(defaults: UserDefaults = .standard) {
        let layout: [(name: String, position: Double)] = [
            ("flux.chevron", 0),                          // rightmost — next to the clock
            ("flux.divider.hidden", 8),                   // just left of the chevron, right of every icon
            ("flux.divider.alwaysHidden", farLeftPosition), // far left — Always-Hidden starts empty
        ]
        for item in layout where defaults.object(forKey: positionKey(item.name)) == nil {
            defaults.set(item.position, forKey: positionKey(item.name))
        }
    }

    /// One-time migration for installs that predate a `layoutVersion` bump. When the
    /// stored marker is behind the current version, clear the saved control-item
    /// positions so `assignDefaultPositionsIfUnset` re-seeds the corrected layout, then
    /// record the new version. Idempotent: it runs at most once per version bump and
    /// leaves a manually-arranged layout alone on every subsequent launch.
    ///
    /// Run **after** `sanitizePersistedPositions` and **before**
    /// `assignDefaultPositionsIfUnset`. Returns `true` if it migrated.
    @discardableResult
    static func migrateLayoutIfNeeded(autosaveNames: [String],
                                      defaults: UserDefaults = .standard) -> Bool {
        let stored = defaults.integer(forKey: layoutVersionKey)   // 0 when never set
        guard stored < layoutVersion else { return false }
        for name in autosaveNames { defaults.removeObject(forKey: positionKey(name)) }
        defaults.set(layoutVersion, forKey: layoutVersionKey)
        Log.menuBar.info("Migrated menu-bar layout v\(stored) → v\(layoutVersion); reset positions to re-seed corrected zones")
        return true
    }

    let role: Role
    let statusItem: NSStatusItem

    /// Called on left-click (chevron only).
    var onToggle: (() -> Void)?
    /// Called on right-click / control-click (chevron only) to show the menu.
    var onShowMenu: (() -> Void)?

    private var style: MenuBarIconStyle = .chevron
    /// Whether the chevron currently shows its "revealed" glyph. Read-only outside
    /// the class; used by `MenuBarManager.diagnostics` and the self-test.
    private(set) var isRevealed = false
    /// Chevron: whether it's showing the Arrange-Mode "Done" glyph.
    /// Divider: whether it's showing its labeled arrange marker.
    /// Read-only outside the class; used by diagnostics and the self-test.
    private(set) var isArranging = false

    init(role: Role, autosaveName: String) {
        self.role = role
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the user's Cmd-drag position across launches so the zones stay
        // where they put them.
        item.autosaveName = autosaveName
        // Control items must NOT be removable. The dividers are invisible, so a
        // stray Cmd-drag-off would silently delete one and permanently break
        // hide/reveal with no way for the user to find or restore it. An empty
        // behavior still lets Cmd-drag *reposition* the items — it just can't
        // delete them.
        item.behavior = []
        // Self-heal: force visible in case an older build (which allowed removal)
        // persisted isVisible=false under this autosaveName.
        item.isVisible = true
        self.statusItem = item

        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        switch role {
        case .chevron:
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Flux — click to reveal hidden menu bar items"
            redrawChevron()
        case .divider:
            // Invisible: no image, empty title. It only exists to take up space.
            button.image = nil
            button.title = ""
        }
    }

    // MARK: Divider geometry

    /// Collapse (hide left-neighbours) or reveal them. `NSStatusItem.length` is
    /// set directly: it isn't reliably animatable, and an instant change is both
    /// snappier and more robust than fighting the animator proxy.
    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard role == .divider else { return }
        let target = collapsed ? ControlItem.collapsedWidth : ControlItem.revealedWidth
        guard abs(statusItem.length - target) > 0.5 else { return }
        statusItem.length = target
    }

    // MARK: Chevron state

    func setChevron(revealed: Bool) {
        guard role == .chevron else { return }
        isRevealed = revealed
        redrawChevron()
    }

    // MARK: Arrange Mode

    /// Chevron only. In Arrange Mode the chevron becomes a **Done** button: it
    /// shows a checkmark glyph and a left-click ends arranging (wired by the
    /// manager) instead of toggling reveal.
    func setArranging(_ on: Bool) {
        guard role == .chevron else { return }
        isArranging = on
        statusItem.button?.toolTip = on
            ? "Flux — drag icons across the markers, then click to finish"
            : "Flux — click to reveal hidden menu bar items"
        redrawChevron()
    }

    /// Divider only. In Arrange Mode a divider stops being invisible and shows a
    /// labeled marker naming the **zone that lies to its left** — the zone an icon
    /// joins when you ⌘-drag it past the marker (leftward). Each marker is a solid
    /// pill in its zone's colour, so the right-to-left order reads straight off the
    /// bar: `[✓] Shown  ◀Hidden  Hidden  ◀Always Hidden  Always-Hidden`. Passing
    /// `on: false` restores the invisible state.
    func setArrangingMarker(_ on: Bool, zone: MenuBarSection? = nil) {
        guard role == .divider, let button = statusItem.button else { return }
        isArranging = on
        if on, let zone {
            // A bold, single-colour tag (drawn, not a template symbol) so it reads
            // as a Flux zone edge — not just another monochrome menu-bar icon — with
            // a left arrow spelling out which way to drag an icon to join the zone.
            button.image = ControlItem.markerImage(zone: zone)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Hold ⌘ and drag an icon to the left of here to move it into \(zone.displayName)."
            // Auto-fit to the tag so the marker is fully visible while arranging.
            statusItem.length = NSStatusItem.variableLength
        } else {
            button.image = nil
            button.title = ""
            button.toolTip = nil
        }
    }

    /// Draws a solid rounded tag in the zone's colour with a left arrow and the
    /// zone's short tag (`◀ Always`) — "everything to the left of here is <zone>".
    /// Deliberately compact: on notched Macs the width this marker occupies is
    /// width the user's real icons can't use, so a slimmer tag keeps more zones
    /// on-screen. The full zone name lives in the tooltip and the hint legend.
    /// Non-template so the colour survives.
    private static func markerImage(zone: MenuBarSection) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = zone.markerLabel as NSString
        let textSize = text.size(withAttributes: attrs)

        let height: CGFloat = 15
        let hPad: CGFloat = 5
        let arrowW: CGFloat = 4.5
        let gap: CGFloat = 3
        let width = ceil(hPad + arrowW + gap + textSize.width + hPad)
        let midY = height / 2

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                     xRadius: 4, yRadius: 4).addClip()
        Theme.zone(zone).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // A left-pointing arrow: "drag this way to move an icon into the zone".
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: hPad + arrowW, y: midY + 3.5))
        arrow.line(to: NSPoint(x: hPad, y: midY))
        arrow.line(to: NSPoint(x: hPad + arrowW, y: midY - 3.5))
        arrow.lineWidth = 1.6
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()

        text.draw(at: NSPoint(x: hPad + arrowW + gap, y: (height - textSize.height) / 2 - 0.5),
                  withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func setStyle(_ newStyle: MenuBarIconStyle) {
        guard role == .chevron else { return }
        style = newStyle
        redrawChevron()
    }

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            onShowMenu?()
        } else {
            onToggle?()
        }
    }

    // MARK: Icon

    private func redrawChevron() {
        guard let button = statusItem.button else { return }
        // In Arrange Mode the chevron is a "Done" button, regardless of style.
        if isArranging {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            let image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                accessibilityDescription: "Done arranging")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            return
        }
        let symbol = isRevealed ? style.revealedSymbol : style.collapsedSymbol
        let pointSize: CGFloat = style == .dot ? 7 : 12
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flux")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
    }

    func removeFromStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

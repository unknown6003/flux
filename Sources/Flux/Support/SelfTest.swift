import AppKit
import Carbon.HIToolbox
import SwiftUI
import Foundation

/// A minimal `NotchWidget` stub used only by the notch section of this test —
/// counts `willPresent`/`didDismiss` calls so the state machine's "exactly
/// once per visibility change" contract can be asserted directly, without a
/// real widget's own side effects (services, timers) in the way.
@MainActor
private final class SelfTestWidget: NotchWidget {
    let id: WidgetID
    var isEnabled: Bool = true
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    init(id: WidgetID) { self.id = id }

    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
    func makeCompactView() -> AnyView? { nil }
    func willPresent() { presentCount += 1 }
    func didDismiss() { dismissCount += 1 }
}

/// Headless functional test of the menu-bar engine. Creates real status items in
/// the system menu bar and asserts the collapse/reveal geometry that does the
/// actual hiding. Run with: `Flux --selftest`.
@MainActor
enum SelfTest {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var allPassed = true
        func check(_ condition: Bool, _ message: String) {
            let mark = condition ? "✓ PASS" : "✗ FAIL"
            print("\(mark)  \(message)")
            allPassed = allPassed && condition
        }

        // --- ControlItem: the unit that performs hiding ---
        let chevron = ControlItem(role: .chevron, autosaveName: "flux.selftest.chevron")
        let divider = ControlItem(role: .divider, autosaveName: "flux.selftest.divider")

        check(chevron.statusItem.button?.image != nil,
              "Chevron control item shows an icon")

        divider.setCollapsed(true, animated: false)
        let collapsed = divider.statusItem.length
        check(collapsed > 5_000,
              "Collapsing expands the divider to \(Int(collapsed))pt → pushes neighbours off-screen")

        divider.setCollapsed(false, animated: false)
        let revealed = divider.statusItem.length
        check(revealed < 5,
              "Revealing shrinks the divider to \(revealed)pt → neighbours return")

        chevron.setStyle(.dot)
        check(chevron.statusItem.button?.image != nil,
              "Chevron icon updates when the style changes")
        chevron.setChevron(revealed: true)
        check(chevron.statusItem.button?.image != nil,
              "Chevron icon updates when reveal state changes")

        chevron.removeFromStatusBar()
        divider.removeFromStatusBar()

        // --- Default layout: Always-Hidden starts empty so the chevron reveals icons ---
        // The v1 bug seeded the Always-Hidden divider near the clock (position 16), so
        // every real icon — which sits further left — fell into Always-Hidden, leaving
        // the Hidden zone empty and the chevron revealing nothing. The corrected layout
        // seeds it far left. Verify on a throwaway suite so real defaults stay clean.
        let layoutSuiteName = "flux.selftest.layout"
        let layoutSuite = UserDefaults(suiteName: layoutSuiteName)!
        layoutSuite.removePersistentDomain(forName: layoutSuiteName)
        let names = ["flux.chevron", "flux.divider.hidden", "flux.divider.alwaysHidden"]
        func posKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

        // A stale/broken position is cleared once on a layout-version bump.
        layoutSuite.set(16.0, forKey: posKey("flux.divider.alwaysHidden"))
        check(ControlItem.migrateLayoutIfNeeded(autosaveNames: names, defaults: layoutSuite),
              "Layout migration fires when the stored version is behind")
        check(layoutSuite.object(forKey: posKey("flux.divider.alwaysHidden")) == nil,
              "Layout migration clears the stale Always-Hidden position")
        // Idempotent: a second run at the same version leaves positions alone.
        layoutSuite.set(42.0, forKey: posKey("flux.divider.alwaysHidden"))
        check(!ControlItem.migrateLayoutIfNeeded(autosaveNames: names, defaults: layoutSuite),
              "Layout migration runs at most once per version bump")
        check(layoutSuite.double(forKey: posKey("flux.divider.alwaysHidden")) == 42.0,
              "Layout migration doesn't touch positions after it has run")

        // Seeding puts the three control items in bar order (right → left: chevron,
        // Hidden divider, Always-Hidden divider) as one adjacent cluster, and puts the
        // whole cluster LEFT of every real icon — a saved position is a distance from
        // the right edge, so "left of every icon" means "beyond the widest screen's
        // width", which no real icon's position can reach.
        layoutSuite.removeObject(forKey: posKey("flux.divider.alwaysHidden"))
        ControlItem.assignDefaultPositionsIfUnset(defaults: layoutSuite)
        let posChevron = layoutSuite.double(forKey: posKey("flux.chevron"))
        let posHidden = layoutSuite.double(forKey: posKey("flux.divider.hidden"))
        let posAlways = layoutSuite.double(forKey: posKey("flux.divider.alwaysHidden"))
        check(posChevron < posHidden && posHidden < posAlways,
              "Layout: bar order right→left is chevron (\(Int(posChevron))) · Hidden (\(Int(posHidden))) · Always-Hidden (\(Int(posAlways)))")
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 2_000
        check(posChevron >= widest,
              "Layout: the cluster seeds left of every real icon (chevron \(Int(posChevron)) ≥ widest screen \(Int(widest))) → everything starts Shown")
        check(posAlways - posChevron < 100,
              "Layout: the three control items seed adjacent (\(Int(posAlways - posChevron))pt apart), so every marker stays reachable")
        layoutSuite.removePersistentDomain(forName: layoutSuiteName)

        // --- MenuBarManager: full state machine, asserting REAL bar geometry ---
        // Clean slate so defaults are deterministic (showAlwaysHiddenSection=true).
        let suiteName = "flux.selftest"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let arranger = MenuBarArranger()
        let manager = MenuBarManager(settings: settings, arranger: arranger, onOpenSettings: {})

        func isHidden(_ length: CGFloat?) -> Bool { (length ?? 0) > 5_000 }
        func isRevealed(_ length: CGFloat?) -> Bool { (length ?? 99) < 5 }

        // Launch state: always collapsed — whatever the user assigned to a hidden zone
        // stays tucked away. (On a fresh install both zones are empty, so this hides
        // nothing.) Chevron shows ‹.
        let s0 = manager.diagnostics
        check(!s0.revealHidden && !s0.revealAlwaysHidden,
              "Launches collapsed, honouring the saved arrangement")
        check(isHidden(s0.hiddenDividerLength),
              "Hidden zone starts hidden (divider \(Int(s0.hiddenDividerLength))pt)")
        check(s0.alwaysHiddenSectionPresent,
              "Always-Hidden section is present by default")
        check(isHidden(s0.alwaysHiddenDividerLength),
              "Always-Hidden zone starts hidden")
        check(!s0.chevronRevealed, "Chevron shows the collapsed glyph at launch")

        // Reveal the Hidden zone (chevron click / hotkey).
        manager.toggleReveal()
        let s1 = manager.diagnostics
        check(s1.revealHidden && !s1.revealAlwaysHidden, "Toggle reveals the Hidden zone only")
        check(isRevealed(s1.hiddenDividerLength),
              "Revealing Hidden shrinks its divider to \(s1.hiddenDividerLength)pt")
        check(isHidden(s1.alwaysHiddenDividerLength),
              "Always-Hidden stays hidden on a plain reveal")
        check(s1.chevronRevealed, "Chevron flips to the revealed glyph")

        // Reveal absolutely everything (option-click / menu).
        manager.revealAll()
        let s2 = manager.diagnostics
        check(s2.revealHidden && s2.revealAlwaysHidden, "revealAll shows both zones")
        check(isRevealed(s2.hiddenDividerLength) && isRevealed(s2.alwaysHiddenDividerLength),
              "Both dividers shrink when everything is revealed")

        // Collapse back to the resting state.
        manager.collapse(animated: false)
        let s3 = manager.diagnostics
        check(!s3.revealHidden && !s3.revealAlwaysHidden, "Collapse hides every zone again")
        check(isHidden(s3.hiddenDividerLength) && isHidden(s3.alwaysHiddenDividerLength),
              "Both dividers re-expand on collapse")

        // --- Arrange Mode: labeled markers + everything shown, then apply ---
        // (Runs while the Always-Hidden section is still on, before we disable it.)
        arranger.setArranging(true)
        let a0 = manager.diagnostics
        check(a0.isArranging, "Entering Arrange Mode flips the arranging flag")
        check(a0.hiddenMarkerShown,
              "Arrange Mode shows the Hidden divider's labeled marker")
        check(a0.alwaysHiddenMarkerShown,
              "Arrange Mode shows the Always-Hidden divider's labeled marker")
        check(!isHidden(a0.hiddenDividerLength),
              "Arrange Mode reveals icons — the Hidden divider isn't at its 10 000pt collapse")

        // Incremental arranging: tucking Always-Hidden away (for users with more
        // icons than fit beside the notch) hides its marker and collapses its zone
        // off-screen, while the Hidden marker stays put.
        arranger.focus = .shownHidden
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)) // let the focus sink fire
        let af = manager.diagnostics
        check(af.hiddenMarkerShown,
              "Shown & Hidden focus keeps the Hidden marker")
        check(!af.alwaysHiddenMarkerShown,
              "Shown & Hidden focus hides the Always-Hidden marker")
        check(isHidden(af.alwaysHiddenDividerLength),
              "Shown & Hidden focus collapses the Always-Hidden zone off-screen")

        arranger.focus = .all
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let ab = manager.diagnostics
        check(ab.alwaysHiddenMarkerShown,
              "Switching back to All zones restores the Always-Hidden marker")

        // Hidden ↔ Always-Hidden focus: shows ONLY the Always-Hidden marker (the
        // Hidden marker drops to a 1pt spacer) so the Always edge — which has
        // Shown + Hidden to its right — gets every point of room beside the notch.
        arranger.focus = .hiddenAlwaysHidden
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let ah = manager.diagnostics
        check(ah.alwaysHiddenMarkerShown,
              "Hidden ↔ Always focus keeps the Always-Hidden marker")
        check(!ah.hiddenMarkerShown,
              "Hidden ↔ Always focus drops the Hidden marker to reclaim its width")
        check(!isHidden(ah.hiddenDividerLength),
              "Hidden ↔ Always focus still reveals the Hidden zone (divider not collapsed)")
        check(!isHidden(ah.alwaysHiddenDividerLength),
              "Hidden ↔ Always focus reveals the Always-Hidden zone")

        arranger.setArranging(false)
        let a1 = manager.diagnostics
        check(!a1.isArranging, "Leaving Arrange Mode clears the arranging flag")
        check(!a1.hiddenMarkerShown && !a1.alwaysHiddenMarkerShown,
              "Leaving Arrange Mode hides both markers")
        check(isHidden(a1.hiddenDividerLength) && isHidden(a1.alwaysHiddenDividerLength),
              "Leaving Arrange Mode applies the arrangement (collapses back to resting)")

        // Turning the Always-Hidden section off removes its divider entirely.
        settings.showAlwaysHiddenSection = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)) // let the Combine sink fire
        let s4 = manager.diagnostics
        check(!s4.alwaysHiddenSectionPresent,
              "Disabling the Always-Hidden section removes its divider")

        // --- Notch geometry: statusItemFitsBesideNotch drives overflow detection ---
        // A marker "fits" only when it sits clear of the notch (its left edge stays
        // right of the usable region's left edge). This is the exact predicate the
        // overflow monitor uses, so pin its behaviour deterministically.
        if let screen = NSScreen.main {
            let region = screen.statusItemRegion
            func marker(atMinX x: CGFloat, width: CGFloat = 60) -> NSRect {
                NSRect(x: x, y: region.minY, width: width, height: region.height)
            }
            check(screen.statusItemFitsBesideNotch(marker(atMinX: region.minX + 50)),
                  "Fit: a marker well right of the region edge fits")
            check(!screen.statusItemFitsBesideNotch(marker(atMinX: region.minX - 10)),
                  "Fit: a marker pushed left of the region edge (toward the notch) doesn't fit")
            check(!screen.statusItemFitsBesideNotch(marker(atMinX: region.minX)),
                  "Fit: a marker with no clearance from the region edge doesn't fit")
            check(screen.statusItemFitsBesideNotch(marker(atMinX: region.minX + 2)),
                  "Fit: a marker exactly at the edge + slack fits")
            check(!screen.statusItemFitsBesideNotch(
                    NSRect(x: region.minX + 50, y: region.minY, width: 0, height: region.height)),
                  "Fit: a zero-width frame (macOS couldn't place it) never fits")
        }

        // --- Reset: the escape hatch out of a layout you can't drag your way out of ---
        let resetSuiteName = "flux.selftest.reset"
        let resetSuite = UserDefaults(suiteName: resetSuiteName)!
        resetSuite.removePersistentDomain(forName: resetSuiteName)
        ControlItem.migrateLayoutIfNeeded(autosaveNames: ControlItem.allAutosaveNames,
                                          defaults: resetSuite)
        ControlItem.assignDefaultPositionsIfUnset(defaults: resetSuite)
        // Simulate a layout the user has dragged into a corner they can't recover from.
        resetSuite.set(9_999.0, forKey: posKey("flux.chevron"))
        ControlItem.resetLayout(defaults: resetSuite)
        check(ControlItem.allAutosaveNames.allSatisfy { resetSuite.object(forKey: posKey($0)) == nil },
              "Reset: clears every saved control-item position")
        check(resetSuite.integer(forKey: "flux.layoutVersion") == 0,
              "Reset: clears the layout marker so the next launch re-seeds")
        // ...and the next launch really does re-seed a clean, everything-Shown layout.
        ControlItem.migrateLayoutIfNeeded(autosaveNames: ControlItem.allAutosaveNames,
                                          defaults: resetSuite)
        ControlItem.assignDefaultPositionsIfUnset(defaults: resetSuite)
        let reseeded = resetSuite.double(forKey: posKey("flux.chevron"))
        check(reseeded > 0 && reseeded < 8_000,
              "Reset: the next launch re-seeds a sane chevron position (\(Int(reseeded)))")
        resetSuite.removePersistentDomain(forName: resetSuiteName)

        // --- Hotkey: the recorded shortcut round-trips and the default is a real chord ---
        check(HotkeyShortcut.default.isValid,
              "Hotkey: the default \(HotkeyShortcut.default.displayString) is registrable (has modifiers)")
        check(HotkeyShortcut.default.displayString == "⌃⌥⌘F",
              "Hotkey: the default renders as ⌃⌥⌘F, got \(HotkeyShortcut.default.displayString)")
        check(!HotkeyShortcut(keyCode: 0, carbonModifiers: 0).isValid,
              "Hotkey: a modifier-less chord is rejected (it would swallow the key system-wide)")

        // A recorded shortcut must survive a round-trip through UserDefaults, or the
        // user's binding silently reverts on the next launch.
        let hkSuiteName = "flux.selftest.hotkey"
        UserDefaults.standard.removePersistentDomain(forName: hkSuiteName)
        let hkDefaults = UserDefaults(suiteName: hkSuiteName)!
        let hkStore = SettingsStore(defaults: hkDefaults)
        check(hkStore.hotkeyShortcut == .default,
              "Hotkey: a fresh install starts on the default chord")
        let custom = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_J),
                                    carbonModifiers: UInt32(cmdKey | shiftKey))
        hkStore.hotkeyShortcut = custom
        let reloaded = SettingsStore(defaults: hkDefaults)
        check(reloaded.hotkeyShortcut == custom,
              "Hotkey: a recorded chord (\(custom.displayString)) persists across launches")
        UserDefaults.standard.removePersistentDomain(forName: hkSuiteName)

        // --- The arrange warning is arrange-only; the notch glow is not ---
        let ov = MenuBarArranger()
        ov.setOverflow(arrange: true, notch: true, iconCount: 3)
        check(!ov.overflowsNotch,
              "Overflow: an arrange warning measured outside Arrange Mode is refused, so it can't flash on a plain chevron toggle")
        check(ov.notchOverflow,
              "Overflow: the notch glow still fires outside Arrange Mode — a normal reveal can clip icons too")
        ov.setArranging(true)
        ov.setOverflow(arrange: true, notch: true, iconCount: 3)
        check(ov.overflowsNotch && ov.overflowIconCount == 3,
              "Overflow: while arranging, a real overflow latches with its icon count")
        ov.setArranging(false)
        check(!ov.overflowsNotch, "Overflow: leaving Arrange Mode clears the arrange warning")

        // The cascade estimate stays sane: a stale ballooned divider frame or the
        // "couldn't place" sentinel must never surface as a triple-digit notch badge.
        check(MenuBarManager.iconsToClear(0, compact: false) == 0,
              "Overflow: no deficit → no icons to clear")
        check(MenuBarManager.iconsToClear(76, compact: false) == 2,
              "Overflow: a 76pt deficit reads as ~2 icons at default spacing")
        check(MenuBarManager.iconsToClear(.greatestFiniteMagnitude, compact: true) == 99,
              "Overflow: an unbounded deficit clamps to 99 instead of trapping or flashing an absurd count")

        // --- OTA updater: semantic version comparison ---
        let updater = UpdateChecker(currentVersion: "0.1.1")
        check(updater.isNewer("0.2.0", than: "0.1.1"), "Update: 0.2.0 is newer than 0.1.1")
        check(updater.isNewer("0.2", than: "0.1.9"), "Update: 0.2 outranks 0.1.9 (zero-padded)")
        check(updater.isNewer("1.0.0", than: "0.9.9"), "Update: a major bump is newer")
        check(!updater.isNewer("0.1.1", than: "0.1.1"), "Update: an identical version is not newer")
        check(!updater.isNewer("0.1.0", than: "0.1.1"), "Update: an older version is not newer")
        check(!updater.isNewer("0.1.1", than: "0.2.0"), "Update: the running build isn't behind a lower tag")
        check(UpdateChecker.normalize("v0.1.1") == "0.1.1", "Update: a 'v' prefix is stripped from tags")

        // --- Notch: NotchWidgetRegistry ordering, enable filtering, wrap-around ---
        let registry = NotchWidgetRegistry()
        let rWidgetA = SelfTestWidget(id: .nowPlaying)
        let rWidgetB = SelfTestWidget(id: .shelf)
        let rWidgetC = SelfTestWidget(id: .calendar)
        registry.register(rWidgetA)
        registry.register(rWidgetB)
        registry.register(rWidgetC)
        registry.register(rWidgetA) // duplicate registration must be a no-op
        check(registry.widgets.count == 3,
              "Registry: a duplicate registration of an already-registered id is ignored")

        registry.order = [.calendar, .nowPlaying, .shelf]
        check(registry.enabledWidgets.map(\.id) == [.calendar, .nowPlaying, .shelf],
              "Registry: enabledWidgets follows the persisted order")

        rWidgetB.isEnabled = false
        check(registry.enabledWidgets.map(\.id) == [.calendar, .nowPlaying],
              "Registry: a disabled widget is filtered out of enabledWidgets")

        check(registry.next(after: .calendar) == .nowPlaying, "Registry: next() walks forward in order")
        check(registry.next(after: .nowPlaying) == .calendar,
              "Registry: next() wraps around past the last enabled widget")
        check(registry.previous(before: .calendar) == .nowPlaying,
              "Registry: previous() wraps around before the first enabled widget")

        rWidgetB.isEnabled = true
        registry.order = [.nowPlaying] // shelf/calendar now unordered
        check(registry.enabledWidgets.map(\.id) == [.nowPlaying, .shelf, .calendar],
              "Registry: an unordered-but-registered widget still appears, appended in registration order")

        let emptyRegistry = NotchWidgetRegistry()
        check(emptyRegistry.next(after: .nowPlaying) == nil,
              "Registry: next() is nil when nothing is registered/enabled")

        // --- Notch: LiveActivityCenter priority queue + expiry-free dismiss ---
        let center = LiveActivityCenter()
        let low = LiveActivity(kind: .bluetoothDevice, leading: .none, trailing: .none, duration: nil, priority: 100)
        let high = LiveActivity(kind: .hudVolume, leading: .none, trailing: .none, duration: nil, priority: 300)
        center.post(low)
        check(center.current?.id == low.id, "LiveActivity: the only queued activity becomes current")
        center.post(high)
        check(center.current?.id == high.id,
              "LiveActivity: a higher-priority activity posted later preempts the current one")
        center.dismiss(id: high.id)
        check(center.current?.id == low.id,
              "LiveActivity: dismissing the current activity restores the next-highest queued one")
        center.dismiss(id: low.id)
        check(center.current == nil, "LiveActivity: dismissing the last activity leaves nothing current")

        let batteryA = LiveActivity(kind: .battery, leading: .text("80%"), trailing: .none, duration: nil, priority: 200)
        let batteryB = LiveActivity(kind: .battery, leading: .text("79%"), trailing: .none, duration: nil, priority: 200)
        center.post(batteryA)
        center.post(batteryB)
        check(center.current?.id == batteryB.id,
              "LiveActivity: posting the same kind again replaces the stale one instead of stacking")
        center.dismiss(id: batteryB.id)

        // --- Notch: NotchViewModel transition table ---
        let notchRegistry = NotchWidgetRegistry()
        let widgetA = SelfTestWidget(id: .nowPlaying)
        let widgetB = SelfTestWidget(id: .shelf)
        notchRegistry.register(widgetA)
        notchRegistry.register(widgetB)
        notchRegistry.order = [.nowPlaying, .shelf]

        let activities = LiveActivityCenter()
        let notchVM = NotchViewModel(registry: notchRegistry, activities: activities, expansionTrigger: .hover)
        check(notchVM.state == .collapsed, "Notch: starts collapsed")

        // Hover-open only fires in hover mode, after the configured delay.
        notchVM.hoverChanged(inside: true)
        RunLoop.current.run(until: Date().addingTimeInterval(notchVM.hoverOpenDelay + 0.15))
        check(notchVM.state == .expanded(.nowPlaying),
              "Notch: hovering in hover mode opens to the first enabled widget after the open delay")
        check(widgetA.presentCount == 1 && widgetA.dismissCount == 0,
              "Notch: willPresent fires exactly once for the widget that opened")

        notchVM.hoverChanged(inside: false)
        RunLoop.current.run(until: Date().addingTimeInterval(notchVM.hoverCloseDelay + 0.15))
        check(notchVM.state == .collapsed, "Notch: hovering out collapses after the close delay")
        check(widgetA.dismissCount == 1, "Notch: didDismiss fires exactly once when the widget collapses")

        // Click mode: hover has no effect at all.
        notchVM.expansionTrigger = .click
        notchVM.hoverChanged(inside: true)
        RunLoop.current.run(until: Date().addingTimeInterval(notchVM.hoverOpenDelay + 0.15))
        check(notchVM.state == .collapsed, "Notch: hovering in click mode never opens the panel")
        notchVM.hoverChanged(inside: false)

        // Click toggles open/closed regardless of trigger mode.
        notchVM.clicked()
        check(notchVM.state == .expanded(.nowPlaying), "Notch: a click opens the panel")
        check(widgetA.presentCount == 2, "Notch: willPresent fires again on the second open")
        notchVM.clicked()
        check(notchVM.state == .collapsed, "Notch: a second click collapses it")
        check(widgetA.dismissCount == 2, "Notch: didDismiss fires again on collapse")

        // Swipe cycling.
        notchVM.expand(nil)
        check(notchVM.state == .expanded(.nowPlaying), "Notch: expand(nil) opens the first enabled widget")
        notchVM.swiped(.left)
        check(notchVM.state == .expanded(.shelf), "Notch: swipe left cycles forward")
        check(widgetA.dismissCount == 3 && widgetB.presentCount == 1,
              "Notch: cycling widget→widget dismisses the old one and presents the new one exactly once")
        notchVM.swiped(.left)
        check(notchVM.state == .expanded(.nowPlaying), "Notch: swipe left wraps around back to the first widget")
        notchVM.swiped(.right)
        check(notchVM.state == .expanded(.shelf), "Notch: swipe right cycles backward (wraps)")
        notchVM.swiped(.up)
        check(notchVM.state == .collapsed, "Notch: swipe up collapses from any state")
        // widgetB (shelf) has been the showing widget twice now (swipe-right landed
        // back on it just before this collapse) — swiped(.up)'s dismiss is its 2nd.
        check(widgetB.dismissCount == 2, "Notch: collapsing from a swipe still dismisses the showing widget exactly once per visibility change")
        notchVM.swiped(.down)
        // lastUsedWidget was last set entering .expanded(shelf) (the swipe-right just
        // before collapsing), and collapsing never changes it — so reopening from
        // collapsed resolves back to shelf, not nowPlaying.
        check(notchVM.state == .expanded(.shelf), "Notch: swipe down from collapsed opens the last-used widget")

        // Live-activity preemption + return-to-collapsed.
        notchVM.collapse()
        check(notchVM.state == .collapsed, "Notch: collapse() returns to collapsed with no activity queued")
        let liveActivity = LiveActivity(kind: .battery, leading: .icon(systemName: "battery.100"),
                                        trailing: .none, duration: nil, priority: 200)
        activities.post(liveActivity)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(notchVM.state == .activity(liveActivity.id), "Notch: a live activity preempts the collapsed state")
        activities.dismiss(id: liveActivity.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(notchVM.state == .collapsed, "Notch: dismissing the only activity returns to collapsed")

        // An activity never disturbs an already-expanded widget.
        notchVM.expand(.shelf)
        let widgetBPresentsBefore = widgetB.presentCount
        activities.post(liveActivity)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(notchVM.state == .expanded(.shelf), "Notch: a live activity doesn't preempt an expanded widget")
        check(widgetB.presentCount == widgetBPresentsBefore,
              "Notch: willPresent doesn't refire for a widget that stayed expanded through an activity post")
        activities.dismiss(id: liveActivity.id)
        notchVM.collapse()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(notchVM.state == .collapsed, "Notch: cleanup — back to collapsed")

        // --- Notch: builtInNotchedScreen is nil-safe whether or not a notch exists ---
        if let builtIn = NSScreen.builtInNotchedScreen {
            check(builtIn.hasNotch, "Notch: builtInNotchedScreen (when non-nil) really is notched")
        } else {
            check(NSScreen.screens.allSatisfy { !$0.hasNotch || $0.displayID.map { CGDisplayIsBuiltin($0) == 0 } ?? true },
                  "Notch: builtInNotchedScreen is correctly nil when no screen is both notched and built-in")
        }

        // --- NowPlayingState: decode from checked-in adapter JSON fixtures ---
        func fixturePayloadDict(_ json: String) -> [String: Any] {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { return [:] }
            return payload
        }
        func decodedState(_ dict: [String: Any]) -> NowPlayingState? {
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let payload = try? JSONDecoder().decode(MediaRemoteAdapterPayload.self, from: data)
            else { return nil }
            return NowPlayingState(payload: payload)
        }
        // Mirrors MediaRemoteAdapterSource.applyPayload's dictionary-level merge:
        // an explicit `null` in a diff line *removes* the key (cleared), while a
        // key simply absent from the diff is left untouched (unchanged) — a
        // distinction Codable-only decoding of one line in isolation can't make.
        func applyDiff(_ payload: [String: Any], into merged: inout [String: Any]) {
            for (key, value) in payload {
                if value is NSNull {
                    merged.removeValue(forKey: key)
                } else {
                    merged[key] = value
                }
            }
        }

        let fullDict = fixturePayloadDict(NowPlayingFixtures.streamFullSnapshotJSON)
        if let fullState = decodedState(fullDict) {
            check(fullState.title == "Sunday Morning", "NowPlaying: full snapshot decodes the title")
            check(fullState.artist == "The Velvet Underground", "NowPlaying: full snapshot decodes the artist")
            check(fullState.isPlaying, "NowPlaying: full snapshot decodes isPlaying")
            check(fullState.elapsed == 42.25, "NowPlaying: full snapshot decodes elapsed")
            check((fullState.artworkData?.isEmpty ?? true) == false,
                  "NowPlaying: full snapshot's base64 artwork decodes to real bytes")
        } else {
            check(false, "NowPlaying: full snapshot fixture failed to decode")
        }

        var merged = fullDict
        merged.removeValue(forKey: "artworkData") // full-snapshot handling strips artwork from the merge dict
        applyDiff(fixturePayloadDict(NowPlayingFixtures.streamDiffTickJSON), into: &merged)
        if let tickState = decodedState(merged) {
            check(tickState.title == "Sunday Morning", "NowPlaying: a diff tick preserves the title unchanged")
            check(tickState.elapsed == 43.25, "NowPlaying: a diff tick updates elapsed")
        } else {
            check(false, "NowPlaying: diff-tick merge failed to decode")
        }

        applyDiff(fixturePayloadDict(NowPlayingFixtures.streamDiffPauseJSON), into: &merged)
        if let pausedState = decodedState(merged) {
            check(!pausedState.isPlaying, "NowPlaying: a diff pause flips isPlaying without touching other fields")
            check(pausedState.title == "Sunday Morning", "NowPlaying: a diff pause preserves the title through the pause diff")
        } else {
            check(false, "NowPlaying: diff-pause merge failed to decode")
        }

        merged["artworkMimeType"] = "image/png" // pretend it survived from the full snapshot
        applyDiff(fixturePayloadDict(NowPlayingFixtures.streamDiffClearArtworkJSON), into: &merged)
        check(merged["artworkMimeType"] == nil,
              "NowPlaying: a diff's explicit null clears a key instead of leaving it (or merely 'absent')")

        let idleState = decodedState(fixturePayloadDict(NowPlayingFixtures.streamIdleJSON))
        check(idleState == nil, "NowPlaying: an idle empty payload (no title) yields no displayable state")

        print(allPassed ? "\n🎉 ALL CHECKS PASSED" : "\n❌ SOME CHECKS FAILED")
        exit(allPassed ? 0 : 1)
    }
}

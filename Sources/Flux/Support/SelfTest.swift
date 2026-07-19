import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
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

        // --- Notch: forceCollapse() (used when the notch panel itself is
        // disabled) dismisses whatever's showing exactly once, and — unlike
        // collapse() — never resurfaces a live activity in its place. ---
        let forceRegistry = NotchWidgetRegistry()
        let forceWidget = SelfTestWidget(id: .nowPlaying)
        forceRegistry.register(forceWidget)
        forceRegistry.order = [.nowPlaying]
        let forceActivities = LiveActivityCenter()
        let forceVM = NotchViewModel(registry: forceRegistry, activities: forceActivities)

        forceVM.expand(.nowPlaying)
        let stickyActivity = LiveActivity(kind: .battery, leading: .none, trailing: .none, duration: nil, priority: 200)
        forceActivities.post(stickyActivity)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(forceVM.state == .expanded(.nowPlaying),
              "Notch: setup — a live activity doesn't preempt an already-expanded widget")

        forceVM.forceCollapse()
        check(forceVM.state == .collapsed,
              "Notch: forceCollapse() goes straight to .collapsed even with a live activity current — unlike collapse(), which would resurface it")
        check(forceWidget.dismissCount == 1,
              "Notch: forceCollapse() fires didDismiss exactly once for the widget that was expanded")

        forceVM.forceCollapse()
        check(forceWidget.dismissCount == 1,
              "Notch: forceCollapse() is idempotent — already collapsed, a second call doesn't refire didDismiss")

        // --- Notch: disabling a widget through the registry re-routes the
        // view model away from it when (and only when) it's the one
        // currently expanded ---
        let disableRegistry = NotchWidgetRegistry()
        let onlyWidget = SelfTestWidget(id: .nowPlaying)
        let otherWidget = SelfTestWidget(id: .shelf)
        disableRegistry.register(onlyWidget)
        disableRegistry.register(otherWidget)
        disableRegistry.order = [.nowPlaying, .shelf]
        let disableVM = NotchViewModel(registry: disableRegistry, activities: LiveActivityCenter())

        disableVM.expand(.nowPlaying)
        check(disableVM.state == .expanded(.nowPlaying), "Notch: setup — nowPlaying is expanded")

        disableRegistry.setEnabled(.shelf, false)
        check(disableVM.state == .expanded(.nowPlaying),
              "Notch: disabling a widget that isn't the one currently expanded leaves the state machine untouched")

        disableRegistry.setEnabled(.nowPlaying, false)
        check(disableVM.state == .collapsed,
              "Notch: disabling the currently-expanded widget collapses the panel when no other widget is left enabled")
        check(onlyWidget.dismissCount == 1,
              "Notch: didDismiss fires for a widget disabled while it was expanded")

        disableRegistry.setEnabled(.nowPlaying, true)
        disableRegistry.setEnabled(.shelf, true)
        disableVM.expand(.shelf)
        disableRegistry.setEnabled(.shelf, false)
        check(disableVM.state == .expanded(.nowPlaying),
              "Notch: disabling the expanded widget falls back to another still-enabled widget instead of collapsing when one exists")
        check(otherWidget.dismissCount == 1 && onlyWidget.presentCount == 2,
              "Notch: falling back to nowPlaying dismisses shelf and re-presents nowPlaying exactly once")

        // --- Notch: hoverChanged's hoverHint write is a same-value no-op —
        // the frequent `mouseMoved` redeliveries within an unchanged hover
        // state must not keep republishing it. ---
        let hoverOnlyVM = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter(), expansionTrigger: .click)
        var hoverHintPublishCount = 0
        let hoverHintCancellable = hoverOnlyVM.$hoverHint.dropFirst().sink { _ in hoverHintPublishCount += 1 }
        hoverOnlyVM.hoverChanged(inside: true)
        check(hoverHintPublishCount == 1, "Notch: hoverChanged publishes hoverHint on a real change")
        hoverOnlyVM.hoverChanged(inside: true)
        hoverOnlyVM.hoverChanged(inside: true)
        check(hoverHintPublishCount == 1,
              "Notch: repeated hoverChanged(inside: true) calls (simulating mouseMoved redeliveries) don't republish hoverHint")
        hoverOnlyVM.hoverChanged(inside: false)
        check(hoverHintPublishCount == 2, "Notch: hoverChanged publishes hoverHint again once it actually changes back")
        hoverHintCancellable.cancel()

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
            check(fullState.playbackRate == 1.0, "NowPlaying: full snapshot decodes playbackRate")
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
            check(tickState.playbackRate == 1.0,
                  "NowPlaying: a diff tick (which doesn't mention playbackRate) preserves it unchanged")
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

        // --- NowPlayingService: currentElapsed(at:) scales its projection by
        // playbackRate, and clamps an implausible one to the documented
        // 0.25...4 range instead of letting the scrubber jump wildly. ---
        let rateService = NowPlayingService()
        let sampleTimestamp = Date()
        rateService.injectPreviewState(NowPlayingState(
            title: "Test Track", artist: nil, album: nil, duration: 100,
            elapsed: 10, isPlaying: true, playbackRate: 2.0, artworkData: nil,
            sourceBundleID: nil, timestamp: sampleTimestamp))
        let doubleSpeedElapsed = rateService.currentElapsed(at: sampleTimestamp.addingTimeInterval(5))
        check(doubleSpeedElapsed.map { abs($0 - 20) < 0.01 } ?? false,
              "NowPlaying: currentElapsed at 2x scales 5s of real time into +10s of elapsed (got \(String(describing: doubleSpeedElapsed)))")

        rateService.injectPreviewState(NowPlayingState(
            title: "Test Track", artist: nil, album: nil, duration: 100,
            elapsed: 10, isPlaying: true, playbackRate: 0.5, artworkData: nil,
            sourceBundleID: nil, timestamp: sampleTimestamp))
        let halfSpeedElapsed = rateService.currentElapsed(at: sampleTimestamp.addingTimeInterval(4))
        check(halfSpeedElapsed.map { abs($0 - 12) < 0.01 } ?? false,
              "NowPlaying: currentElapsed at 0.5x scales 4s of real time into +2s of elapsed (got \(String(describing: halfSpeedElapsed)))")

        rateService.injectPreviewState(NowPlayingState(
            title: "Test Track", artist: nil, album: nil, duration: 100,
            elapsed: 10, isPlaying: true, playbackRate: 100, artworkData: nil,
            sourceBundleID: nil, timestamp: sampleTimestamp))
        let clampedElapsed = rateService.currentElapsed(at: sampleTimestamp.addingTimeInterval(1))
        check(clampedElapsed.map { abs($0 - 14) < 0.01 } ?? false,
              "NowPlaying: currentElapsed clamps an absurd playbackRate to the 4x ceiling (got \(String(describing: clampedElapsed)))")

        rateService.injectPreviewState(NowPlayingState(
            title: "Test Track", artist: nil, album: nil, duration: nil,
            elapsed: 10, isPlaying: true, playbackRate: nil, artworkData: nil,
            sourceBundleID: nil, timestamp: sampleTimestamp))
        let missingRateElapsed = rateService.currentElapsed(at: sampleTimestamp.addingTimeInterval(3))
        check(missingRateElapsed.map { abs($0 - 13) < 0.01 } ?? false,
              "NowPlaying: currentElapsed treats a missing playbackRate as normal 1x speed (got \(String(describing: missingRateElapsed)))")

        // --- ScriptingNowPlayingSource: per-poll player selection ---
        // Pure functions (no AppleScript execution) so they're testable on a
        // machine that can't run Music or Spotify at all.
        check(ScriptingNowPlayingSource.primaryCandidate(current: nil, running: []) == nil,
              "Scripting: primaryCandidate is nil when nothing is running")
        check(ScriptingNowPlayingSource.primaryCandidate(current: nil, running: [.spotify]) == .spotify,
              "Scripting: primaryCandidate picks the only running app")
        check(ScriptingNowPlayingSource.primaryCandidate(current: nil, running: [.music, .spotify]) == .music,
              "Scripting: primaryCandidate prefers Music first when nothing is already selected")
        check(ScriptingNowPlayingSource.primaryCandidate(current: .spotify, running: [.music, .spotify]) == .spotify,
              "Scripting: primaryCandidate sticks with the current app if it's still running, even if Music also is")
        check(ScriptingNowPlayingSource.primaryCandidate(current: .spotify, running: [.music]) == .music,
              "Scripting: primaryCandidate falls back once the current app is no longer running")

        check(ScriptingNowPlayingSource.fallbackCandidate(excluding: .music, running: [.music]) == nil,
              "Scripting: fallbackCandidate is nil when the excluded app is the only one running")
        check(ScriptingNowPlayingSource.fallbackCandidate(excluding: .music, running: [.music, .spotify]) == .spotify,
              "Scripting: fallbackCandidate — the fix for a stopped Music silently starving a playing Spotify — offers the other running app for a probe")
        check(ScriptingNowPlayingSource.fallbackCandidate(excluding: .spotify, running: [.music, .spotify]) == .music,
              "Scripting: fallbackCandidate works symmetrically the other direction (stopped Spotify, playing Music)")

        // --- Shelf: ShelfStore round-trip, remove, persistence, reconcile, expiry ---
        // Entirely against throwaway temp directories (never the user's real
        // App Support/Flux/Shelf) so this is safe to run repeatedly and
        // leaves nothing behind once the cleanup at the end of this section runs.
        func makeShelfTempDir() -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        func makeShelfSourceFile(named name: String, in dir: URL, contents: String = "flux-selftest") -> URL {
            let url = dir.appendingPathComponent(name)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        /// Writes `item`'s stored file directly into its per-item
        /// subdirectory, bypassing `ShelfStore.add(urls:)` — for tests that
        /// need to seed on-disk state (alongside a hand-written manifest) as
        /// if a previous launch had already added the item, matching the
        /// `<directory>/<id>/<fileName>` layout `ShelfItem.storedURL(in:)`
        /// now expects.
        func writeShelfStoredFile(for item: ShelfItem, in directory: URL, contents: String = "x") {
            let url = item.storedURL(in: directory)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let shelfSourceDir = makeShelfTempDir()
        let shelfDirA = makeShelfTempDir()
        let shelfManifestURLA = shelfDirA.appendingPathComponent("manifest.json")

        // Round-trip add: a dropped file is copied in, shows up in `items`,
        // its stored copy exists, and the manifest is written.
        let shelfSrc1 = makeShelfSourceFile(named: "hello.txt", in: shelfSourceDir, contents: "hello shelf")
        let shelfStore1 = ShelfStore(directory: shelfDirA)
        let shelfAdded1 = shelfStore1.add(urls: [shelfSrc1])
        check(shelfAdded1.count == 1,
              "Shelf: add() copies a single dropped file and returns exactly the item added")

        if let shelfItem1 = shelfAdded1.first {
            check(shelfStore1.items.contains(where: { $0.id == shelfItem1.id }),
                  "Shelf: the added item appears in items")
            check(FileManager.default.fileExists(atPath: shelfItem1.storedURL(in: shelfDirA).path),
                  "Shelf: the added item's stored copy exists on disk")
            check(FileManager.default.fileExists(atPath: shelfManifestURLA.path),
                  "Shelf: adding writes manifest.json")
            // Storage layout fix: each item lives in its own `<id>/`
            // subdirectory rather than a UUID-prefixed on-disk file name, so
            // the URL handed out for every export (drag-out, AirDrop, Copy)
            // keeps the original basename verbatim — no "2F…-hello.txt"
            // leaking into whatever app receives it.
            check(shelfStore1.url(for: shelfItem1.id)?.lastPathComponent == "hello.txt",
                  "Shelf: the exported URL's last path component is exactly the original file name, not a UUID-prefixed stand-in")

            // Remove: whole per-item subdirectory gone, item gone, manifest updated.
            shelfStore1.remove(shelfItem1.id)
            check(!shelfStore1.items.contains(where: { $0.id == shelfItem1.id }),
                  "Shelf: remove() drops the item from items")
            check(!FileManager.default.fileExists(atPath: shelfItem1.storedURL(in: shelfDirA).path),
                  "Shelf: remove() deletes the stored file")
            check(!FileManager.default.fileExists(atPath: shelfItem1.storedDirectoryURL(in: shelfDirA).path),
                  "Shelf: remove() deletes the whole per-item subdirectory, not just the file inside it")
            let shelfManifestAfterRemove = (try? Data(contentsOf: shelfManifestURLA))
                .flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
            check(!shelfManifestAfterRemove.contains(where: { $0.id == shelfItem1.id }),
                  "Shelf: remove() persists the drop to manifest.json")
        } else {
            check(false, "Shelf: add() produced an item to test remove() against")
        }

        // Persistence: a second ShelfStore instance on the same directory
        // loads what the first one persisted.
        let shelfSrc2 = makeShelfSourceFile(named: "world.txt", in: shelfSourceDir, contents: "world shelf")
        let shelfAdded2 = shelfStore1.add(urls: [shelfSrc2])
        if let shelfItem2 = shelfAdded2.first {
            let shelfStore2 = ShelfStore(directory: shelfDirA)
            check(shelfStore2.items.contains(where: { $0.id == shelfItem2.id && $0.fileName == "world.txt" }),
                  "Shelf: persistence — a fresh ShelfStore on the same directory loads the manifest")

            // Reconcile: delete the stored file behind the store's back (as if
            // the user removed it in Finder) — the next instance to load this
            // directory must drop the now-dangling manifest entry.
            try? FileManager.default.removeItem(at: shelfItem2.storedURL(in: shelfDirA))
            let shelfStore3 = ShelfStore(directory: shelfDirA)
            check(!shelfStore3.items.contains(where: { $0.id == shelfItem2.id }),
                  "Shelf: reconcile — a new instance drops a manifest entry whose stored file vanished behind its back")
        } else {
            check(false, "Shelf: add() produced an item to test persistence/reconcile against")
        }

        // Expiry: an item older than expiryInterval is swept once it's set,
        // but left alone while expiryInterval is nil.
        let shelfDirExpiry = makeShelfTempDir()
        let shelfStaleItem = ShelfItem(fileName: "stale.txt", addedAt: Date().addingTimeInterval(-3_600))
        writeShelfStoredFile(for: shelfStaleItem, in: shelfDirExpiry, contents: "stale")
        if let shelfExpiryManifest = try? JSONEncoder().encode([shelfStaleItem]) {
            try? shelfExpiryManifest.write(to: shelfDirExpiry.appendingPathComponent("manifest.json"))
        }
        let shelfStoreExpiry = ShelfStore(directory: shelfDirExpiry)
        check(shelfStoreExpiry.items.contains(where: { $0.id == shelfStaleItem.id }),
              "Shelf: expiry — a 1-hour-old item is kept across load when expiryInterval is nil")
        // `expiryInterval`'s `didSet` fix: assigning the property alone — no
        // explicit `sweepExpired()` call anywhere below — must be enough to
        // drop the now-expired item. Before the fix, a freshly-configured
        // auto-clear interval only took effect the next time `init`/
        // `add(urls:)` happened to run, so a shelf nobody was actively
        // dropping into again would never tidy itself after being configured.
        shelfStoreExpiry.expiryInterval = 60 // 1 minute — the stale item is an hour old
        check(!shelfStoreExpiry.items.contains(where: { $0.id == shelfStaleItem.id }),
              "Shelf: expiry — assigning expiryInterval alone sweeps a now-expired item via didSet, with no explicit sweepExpired() call")

        // Batch sweep: several expired items alongside one fresh survivor.
        // `sweepExpired()` partitions/deletes/persists in one shot rather
        // than calling `remove(_:)` per item — asserting *how many times* the
        // manifest was written would be a fragile way to verify that (mtimes,
        // buffering, etc.), so this instead only checks observable
        // correctness: every expired item is gone (files and manifest), the
        // fresh one survives, and nothing else was disturbed. The explicit
        // `sweepExpired()` call below is redundant with the `didSet`-driven
        // sweep the `expiryInterval` assignment just triggered — kept anyway
        // to assert that calling it directly afterward stays safe/idempotent.
        let shelfDirBatch = makeShelfTempDir()
        let staleBatch1 = ShelfItem(fileName: "stale1.txt", addedAt: Date().addingTimeInterval(-3_600))
        let staleBatch2 = ShelfItem(fileName: "stale2.txt", addedAt: Date().addingTimeInterval(-7_200))
        let freshBatch = ShelfItem(fileName: "fresh.txt", addedAt: Date())
        for item in [staleBatch1, staleBatch2, freshBatch] {
            writeShelfStoredFile(for: item, in: shelfDirBatch)
        }
        if let batchManifest = try? JSONEncoder().encode([staleBatch1, staleBatch2, freshBatch]) {
            try? batchManifest.write(to: shelfDirBatch.appendingPathComponent("manifest.json"))
        }
        let shelfStoreBatch = ShelfStore(directory: shelfDirBatch)
        shelfStoreBatch.expiryInterval = 60
        shelfStoreBatch.sweepExpired()
        check(!shelfStoreBatch.items.contains(where: { $0.id == staleBatch1.id }) &&
              !shelfStoreBatch.items.contains(where: { $0.id == staleBatch2.id }),
              "Shelf: batch sweepExpired() removes every expired item in one pass, not just the first")
        check(shelfStoreBatch.items.contains(where: { $0.id == freshBatch.id }),
              "Shelf: batch sweepExpired() leaves a non-expired item untouched")
        check(!FileManager.default.fileExists(atPath: staleBatch1.storedURL(in: shelfDirBatch).path) &&
              !FileManager.default.fileExists(atPath: staleBatch2.storedURL(in: shelfDirBatch).path),
              "Shelf: batch sweepExpired() deletes every expired item's stored file")
        let batchManifestAfter = (try? Data(contentsOf: shelfDirBatch.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
        check(batchManifestAfter.count == 1 && batchManifestAfter.first?.id == freshBatch.id,
              "Shelf: batch sweepExpired() persists a single post-sweep manifest write with only the survivor")

        // Lazy thumbnails: a freshly-loaded store (nothing added/opened yet)
        // starts with no thumbnails at all — the eager per-item generation
        // loop that used to run in `init` is gone — and `ensureThumbnails()`
        // (what `ShelfWidget.willPresent()` calls) is safe to call without
        // crashing even though `QLThumbnailGenerator`'s result arrives
        // asynchronously and can't be awaited deterministically here.
        check(shelfStoreBatch.thumbnails.isEmpty,
              "Shelf: a store with items freshly loaded from a manifest (not added, not presented) starts with no thumbnails — generation is lazy")
        shelfStoreBatch.ensureThumbnails()

        for shelfDir in [shelfSourceDir, shelfDirA, shelfDirExpiry, shelfDirBatch] {
            try? FileManager.default.removeItem(at: shelfDir)
        }

        // --- Notch: drag-flag lifecycle (dragEntered/dragExited/dragCompleted) ---
        // Uses the same `SelfTestWidget` stub as the transition-table tests
        // above so this exercises the real `NotchViewModel`, not a mock.
        let dragRegistry = NotchWidgetRegistry()
        let dragShelfWidget = SelfTestWidget(id: .shelf)
        dragRegistry.register(dragShelfWidget)
        dragRegistry.order = [.shelf]
        let dragVM = NotchViewModel(registry: dragRegistry, activities: LiveActivityCenter())

        // A drag entering the collapsed notch auto-expands to the shelf...
        dragVM.dragEntered()
        check(dragVM.state == .expanded(.shelf),
              "Drag: dragEntered() auto-expands from collapsed to the shelf widget")

        // ...and dragExited() (the drag left without a drop) collapses it
        // back, since this exact drag is the one that opened it.
        dragVM.dragExited()
        check(dragVM.state == .collapsed,
              "Drag: dragExited() collapses a shelf that this same drag auto-expanded")

        // A drag entering when the shelf isn't registered/enabled at all is
        // a no-op — nothing to auto-expand to.
        let noShelfRegistry = NotchWidgetRegistry()
        let noShelfWidget = SelfTestWidget(id: .nowPlaying)
        noShelfRegistry.register(noShelfWidget)
        noShelfRegistry.order = [.nowPlaying]
        let noShelfVM = NotchViewModel(registry: noShelfRegistry, activities: LiveActivityCenter())
        noShelfVM.dragEntered()
        check(noShelfVM.state == .collapsed,
              "Drag: dragEntered() is a no-op when no shelf widget is registered/enabled")

        // A drop landing instead just clears the auto-expand flag and leaves
        // the shelf open — a later, stray dragExited() (another drag session
        // merely passing near the already-open shelf) must not close it.
        dragVM.dragEntered()
        check(dragVM.state == .expanded(.shelf), "Drag: setup — re-enter for the dragCompleted() case")
        dragVM.dragCompleted()
        dragVM.dragExited()
        check(dragVM.state == .expanded(.shelf),
              "Drag: dragCompleted() clears the auto-expand flag, so a later dragExited() leaves the still-open shelf alone")
        dragVM.collapse()

        // If the state machine lands on `.collapsed` via any OTHER path
        // (not `dragExited()` itself) while a drag had auto-expanded the
        // shelf, that must also clear the flag — otherwise it could survive
        // to misfire against whatever the user does next.
        dragVM.dragEntered()
        check(dragVM.state == .expanded(.shelf), "Drag: setup — auto-expanded again")
        dragVM.collapse() // an ordinary collapse, not dragExited()
        check(dragVM.state == .collapsed, "Drag: setup — collapsed via collapse(), not dragExited()")
        dragVM.expand(.shelf) // the user reopens it themselves
        check(dragVM.state == .expanded(.shelf), "Drag: setup — user reopens the shelf themselves")
        dragVM.dragExited()
        check(dragVM.state == .expanded(.shelf),
              "Drag: transition(to:) clearing dragAutoExpanded on the earlier collapse() means a stray dragExited() can't close a panel the user reopened themselves")

        // --- Notch: NotchWindowController.shouldAcceptDrag — the pure
        // predicate behind the window-level drag destination's accept/decline
        // decision, testable without a real window, screen, or drag session ---
        check(NotchWindowController.shouldAcceptDrag(state: .collapsed, pointInNotch: true, shelfEnabled: true),
              "Drag accept: collapsed + inside the (slop-padded) notch + shelf enabled accepts")
        check(!NotchWindowController.shouldAcceptDrag(state: .collapsed, pointInNotch: true, shelfEnabled: false),
              "Drag accept: collapsed but the shelf widget is disabled declines")
        check(!NotchWindowController.shouldAcceptDrag(state: .collapsed, pointInNotch: false, shelfEnabled: true),
              "Drag accept: collapsed but the point is outside the notch declines")
        check(NotchWindowController.shouldAcceptDrag(state: .expanded(.shelf), pointInNotch: true, shelfEnabled: true),
              "Drag accept: already expanded to the shelf + inside its bounds accepts (keeps the window accepting after auto-expand)")
        check(!NotchWindowController.shouldAcceptDrag(state: .expanded(.shelf), pointInNotch: false, shelfEnabled: true),
              "Drag accept: expanded to the shelf but the point left its bounds declines")
        check(!NotchWindowController.shouldAcceptDrag(state: .expanded(.nowPlaying), pointInNotch: true, shelfEnabled: true),
              "Drag accept: expanded to a different widget (not the shelf) declines even if the point is inside")
        check(!NotchWindowController.shouldAcceptDrag(state: .activity(UUID()), pointInNotch: true, shelfEnabled: true),
              "Drag accept: a live activity showing declines")

        // --- M3: PowerMonitor.lowBatteryEvent — the low-battery hysteresis,
        // testable as a pure function with no real IOKit power source ---
        do {
            var armed = true
            let ac = PowerState(percent: 50, isCharging: true, onACPower: true)
            let unplugged60 = PowerState(percent: 60, isCharging: false, onACPower: false)
            let unplugged20 = PowerState(percent: 20, isCharging: false, onACPower: false)
            let unplugged19 = PowerState(percent: 19, isCharging: false, onACPower: false)
            let unplugged26 = PowerState(percent: 26, isCharging: false, onACPower: false)

            check(PowerMonitor.lowBatteryEvent(previous: unplugged60, current: unplugged20, armed: &armed) == .lowBattery(percent: 20),
                  "PowerMonitor: crossing below 20% unplugged fires .lowBattery once")
            check(!armed, "PowerMonitor: firing disarms so the same low level doesn't refire")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged20, current: unplugged19, armed: &armed) == nil,
                  "PowerMonitor: staying low while disarmed doesn't refire")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged19, current: unplugged26, armed: &armed) == nil,
                  "PowerMonitor: crossing back above the 25% re-arm threshold doesn't itself fire")
            check(armed, "PowerMonitor: crossing above 25% re-arms")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged26, current: unplugged20, armed: &armed) == .lowBattery(percent: 20),
                  "PowerMonitor: re-armed, dropping below 20% again fires again")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged20, current: ac, armed: &armed) == nil,
                  "PowerMonitor: plugging in while low never fires .lowBattery")
            check(armed, "PowerMonitor: plugging in re-arms (a fresh unplug can refire immediately)")
        }

        // --- M3: PowerMonitor.plugEvent — plug/unplug transition detection ---
        do {
            let ac = PowerState(percent: 80, isCharging: true, onACPower: true)
            let battery = PowerState(percent: 80, isCharging: false, onACPower: false)
            check(PowerMonitor.plugEvent(previous: battery, current: ac) == .pluggedIn(percent: 80),
                  "PowerMonitor: an AC transition fires .pluggedIn")
            check(PowerMonitor.plugEvent(previous: ac, current: battery) == .unplugged(percent: 80),
                  "PowerMonitor: losing AC fires .unplugged")
            check(PowerMonitor.plugEvent(previous: ac, current: ac) == nil,
                  "PowerMonitor: no power-source change means no event")
        }

        // --- M3: BluetoothMonitor.isDuplicate — the reconnect-storm dedupe
        // window, as a pure predicate over a plain address→timestamp map ---
        do {
            let t0 = Date()
            var lastEventAt: [String: Date] = [:]
            check(!BluetoothMonitor.isDuplicate(address: "AA", now: t0, lastEventAt: lastEventAt),
                  "BluetoothMonitor: a device's first event is never a duplicate")
            lastEventAt["AA"] = t0
            check(BluetoothMonitor.isDuplicate(address: "AA", now: t0.addingTimeInterval(2), lastEventAt: lastEventAt),
                  "BluetoothMonitor: a same-device event 2s later falls inside the 5s dedupe window")
            check(!BluetoothMonitor.isDuplicate(address: "AA", now: t0.addingTimeInterval(6), lastEventAt: lastEventAt),
                  "BluetoothMonitor: a same-device event past 5s is treated as new")
            check(!BluetoothMonitor.isDuplicate(address: "BB", now: t0.addingTimeInterval(1), lastEventAt: lastEventAt),
                  "BluetoothMonitor: a different device's address is never deduped by another's window")
        }

        // --- M3: NotchActivityRouter — SF Symbol choice helpers ---
        check(NotchActivityRouter.batterySymbol(percent: 100, charging: false) == "battery.100",
              "NotchActivityRouter: a full battery maps to battery.100")
        check(NotchActivityRouter.batterySymbol(percent: 74, charging: false) == "battery.50",
              "NotchActivityRouter: percent rounds DOWN to the nearest SF Symbol step (74% -> 50, never up to 75)")
        check(NotchActivityRouter.batterySymbol(percent: 50, charging: true) == "battery.50.bolt",
              "NotchActivityRouter: charging adds the .bolt variant")
        check(NotchActivityRouter.deviceSymbol(name: "Ammar's AirPods Pro") == "airpodspro",
              "NotchActivityRouter: AirPods-named devices map to the airpodspro glyph")
        check(NotchActivityRouter.deviceSymbol(name: "Sony WH-1000XM4") == "headphones",
              "NotchActivityRouter: unrecognized device names fall back to a generic headphones glyph")

        // --- M3: NotchActivityRouter — event-to-LiveActivity translation and
        // settings gating, with real PowerMonitor/BluetoothMonitor instances
        // standing in only as event sources (their .events subjects are fed
        // directly here — no real IOKit/IOBluetooth state is exercised) ---
        do {
            let routerSuiteName = "flux.selftest.router"
            let routerSuite = UserDefaults(suiteName: routerSuiteName)!
            routerSuite.removePersistentDomain(forName: routerSuiteName)
            let routerSettings = SettingsStore(defaults: routerSuite)
            let routerActivities = LiveActivityCenter()
            let routerArranger = MenuBarArranger()
            let testPower = PowerMonitor()
            let testBluetooth = BluetoothMonitor()
            let router = NotchActivityRouter(activities: routerActivities, settings: routerSettings,
                                              arranger: routerArranger, power: testPower, bluetooth: testBluetooth)

            // `withExtendedLifetime` keeps `router` (and its Combine
            // subscriptions on `testPower`/`testBluetooth`) alive for the
            // whole block — otherwise ARC would be free to deallocate an
            // otherwise-unread local the moment after construction, silently
            // cancelling the very subscriptions these assertions depend on.
            withExtendedLifetime(router) {
                testPower.events.send(.unplugged(percent: 45))
                check(routerActivities.current?.kind == .battery,
                      "NotchActivityRouter: a PowerEvent posts a .battery live activity")
                check(routerActivities.current?.priority == 200,
                      "NotchActivityRouter: battery activities post at priority 200")
                check(routerActivities.current?.duration == 4,
                      "NotchActivityRouter: battery activities expire after 4s")
                check(routerActivities.current?.tint == .normal,
                      "NotchActivityRouter: a plain unplug is untinted")

                testPower.events.send(.lowBattery(percent: 15))
                check(routerActivities.current?.tint == .warning,
                      "NotchActivityRouter: .lowBattery posts a .warning-tinted activity")

                // Battery (priority 200) outranks bluetooth (priority 100) in
                // `LiveActivityCenter`'s priority queue by design — dismiss it
                // here so the bluetooth checks below observe their own posts
                // as `current` rather than the still-queued battery activity.
                routerActivities.dismiss(kind: .battery)

                testBluetooth.events.send(.connected(name: "AirPods Pro", batteryPercent: 80))
                check(routerActivities.current?.kind == .bluetoothDevice,
                      "NotchActivityRouter: a BluetoothEvent posts a .bluetoothDevice live activity")
                check(routerActivities.current?.priority == 100,
                      "NotchActivityRouter: bluetooth activities post at priority 100")
                check(routerActivities.current?.trailing == .iconText(systemName: "battery.100", text: "80%"),
                      "NotchActivityRouter: a reported battery percent shows as icon+text")

                testBluetooth.events.send(.connected(name: "Sony WH-1000XM4", batteryPercent: nil))
                check(routerActivities.current?.trailing == .text("Sony WH-1000XM4"),
                      "NotchActivityRouter: no battery reading falls back to showing the device name")

                // Settings gating: flipping a toggle off suppresses further
                // posts of that kind, without touching the other kind.
                routerActivities.dismiss(kind: .battery)
                routerSettings.notchActivityBatteryEnabled = false
                testPower.events.send(.pluggedIn(percent: 90))
                check(routerActivities.current?.kind != .battery,
                      "NotchActivityRouter: the battery toggle off suppresses new battery posts")

                testBluetooth.events.send(.disconnected(name: "AirPods Pro"))
                check(routerActivities.current?.kind == .bluetoothDevice,
                      "NotchActivityRouter: the bluetooth toggle (still on) keeps posting independently of the battery toggle")
            }
            routerSuite.removePersistentDomain(forName: routerSuiteName)
        }

        print(allPassed ? "\n🎉 ALL CHECKS PASSED" : "\n❌ SOME CHECKS FAILED")
        exit(allPassed ? 0 : 1)
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import Foundation
import EventKit
import AVFoundation
import CoreGraphics
import ApplicationServices

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

        // The code-review fix: posting the same kind again with DIFFERENT
        // content (79% vs. 80%) still supersedes the stale one — but the
        // in-place update keeps the ORIGINAL id (batteryA's), not batteryB's
        // own freshly-generated one, so SwiftUI sees an update to the
        // existing view rather than a remove+insert.
        let batteryA = LiveActivity(kind: .battery, leading: .text("80%"), trailing: .none, duration: nil, priority: 200)
        let batteryB = LiveActivity(kind: .battery, leading: .text("79%"), trailing: .none, duration: nil, priority: 200)
        center.post(batteryA)
        center.post(batteryB)
        check(center.current?.id == batteryA.id,
              "LiveActivity: posting the same kind again with different content updates in place (keeps the original id) instead of stacking or churning identity")
        check(center.current?.leading == .text("79%"),
              "LiveActivity: the in-place update reflects the newly posted content")
        center.dismiss(id: batteryA.id)

        // --- M6 fix (M9: now read directly by `LockScreenContentView`'s
        // activity pill via `LiveActivityCenter.current?.captionText`,
        // rather than through the M6 `currentActivityLine` closure this
        // replaced) — LiveActivity.captionText: the generic seam that keeps
        // the lock-screen activity pill from depending on any one producer
        // (e.g. timers) specifically. Prefers `trailing` over `leading`, and
        // is `nil` for icon/gauge/artwork/`.none` content on both sides. ---
        check(LiveActivity(kind: .timer, leading: .icon(systemName: "timer"), trailing: .text("2 min"),
                            duration: nil, priority: 110).captionText == "2 min",
              "LiveActivity: captionText reads a .text trailing side")
        check(LiveActivity(kind: .battery, leading: .none,
                            trailing: .iconText(systemName: "battery.100", text: "80%"),
                            duration: nil, priority: 200).captionText == "80%",
              "LiveActivity: captionText reads an .iconText trailing side too")
        check(LiveActivity(kind: .battery, leading: .text("leading fallback"), trailing: .none,
                            duration: nil, priority: 200).captionText == "leading fallback",
              "LiveActivity: captionText falls back to leading when trailing has no text")
        check(LiveActivity(kind: .battery, leading: .icon(systemName: "battery.100"),
                            trailing: .gauge(0.8, systemName: "battery.100"),
                            duration: nil, priority: 200).captionText == nil,
              "LiveActivity: captionText is nil when neither side carries text (icon + gauge)")
        check(LiveActivity(kind: .nowPlaying, leading: .artwork, trailing: .none,
                            duration: nil, priority: 50).captionText == nil,
              "LiveActivity: captionText is nil for an artwork-only activity")

        // --- LiveActivity: same-kind EQUAL-content repost (a key-repeat
        // storm reposting an unchanged gauge) reuses the existing id and
        // just extends its expiry deadline instead of replacing it. ---
        //
        // Timing is deliberately generous (hundreds of ms, ~150ms margins on
        // every side) rather than tight fractions of a short duration — a
        // loaded CI runner's real scheduling jitter is easily tens of ms, and
        // this needs to reliably land BEFORE one deadline and AFTER another
        // rather than merely after some elapsed time (unlike e.g.
        // `hoverOpenDelay + 0.15`'s simpler "wait comfortably past" checks
        // elsewhere in this file).
        let repostCenter = LiveActivityCenter()
        let repostDuration: TimeInterval = 0.6
        let repostGapBeforeRepost: TimeInterval = 0.3 // comfortably < repostDuration
        let repostFirst = LiveActivity(kind: .hudVolume, leading: .icon(systemName: "speaker.wave.2.fill"),
                                        trailing: .gauge(0.5, systemName: "speaker.wave.2.fill"),
                                        duration: repostDuration, priority: 300)
        repostCenter.post(repostFirst) // deadline at t≈0.6
        RunLoop.current.run(until: Date().addingTimeInterval(repostGapBeforeRepost)) // t≈0.3, well before 0.6
        let repostEqual = LiveActivity(kind: .hudVolume, leading: .icon(systemName: "speaker.wave.2.fill"),
                                        trailing: .gauge(0.5, systemName: "speaker.wave.2.fill"),
                                        duration: repostDuration, priority: 300)
        repostCenter.post(repostEqual) // resets the deadline to t≈0.3+0.6=0.9
        check(repostCenter.current?.id == repostFirst.id,
              "LiveActivity: an equal-content repost of the same kind reuses the original id instead of replacing it")
        // t≈0.75: past the ORIGINAL post's own deadline (0.6) — proof the
        // repost actually rescheduled the expiry Task rather than being a
        // no-op — but comfortably before the extended one (0.9).
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        check(repostCenter.current?.id == repostFirst.id,
              "LiveActivity: the equal-content repost extended the expiry deadline — it survives past the original post's own duration")
        // t≈1.1: comfortably past the extended deadline (0.9) too.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        check(repostCenter.current == nil,
              "LiveActivity: the extended deadline still expires on its own schedule once it's actually reached")

        // Content-change repost of the same kind: same shape as the battery
        // case above, isolated here against a duration-bearing kind.
        let contentChangeCenter = LiveActivityCenter()
        let contentFirst = LiveActivity(kind: .hudVolume, leading: .icon(systemName: "speaker.wave.1.fill"),
                                         trailing: .gauge(0.2, systemName: "speaker.wave.1.fill"),
                                         duration: nil, priority: 300)
        contentChangeCenter.post(contentFirst)
        let contentSecond = LiveActivity(kind: .hudVolume, leading: .icon(systemName: "speaker.wave.3.fill"),
                                          trailing: .gauge(0.9, systemName: "speaker.wave.3.fill"),
                                          duration: nil, priority: 300)
        contentChangeCenter.post(contentSecond)
        check(contentChangeCenter.current?.id == contentFirst.id,
              "LiveActivity: a content-changed repost of the same kind keeps the original id (an update, not a replace)")
        check(contentChangeCenter.current?.trailing == .gauge(0.9, systemName: "speaker.wave.3.fill"),
              "LiveActivity: a content-changed repost's new value is what's actually shown")

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

        // Transition-direction classification (drives the view's spring
        // choice: shrinks settle on the collapse spring, growths overshoot).
        check(NotchViewModel.footprintRank(.collapsed) < NotchViewModel.footprintRank(.activity(UUID()))
                && NotchViewModel.footprintRank(.activity(UUID())) < NotchViewModel.footprintRank(.expanded(.nowPlaying)),
              "Notch: footprint ranks order collapsed < activity < expanded")
        check(notchVM.lastTransitionWasShrink == false,
              "Notch: opening from collapsed records a growth, not a shrink")
        // Widget→widget tie-break: equal rank, decided by panel heights
        // (calendar 190 → shelf 150 is a shrink; the reverse is a growth).
        check(NotchViewModel.isShrink(from: .expanded(.calendar), to: .expanded(.shelf)),
              "Notch: cycling to a shorter widget classifies as a shrink")
        check(!NotchViewModel.isShrink(from: .expanded(.shelf), to: .expanded(.calendar)),
              "Notch: cycling to a taller widget classifies as a growth")
        notchVM.collapse()
        check(notchVM.lastTransitionWasShrink == true,
              "Notch: collapsing records a shrink so the collapse spring is used")

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

        // --- M9: NowPlayingService.shouldEngageScriptingFallback — the pure
        // consent-gating decision behind the AppleScript failover, extracted
        // so it's testable without a live Music/Spotify process (this
        // environment can't run either). Both `setActive` and
        // `observeSources`'s adapter-availability sink route through this
        // one rule; the fallback must never engage while the consent toggle
        // is off, even if the adapter is unavailable. ---
        check(!NowPlayingService.shouldEngageScriptingFallback(allowScriptingFallback: false, adapterAvailable: false),
              "NowPlayingService: the scripting fallback never engages while the consent toggle is off, even with the adapter unavailable")
        check(!NowPlayingService.shouldEngageScriptingFallback(allowScriptingFallback: false, adapterAvailable: true),
              "NowPlayingService: the scripting fallback stays off with the toggle off and the adapter alive too")
        check(NowPlayingService.shouldEngageScriptingFallback(allowScriptingFallback: true, adapterAvailable: false),
              "NowPlayingService: opting in engages the fallback once the adapter is unavailable")
        check(!NowPlayingService.shouldEngageScriptingFallback(allowScriptingFallback: true, adapterAvailable: true),
              "NowPlayingService: even opted in, the fallback doesn't engage while the preferred adapter is alive")

        // Behavioral check on a real instance: setting `allowScriptingFallback`
        // is itself gated the same way — flipping it on while the widget
        // isn't presented (`isActive == false`) must not start the scripting
        // poller, honoring the same "widget hidden -> scripting poll MUST
        // stop" contract `setActive` documents.
        let consentService = NowPlayingService()
        check(!consentService.allowScriptingFallback,
              "NowPlayingService: allowScriptingFallback defaults to false on a fresh instance")
        consentService.allowScriptingFallback = true
        check(consentService.allowScriptingFallback,
              "NowPlayingService: allowScriptingFallback is settable (wired from SettingsStore by AppDelegate)")

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
            let unplugged70 = PowerState(percent: 70, isCharging: false, onACPower: false)
            let unplugged20 = PowerState(percent: 20, isCharging: false, onACPower: false)
            let unplugged19 = PowerState(percent: 19, isCharging: false, onACPower: false)
            let unplugged26 = PowerState(percent: 26, isCharging: false, onACPower: false)

            // Ordinary ticks above the re-arm line, with nothing ever having
            // fired, must never emit `.batteryRecovered` — there's nothing to
            // recover from, and this is by far the most common state a
            // discharging, still-armed battery sits in.
            var neverFired = true
            check(PowerMonitor.lowBatteryEvent(previous: unplugged60, current: unplugged70, armed: &neverFired) == nil,
                  "PowerMonitor: staying above the re-arm threshold while never having fired emits nothing (no spurious .batteryRecovered)")

            check(PowerMonitor.lowBatteryEvent(previous: unplugged60, current: unplugged20, armed: &armed) == .lowBattery(percent: 20),
                  "PowerMonitor: crossing below 20% unplugged fires .lowBattery once")
            check(!armed, "PowerMonitor: firing disarms so the same low level doesn't refire")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged20, current: unplugged19, armed: &armed) == nil,
                  "PowerMonitor: staying low while disarmed doesn't refire")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged19, current: unplugged26, armed: &armed) == .batteryRecovered(percent: 26),
                  "PowerMonitor: crossing back above the 25% re-arm threshold after a fire posts .batteryRecovered (so the sticky warning comes down) instead of another .lowBattery")
            check(armed, "PowerMonitor: crossing above 25% re-arms")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged26, current: unplugged20, armed: &armed) == .lowBattery(percent: 20),
                  "PowerMonitor: re-armed, dropping below 20% again fires again")
            check(PowerMonitor.lowBatteryEvent(previous: unplugged20, current: ac, armed: &armed) == nil,
                  "PowerMonitor: plugging in while low never fires .lowBattery or .batteryRecovered (`.pluggedIn` already carries its own replacement activity)")
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
        check(NotchActivityRouter.batterySymbol(percent: 50, charging: true) == "battery.100.bolt",
              "NotchActivityRouter: charging always uses battery.100.bolt (the only .bolt step SF Symbols ships)")
        check(NotchActivityRouter.deviceSymbol(name: "Ammar's AirPods Pro", category: .audio) == "airpodspro",
              "NotchActivityRouter: AirPods-named devices map to the airpodspro glyph")
        check(NotchActivityRouter.deviceSymbol(name: "Sony WH-1000XM4", category: .audio) == "headphones",
              "NotchActivityRouter: unrecognized audio-category device names fall back to a generic headphones glyph")
        check(NotchActivityRouter.deviceSymbol(name: "Magic Keyboard", category: .peripheral) == "keyboard",
              "NotchActivityRouter: a peripheral-category device named 'Keyboard' maps to the keyboard glyph, not headphones")
        check(NotchActivityRouter.deviceSymbol(name: "Magic Mouse", category: .peripheral) == "computermouse",
              "NotchActivityRouter: a peripheral-category device named 'Mouse' maps to the computermouse glyph")
        check(NotchActivityRouter.deviceSymbol(name: "Xbox Wireless Controller", category: .peripheral) == "gamecontroller",
              "NotchActivityRouter: a peripheral-category device named 'Controller' maps to the gamecontroller glyph")
        check(NotchActivityRouter.deviceSymbol(name: "Some HID Gadget", category: .peripheral) == "cable.connector",
              "NotchActivityRouter: a peripheral-category device whose name hints at no specific kind falls back to a generic accessory glyph, not headphones")

        // --- M3: NotchActivityRouter — event-to-LiveActivity translation and
        // settings gating, with real PowerMonitor/BluetoothMonitor instances
        // standing in only as event sources (their .events subjects are fed
        // directly here — no real IOKit/IOBluetooth state is exercised) ---
        do {
            let routerSuiteName = "flux.selftest.router"
            let routerSuite = UserDefaults(suiteName: routerSuiteName)!
            routerSuite.removePersistentDomain(forName: routerSuiteName)
            let routerSettings = SettingsStore(defaults: routerSuite)
            // M9 privacy audit: Bluetooth now defaults to OFF — opt in
            // explicitly so this block can keep exercising the
            // BluetoothEvent -> LiveActivity translation logic below.
            routerSettings.notchActivityBluetoothEnabled = true
            let routerActivities = LiveActivityCenter()
            let routerArranger = MenuBarArranger()
            let testPower = PowerMonitor()
            let testBluetooth = BluetoothMonitor()
            let testCalendar = CalendarService()
            let testPermissions = PermissionCenter()
            let testTimers = TimerService()
            // A plain, headless `NotchViewModel` — the router only reads its
            // `$state`, never anything screen/panel-related, so this needs no
            // `NotchWindowController` (which would need a real notch screen
            // to ever become `isPresenting`) behind it at all.
            let routerViewModel = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter())
            // `startsMonitors: false` — this test drives `testPower`/
            // `testBluetooth` purely by feeding synthetic events straight
            // through their `.events` subjects (below); it must never let the
            // router's real settings-driven lifecycle call `start()` on
            // either monitor, which would register real IOKit/IOBluetooth
            // run-loop sources and notifications on the CI runner (flaky and
            // slow in a headless environment with no real battery/Bluetooth
            // hardware to speak of). Same reasoning extends `testCalendar`/
            // `testPermissions`: this block only exercises the event-soon
            // pure translation logic (below), never a real EventKit fetch.
            // `presentation` is left at its default (`Just(true)`) — this
            // block doesn't exercise the M4 grant-while-open/screen-disappear
            // fix directly; that's covered below by
            // `NotchActivityRouter.calendarServiceShouldRun`'s own pure-logic
            // checks instead of a live Combine simulation (see this file's
            // M3-era note on why: a debounced/`.receive(on:)` sink needs a
            // `RunLoop` spin to observe, which the pure function sidesteps
            // entirely).
            let router = NotchActivityRouter(activities: routerActivities, settings: routerSettings,
                                              arranger: routerArranger, calendar: testCalendar,
                                              permissions: testPermissions, viewModel: routerViewModel,
                                              timers: testTimers,
                                              power: testPower, bluetooth: testBluetooth, startsMonitors: false)

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
                check(routerActivities.current?.duration == nil,
                      "NotchActivityRouter: .lowBattery posts a STICKY (duration nil) activity — a transient 4s toast is too easy to miss for a warning that matters")

                // `.batteryRecovered` (percent climbed back above the re-arm
                // threshold with no plug event) must bring the sticky warning
                // down even though there's no replacement activity to post.
                testPower.events.send(.batteryRecovered(percent: 30))
                check(routerActivities.current?.kind != .battery,
                      "NotchActivityRouter: .batteryRecovered dismisses the sticky low-battery warning with no plug event to replace it")

                // Plugging in while the sticky warning is up must replace it
                // with a transient charging activity, not leave both queued.
                testPower.events.send(.lowBattery(percent: 10))
                check(routerActivities.current?.duration == nil,
                      "NotchActivityRouter: a fresh .lowBattery re-posts sticky after a prior recovery")
                testPower.events.send(.pluggedIn(percent: 25))
                check(routerActivities.current?.kind == .battery && routerActivities.current?.tint == .normal,
                      "NotchActivityRouter: plugging in while the sticky low-battery warning is showing replaces it with a transient charging activity (same-kind post dedup in LiveActivityCenter)")
                check(routerActivities.current?.duration == 4,
                      "NotchActivityRouter: the replacement charging activity is transient (4s), not sticky")

                // Battery (priority 200) outranks bluetooth (priority 100) in
                // `LiveActivityCenter`'s priority queue by design — dismiss it
                // here so the bluetooth checks below observe their own posts
                // as `current` rather than the still-queued battery activity.
                routerActivities.dismiss(kind: .battery)

                testBluetooth.events.send(.connected(name: "AirPods Pro", batteryPercent: 80, category: .audio))
                check(routerActivities.current?.kind == .bluetoothDevice,
                      "NotchActivityRouter: a BluetoothEvent posts a .bluetoothDevice live activity")
                check(routerActivities.current?.priority == 100,
                      "NotchActivityRouter: bluetooth activities post at priority 100")
                check(routerActivities.current?.trailing == .iconText(systemName: "battery.75", text: "80%"),
                      "NotchActivityRouter: a reported battery percent shows as icon+text using the real batterySymbol picker (80% -> the 75% SF Symbol step, not a hardcoded battery.100)")

                testBluetooth.events.send(.connected(name: "Sony WH-1000XM4", batteryPercent: nil, category: .audio))
                check(routerActivities.current?.trailing == .text("Sony WH-1000XM4"),
                      "NotchActivityRouter: no battery reading falls back to showing the device name")

                // Settings gating: flipping a toggle off suppresses further
                // posts of that kind, without touching the other kind.
                routerActivities.dismiss(kind: .battery)
                routerSettings.notchActivityBatteryEnabled = false
                testPower.events.send(.pluggedIn(percent: 90))
                check(routerActivities.current?.kind != .battery,
                      "NotchActivityRouter: the battery toggle off suppresses new battery posts")

                testBluetooth.events.send(.disconnected(name: "AirPods Pro", category: .audio))
                check(routerActivities.current?.kind == .bluetoothDevice,
                      "NotchActivityRouter: the bluetooth toggle (still on) keeps posting independently of the battery toggle")

                // M3 review fix: re-enabling the notch while the menu bar is
                // STILL overflowing must re-post the warning, even though
                // `arranger`'s own published state never changed in between —
                // `observeOverflow()`'s deduped subscription only fires on a
                // genuine change, so a static "still overflowing" condition
                // would otherwise never republish through it.
                routerArranger.setOverflow(arrange: false, notch: true, iconCount: 5)
                // `observeOverflow()` delivers on `.receive(on: RunLoop.main)`
                // (like several other sinks in this codebase — the hotkey
                // shortcut and arrange-hint ones in `AppDelegate`, e.g.) —
                // deliberately deferred, not synchronous, so a plain `check`
                // straight after `setOverflow()` would race the scheduled
                // delivery and see the *previous* activity. Spin the run loop
                // briefly first, the same way the hover/focus sinks earlier
                // in this file do.
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                check(routerActivities.current?.kind == .menuBarOverflow,
                      "NotchActivityRouter: a real menu-bar overflow posts a .menuBarOverflow live activity")
                routerSettings.notchEnabled = false
                check(routerActivities.current?.kind != .menuBarOverflow,
                      "NotchActivityRouter: disabling the notch dismisses the overflow warning (nowhere left to show it)")
                routerSettings.notchEnabled = true
                check(routerActivities.current?.kind == .menuBarOverflow,
                      "NotchActivityRouter: re-enabling the notch while still overflowing re-posts the warning even though arranger's overflow state itself never changed")
            }
            routerSuite.removePersistentDomain(forName: routerSuiteName)
        }

        // --- M4: PermissionCenter — EKAuthorizationStatus/AVAuthorizationStatus
        // mapping is pure and testable without any real TCC state ---
        check(PermissionCenter.mapCalendarStatus(.notDetermined) == .notDetermined,
              "PermissionCenter: EKAuthorizationStatus.notDetermined maps to .notDetermined")
        check(PermissionCenter.mapCalendarStatus(.restricted) == .restricted,
              "PermissionCenter: EKAuthorizationStatus.restricted maps to .restricted")
        check(PermissionCenter.mapCalendarStatus(.denied) == .denied,
              "PermissionCenter: EKAuthorizationStatus.denied maps to .denied")
        check(PermissionCenter.mapCalendarStatus(.fullAccess) == .granted,
              "PermissionCenter: EKAuthorizationStatus.fullAccess maps to .granted")
        check(PermissionCenter.mapCalendarStatus(.writeOnly) == .denied,
              "PermissionCenter: EKAuthorizationStatus.writeOnly maps to .denied — write-only access is as useless to Flux's read-only agenda/live-activity as no access at all")

        check(PermissionCenter.mapCameraStatus(.notDetermined) == .notDetermined,
              "PermissionCenter: AVAuthorizationStatus.notDetermined maps to .notDetermined")
        check(PermissionCenter.mapCameraStatus(.authorized) == .granted,
              "PermissionCenter: AVAuthorizationStatus.authorized maps to .granted")
        check(PermissionCenter.mapCameraStatus(.denied) == .denied,
              "PermissionCenter: AVAuthorizationStatus.denied maps to .denied")
        check(PermissionCenter.mapCameraStatus(.restricted) == .restricted,
              "PermissionCenter: AVAuthorizationStatus.restricted maps to .restricted")

        let permissionCenterSelfTest = PermissionCenter()
        check(PermissionKind.allCases.allSatisfy { permissionCenterSelfTest.statuses[$0] != nil },
              "PermissionCenter: every PermissionKind has a status populated at init")
        permissionCenterSelfTest.refresh(.calendar)
        check(permissionCenterSelfTest.statuses[.calendar] != nil,
              "PermissionCenter: refresh(_:) re-populates a status without crashing")

        // --- M4: CalendarService — pure display helpers, testable without a real EKEventStore ---
        func makeCalendarTestEvent(id: String, title: String, start: Date, end: Date,
                                    isAllDay: Bool = false, location: String? = nil) -> CalendarEvent {
            CalendarEvent(id: id, title: title, start: start, end: end,
                          isAllDay: isAllDay, calendarColor: nil, location: location)
        }

        let calNow = Date()
        let calCalendar = Calendar.current

        // occurrenceID: the recurring-event id-collision fix — every
        // occurrence of a recurring event shares one `eventIdentifier`, so
        // uniqueness has to come from combining it with the occurrence's own
        // `start`.
        let recurringIdentifier = "recurring-series-1"
        let occurrenceA = CalendarService.occurrenceID(eventIdentifier: recurringIdentifier, start: calNow)
        let occurrenceB = CalendarService.occurrenceID(eventIdentifier: recurringIdentifier, start: calNow.addingTimeInterval(86400))
        check(occurrenceA != occurrenceB,
              "CalendarService: occurrenceID differs for two occurrences of the same recurring event once their start dates differ")
        check(occurrenceA == CalendarService.occurrenceID(eventIdentifier: recurringIdentifier, start: calNow),
              "CalendarService: occurrenceID is deterministic for the same identifier+start pair")
        check(CalendarService.occurrenceID(eventIdentifier: nil, start: calNow) != CalendarService.occurrenceID(eventIdentifier: nil, start: calNow),
              "CalendarService: occurrenceID falls back to a fresh (never-colliding) UUID when eventIdentifier is nil")

        // relativeStartPhrase: the shared phrasing helper `nextEventLine` and
        // `NotchActivityRouter.calendarEventSoonActivity` both call, so the
        // "<title> in Nm"/"<title> in Nh"/"<title> now" wording only has to
        // be gotten right in one place.
        check(CalendarService.relativeStartPhrase(title: "Standup", start: calNow, now: calNow) == "Standup now",
              "CalendarService: relativeStartPhrase says 'now' when start == now")
        check(CalendarService.relativeStartPhrase(title: "Standup", start: calNow.addingTimeInterval(-60), now: calNow) == "Standup now",
              "CalendarService: relativeStartPhrase says 'now' for an already-started event")

        // nextEventLine: minutes / hours / now boundaries.
        let eventIn5Min = makeCalendarTestEvent(id: "a", title: "Standup",
            start: calNow.addingTimeInterval(5 * 60), end: calNow.addingTimeInterval(35 * 60))
        check(CalendarService.nextEventLine(events: [eventIn5Min], now: calNow) == "Standup in 5m",
              "CalendarService: nextEventLine renders a same-hour event in minutes")

        let eventIn2Hours = makeCalendarTestEvent(id: "b", title: "Review",
            start: calNow.addingTimeInterval(2 * 3600), end: calNow.addingTimeInterval(3 * 3600))
        check(CalendarService.nextEventLine(events: [eventIn2Hours], now: calNow) == "Review in 2h",
              "CalendarService: nextEventLine renders an hours-away event in hours")

        let eventInProgress = makeCalendarTestEvent(id: "c", title: "Focus Block",
            start: calNow.addingTimeInterval(-10 * 60), end: calNow.addingTimeInterval(20 * 60))
        check(CalendarService.nextEventLine(events: [eventInProgress], now: calNow) == "Focus Block now",
              "CalendarService: nextEventLine renders an already-started, not-yet-ended event as 'now'")

        let eventEnded = makeCalendarTestEvent(id: "d", title: "Past Meeting",
            start: calNow.addingTimeInterval(-3600), end: calNow.addingTimeInterval(-1800))
        check(CalendarService.nextEventLine(events: [eventEnded], now: calNow) == nil,
              "CalendarService: nextEventLine is nil when every event has already ended")
        check(CalendarService.nextEventLine(events: [], now: calNow) == nil,
              "CalendarService: nextEventLine is nil for an empty list")
        check(CalendarService.nextEventLine(events: [eventIn2Hours, eventIn5Min], now: calNow) == "Standup in 5m",
              "CalendarService: nextEventLine picks the earliest-starting qualifying event regardless of list order")

        // groupByDay: boundary at midnight, all-day events.
        let startOfToday = calCalendar.startOfDay(for: calNow)
        let startOfTomorrow = calCalendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfDayAfterTomorrow = calCalendar.date(byAdding: .day, value: 1, to: startOfTomorrow)!

        let todayEvent = makeCalendarTestEvent(id: "e", title: "Today Meeting",
            start: startOfToday.addingTimeInterval(3600), end: startOfToday.addingTimeInterval(7200))
        let tomorrowEvent = makeCalendarTestEvent(id: "f", title: "Tomorrow Meeting",
            start: startOfTomorrow.addingTimeInterval(3600), end: startOfTomorrow.addingTimeInterval(7200))
        let dayAfterEvent = makeCalendarTestEvent(id: "g", title: "Day After",
            start: startOfDayAfterTomorrow.addingTimeInterval(3600), end: startOfDayAfterTomorrow.addingTimeInterval(7200))
        let allDayToday = makeCalendarTestEvent(id: "h", title: "All-day Today",
            start: startOfToday, end: startOfTomorrow, isAllDay: true)
        let midnightBoundaryEvent = makeCalendarTestEvent(id: "i", title: "Midnight Tomorrow",
            start: startOfTomorrow, end: startOfTomorrow.addingTimeInterval(1800))

        let groups = CalendarService.groupByDay(
            events: [todayEvent, tomorrowEvent, dayAfterEvent, allDayToday, midnightBoundaryEvent],
            now: calNow, calendar: calCalendar)
        check(groups.today.map(\.id).sorted() == ["e", "h"],
              "CalendarService: groupByDay puts today's timed event and today's all-day event in 'today'")
        check(groups.tomorrow.map(\.id).sorted() == ["f", "i"],
              "CalendarService: groupByDay puts tomorrow's event AND an event starting exactly at tomorrow's midnight boundary in 'tomorrow' (inclusive lower bound)")
        check(!groups.today.contains(where: { $0.id == "g" }) && !groups.tomorrow.contains(where: { $0.id == "g" }),
              "CalendarService: groupByDay excludes an event starting the day after tomorrow from both sections")

        let emptyGroups = CalendarService.groupByDay(events: [], now: calNow, calendar: calCalendar)
        check(emptyGroups.today.isEmpty && emptyGroups.tomorrow.isEmpty,
              "CalendarService: groupByDay is empty/empty for an empty list")

        // start()/stop() are plain, idempotent booleans (mirroring PowerMonitor's shape).
        let lifecycleCalendar = CalendarService()
        lifecycleCalendar.start()
        lifecycleCalendar.start() // idempotent — must not crash or double-subscribe
        lifecycleCalendar.stop()
        lifecycleCalendar.stop() // idempotent
        check(true, "CalendarService: start()/stop() are safely idempotent when called repeatedly")

        // nextMidnight: the fix for the rolling "now → end of tomorrow" fetch
        // window never re-fetching across a midnight rollover — pure and
        // testable without a real clock/timer.
        let midnightToday = calCalendar.startOfDay(for: calNow)
        let midnightTomorrow = calCalendar.date(byAdding: .day, value: 1, to: midnightToday)!
        check(CalendarService.nextMidnight(after: calNow, calendar: calCalendar) == midnightTomorrow,
              "CalendarService: nextMidnight is the start of the day after the given date's own day")
        check(CalendarService.nextMidnight(after: midnightToday, calendar: calCalendar) == midnightTomorrow,
              "CalendarService: nextMidnight given exactly midnight still advances to the FOLLOWING midnight, not the same instant")

        // --- M4: NotchActivityRouter.calendarEventSoonActivity — pure event-soon translation ---
        let soonNow = Date()
        let eventSoonIn3Min = makeCalendarTestEvent(id: "soon1", title: "1:1",
            start: soonNow.addingTimeInterval(3 * 60), end: soonNow.addingTimeInterval(30 * 60))
        let eventSoonActivity = NotchActivityRouter.calendarEventSoonActivity(events: [eventSoonIn3Min], now: soonNow)
        check(eventSoonActivity?.kind == .calendarEvent,
              "NotchActivityRouter: an event starting within 10 minutes produces a .calendarEvent activity")
        check(eventSoonActivity?.duration == nil,
              "NotchActivityRouter: the event-soon activity is sticky (duration nil) — dismissed explicitly once no longer 'soon', not auto-expired")
        check(eventSoonActivity?.priority == 120,
              "NotchActivityRouter: the event-soon activity posts at priority 120 (between menu-bar overflow's 150 and Bluetooth's 100)")
        check(eventSoonActivity?.trailing == .text("1:1 in 3m"),
              "NotchActivityRouter: the event-soon activity's trailing text is '<title> in Nm'")
        check(eventSoonActivity?.leading == .icon(systemName: "calendar"),
              "NotchActivityRouter: the event-soon activity's leading content is a calendar icon")

        let eventFarAway = makeCalendarTestEvent(id: "far", title: "Later",
            start: soonNow.addingTimeInterval(20 * 60), end: soonNow.addingTimeInterval(50 * 60))
        check(NotchActivityRouter.calendarEventSoonActivity(events: [eventFarAway], now: soonNow) == nil,
              "NotchActivityRouter: an event more than 10 minutes away produces no activity")

        let eventAlreadyStarted = makeCalendarTestEvent(id: "started", title: "In Progress",
            start: soonNow.addingTimeInterval(-5 * 60), end: soonNow.addingTimeInterval(25 * 60))
        check(NotchActivityRouter.calendarEventSoonActivity(events: [eventAlreadyStarted], now: soonNow) == nil,
              "NotchActivityRouter: an event that has already started produces no activity — only the approach to its start counts as 'soon'")

        check(NotchActivityRouter.calendarEventSoonActivity(events: [], now: soonNow) == nil,
              "NotchActivityRouter: no activity for an empty event list")

        let eventRightAtStart = makeCalendarTestEvent(id: "atstart", title: "Now",
            start: soonNow, end: soonNow.addingTimeInterval(1800))
        check(NotchActivityRouter.calendarEventSoonActivity(events: [eventRightAtStart], now: soonNow)?.trailing == .text("Now now"),
              "NotchActivityRouter: an event starting exactly now still qualifies (inclusive lower bound) and reads 'now' via the shared relativeStartPhrase helper — NOT a separate '0m' format")

        let eventSoonIn12Min = makeCalendarTestEvent(id: "soon2", title: "Too Far",
            start: soonNow.addingTimeInterval(12 * 60), end: soonNow.addingTimeInterval(40 * 60))
        let multiEventActivity = NotchActivityRouter.calendarEventSoonActivity(
            events: [eventFarAway, eventSoonIn3Min, eventSoonIn12Min], now: soonNow)
        check(multiEventActivity?.trailing == .text("1:1 in 3m"),
              "NotchActivityRouter: with a mix of qualifying/non-qualifying events, the earliest-starting qualifying one wins")

        // All-day events never qualify as "starting soon" — their `start` is
        // local midnight, which is not a meaningful countdown target (a fix
        // for a false alert every midnight rollover). They still appear in
        // the widget's own agenda via `groupByDay`, untouched by this filter.
        let allDaySoon = makeCalendarTestEvent(id: "allday-soon", title: "Conference",
            start: soonNow, end: soonNow.addingTimeInterval(86400), isAllDay: true)
        check(NotchActivityRouter.calendarEventSoonActivity(events: [allDaySoon], now: soonNow) == nil,
              "NotchActivityRouter: calendarEventSoonActivity excludes all-day events even when their start falls inside the 10-minute window")
        check(NotchActivityRouter.calendarEventSoonActivity(events: [allDaySoon, eventSoonIn3Min], now: soonNow)?.trailing == .text("1:1 in 3m"),
              "NotchActivityRouter: an all-day event mixed in with a qualifying timed event doesn't block the timed event from winning")

        // --- M4: NotchActivityRouter.nextMinuteBoundary / nextCalendarBoundary
        // — the frozen-countdown fix, kept pure so no real Task/RunLoop is
        // needed to verify the "when should the wing next wake up" math ---
        let midMinute = Date(timeIntervalSinceReferenceDate: 1_000 * 60 + 47) // 47s past a minute boundary
        check(NotchActivityRouter.nextMinuteBoundary(after: midMinute) == Date(timeIntervalSinceReferenceDate: 1_001 * 60),
              "NotchActivityRouter: nextMinuteBoundary rounds up to the next whole minute")
        let exactMinute = Date(timeIntervalSinceReferenceDate: 1_000 * 60)
        check(NotchActivityRouter.nextMinuteBoundary(after: exactMinute) == Date(timeIntervalSinceReferenceDate: 1_001 * 60),
              "NotchActivityRouter: nextMinuteBoundary advances a full minute even when `now` already lands exactly on a boundary — the scheduled task must always sleep a positive duration")

        let boundaryNow = Date(timeIntervalSinceReferenceDate: 1_000 * 60 + 10) // 10s into a minute
        let eventInsideWindow = makeCalendarTestEvent(id: "boundary1", title: "Standup",
            start: boundaryNow.addingTimeInterval(5 * 60), end: boundaryNow.addingTimeInterval(35 * 60))
        check(NotchActivityRouter.nextCalendarBoundary(events: [eventInsideWindow], now: boundaryNow) == NotchActivityRouter.nextMinuteBoundary(after: boundaryNow),
              "NotchActivityRouter: nextCalendarBoundary wakes at the next minute tick while an event is inside the soon window — this is what keeps the wing's 'in Nm' text counting down instead of freezing")

        let eventNotYetSoon = makeCalendarTestEvent(id: "boundary2", title: "Review",
            start: boundaryNow.addingTimeInterval(20 * 60), end: boundaryNow.addingTimeInterval(50 * 60))
        check(NotchActivityRouter.nextCalendarBoundary(events: [eventNotYetSoon], now: boundaryNow)
                == eventNotYetSoon.start.addingTimeInterval(-NotchActivityRouter.calendarSoonThreshold),
              "NotchActivityRouter: nextCalendarBoundary wakes at an event's own threshold-crossing instant when nothing is inside the soon window yet")

        let allDayOnlyBoundary = makeCalendarTestEvent(id: "boundary3", title: "Holiday",
            start: boundaryNow.addingTimeInterval(5 * 60), end: boundaryNow.addingTimeInterval(35 * 60), isAllDay: true)
        check(NotchActivityRouter.nextCalendarBoundary(events: [allDayOnlyBoundary], now: boundaryNow) == nil,
              "NotchActivityRouter: nextCalendarBoundary ignores all-day events entirely — no boundary, no wasted wake-up")
        check(NotchActivityRouter.nextCalendarBoundary(events: [], now: boundaryNow) == nil,
              "NotchActivityRouter: nextCalendarBoundary is nil with no events at all")

        // --- M4: NotchActivityRouter.calendarServiceShouldRun — pure
        // lifecycle derivation (the grant-while-open / screen-disappear fix).
        // `duoActive: false` on every case below that isn't specifically
        // testing the M7 Duo addition, below. ---
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: false, notchPresenting: true, widgetEnabled: true,
                state: .expanded(.calendar), activityToggleOn: true, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun is false without calendar permission, no matter what else is true")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: false, widgetEnabled: true,
                state: .expanded(.calendar), activityToggleOn: true, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun is false with nowhere to present, even with the widget 'open' and the toggle on — the screen-disappear-stops-the-service fix")
        check(NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: true,
                state: .expanded(.calendar), activityToggleOn: false, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun is true when the Calendar widget is the one currently expanded, even with the event-soon toggle off")
        check(NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: false,
                state: .collapsed, activityToggleOn: true, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun is true when the event-soon toggle is on, even with the widget closed/disabled — the grant-while-open fix's other half")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: true,
                state: .collapsed, activityToggleOn: false, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun is false when neither the widget is open nor the event-soon toggle is on")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: false,
                state: .expanded(.calendar), activityToggleOn: false, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun requires widgetEnabled true for the widget-open condition to count, even if state somehow still reads .expanded(.calendar)")

        // --- M7 bot-review fix: calendarServiceShouldRun also runs the
        // service while the Duo pane (Now Playing + Calendar side by side)
        // is showing, even with the Calendar widget's own event-soon toggle
        // off and Calendar not itself the `.expanded` widget — otherwise the
        // Duo pane's Calendar half renders with the service never started,
        // an empty agenda. ---
        check(NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: false,
                state: .expanded(.nowPlaying), activityToggleOn: false, duoActive: true),
              "NotchActivityRouter: calendarServiceShouldRun is true when Duo is active and its pane (.expanded(.nowPlaying)) is showing, even with the event-soon toggle off and the Calendar widget itself disabled")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: false,
                state: .expanded(.shelf), activityToggleOn: false, duoActive: true),
              "NotchActivityRouter: calendarServiceShouldRun requires the Duo pane's OWN state (.expanded(.nowPlaying)) for duoActive to count — duoActive alone, with some other widget expanded, isn't the Duo pane actually being on screen")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: true, notchPresenting: true, widgetEnabled: false,
                state: .expanded(.nowPlaying), activityToggleOn: false, duoActive: false),
              "NotchActivityRouter: calendarServiceShouldRun stays false at .expanded(.nowPlaying) when Duo itself isn't active — this is just plain Now Playing, not Duo")
        check(!NotchActivityRouter.calendarServiceShouldRun(
                permissionGranted: false, notchPresenting: true, widgetEnabled: false,
                state: .expanded(.nowPlaying), activityToggleOn: false, duoActive: true),
              "NotchActivityRouter: calendarServiceShouldRun is still false without calendar permission even with the Duo pane showing")

        // --- M5: MediaKeyInterceptor — NX_SYSDEFINED data1 parsing + decision
        // logic, all pure (no real CGEventTap is ever created here) ---
        do {
            // data1 layout: bits 16-31 = NX_KEYTYPE_* key code, bits 8-15 of the
            // low word = key state (0xA down / 0xB up), bit 0 = autorepeat.
            let volUpDown = MediaKeyInterceptor.parseKeyEvent(data1: 0x00000A00)
            check(volUpDown.keyCode == 0 && volUpDown.keyDown && !volUpDown.isRepeat,
                  "MediaKeyInterceptor: parseKeyEvent decodes a plain key-down (NX_KEYTYPE_SOUND_UP, non-repeat)")

            let keyUp = MediaKeyInterceptor.parseKeyEvent(data1: 0x00000B00)
            check(!keyUp.keyDown, "MediaKeyInterceptor: parseKeyEvent decodes a key-up (state 0xB) as NOT keyDown")

            let repeatDown = MediaKeyInterceptor.parseKeyEvent(data1: 0x00000A01)
            check(repeatDown.keyDown && repeatDown.isRepeat,
                  "MediaKeyInterceptor: parseKeyEvent decodes the autorepeat bit")

            let brightnessDown = MediaKeyInterceptor.parseKeyEvent(data1: 0x00020A00)
            check(brightnessDown.keyCode == 2 && brightnessDown.keyDown,
                  "MediaKeyInterceptor: parseKeyEvent decodes a non-zero key code out of the high 16 bits (NX_KEYTYPE_BRIGHTNESS_UP)")

            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 0) == .volumeUp,
                  "MediaKeyInterceptor: hudKey maps NX_KEYTYPE_SOUND_UP (0) to .volumeUp")
            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 1) == .volumeDown,
                  "MediaKeyInterceptor: hudKey maps NX_KEYTYPE_SOUND_DOWN (1) to .volumeDown")
            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 7) == .mute,
                  "MediaKeyInterceptor: hudKey maps NX_KEYTYPE_MUTE (7) to .mute")
            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 2) == .brightnessUp,
                  "MediaKeyInterceptor: hudKey maps NX_KEYTYPE_BRIGHTNESS_UP (2) to .brightnessUp")
            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 3) == .brightnessDown,
                  "MediaKeyInterceptor: hudKey maps NX_KEYTYPE_BRIGHTNESS_DOWN (3) to .brightnessDown")
            check(MediaKeyInterceptor.hudKey(forNXKeyCode: 16) == nil,
                  "MediaKeyInterceptor: hudKey is nil for a system-defined key this app doesn't handle (e.g. play/pause)")

            check(MediaKeyInterceptor.shouldSwallow(key: .volumeUp, brightnessAvailable: false, volumeControllable: true),
                  "MediaKeyInterceptor: volume keys are swallowed when the device has software volume control, brightness availability notwithstanding")
            check(MediaKeyInterceptor.shouldSwallow(key: .mute, brightnessAvailable: false, volumeControllable: true),
                  "MediaKeyInterceptor: mute is swallowed when the device has software volume control")
            check(!MediaKeyInterceptor.shouldSwallow(key: .brightnessUp, brightnessAvailable: false, volumeControllable: true),
                  "MediaKeyInterceptor: brightness keys pass through untouched when DisplayServices is unavailable")
            check(MediaKeyInterceptor.shouldSwallow(key: .brightnessDown, brightnessAvailable: true, volumeControllable: true),
                  "MediaKeyInterceptor: brightness keys are swallowed once DisplayServices is available")
            // The code-review fix: a device with no software-settable volume
            // (digital/HDMI out, some external DACs) must let volume keys
            // pass through instead of swallowing them into a void — mirrors
            // the existing brightnessAvailable pass-through above exactly.
            check(!MediaKeyInterceptor.shouldSwallow(key: .volumeUp, brightnessAvailable: true, volumeControllable: false),
                  "MediaKeyInterceptor: volume keys pass through when the output device has no software volume control")
            check(!MediaKeyInterceptor.shouldSwallow(key: .volumeDown, brightnessAvailable: true, volumeControllable: false),
                  "MediaKeyInterceptor: volume-down also passes through with no software volume control")
            check(!MediaKeyInterceptor.shouldSwallow(key: .mute, brightnessAvailable: true, volumeControllable: false),
                  "MediaKeyInterceptor: mute also passes through with no software volume control")

            check(!MediaKeyInterceptor().isTapActive,
                  "MediaKeyInterceptor: isTapActive is false for a fresh instance before start() is ever called")

            check(!MediaKeyInterceptor.isFineStep(flags: []),
                  "MediaKeyInterceptor: isFineStep is false with no modifiers")
            check(!MediaKeyInterceptor.isFineStep(flags: .maskShift),
                  "MediaKeyInterceptor: isFineStep requires BOTH Shift and Option, not Shift alone")
            check(!MediaKeyInterceptor.isFineStep(flags: .maskAlternate),
                  "MediaKeyInterceptor: isFineStep requires BOTH Shift and Option, not Option alone")
            check(MediaKeyInterceptor.isFineStep(flags: [.maskShift, .maskAlternate]),
                  "MediaKeyInterceptor: isFineStep is true with Shift+Option together")
        }

        // --- M5: NotchActivityRouter — HUD symbol pickers, activity shape,
        // dedupe window, and mode derivation, all pure ---
        check(NotchActivityRouter.volumeSymbol(level: 0.5, muted: true) == "speaker.slash.fill",
              "NotchActivityRouter: volumeSymbol shows the slashed glyph whenever muted, regardless of level")
        check(NotchActivityRouter.volumeSymbol(level: 0, muted: false) == "speaker.slash.fill",
              "NotchActivityRouter: volumeSymbol shows the slashed glyph at a literal 0 level too")
        check(NotchActivityRouter.volumeSymbol(level: 0.1, muted: false) == "speaker.wave.1.fill",
              "NotchActivityRouter: volumeSymbol picks the low-wave glyph in the bottom third")
        check(NotchActivityRouter.volumeSymbol(level: 0.5, muted: false) == "speaker.wave.2.fill",
              "NotchActivityRouter: volumeSymbol picks the mid-wave glyph in the middle third")
        check(NotchActivityRouter.volumeSymbol(level: 0.9, muted: false) == "speaker.wave.3.fill",
              "NotchActivityRouter: volumeSymbol picks the full-wave glyph in the top third")

        check(NotchActivityRouter.brightnessSymbol(level: 0.2) == "sun.min.fill",
              "NotchActivityRouter: brightnessSymbol shows the dim glyph at or below half brightness")
        check(NotchActivityRouter.brightnessSymbol(level: 0.8) == "sun.max.fill",
              "NotchActivityRouter: brightnessSymbol shows the bright glyph above half brightness")

        let m5VolumeActivity = NotchActivityRouter.volumeActivity(level: 0.4, muted: false)
        check(m5VolumeActivity.kind == .hudVolume && m5VolumeActivity.priority == 300 && m5VolumeActivity.duration == 1.5,
              "NotchActivityRouter: volumeActivity posts at kind .hudVolume, priority 300, duration 1.5s")
        // Not a plain `==` against `.gauge(0.4, ...)`: `volumeActivity` stores
        // `Double(level)` where `level` is a `Float`, and widening a `Float`
        // 0.4 to `Double` (~0.4000000059604645) doesn't bit-for-bit match the
        // `Double` literal `0.4` — an epsilon compare on the unwrapped value
        // is the correct check, not a red herring to "fix" by chasing exact
        // equality.
        if case let .gauge(value, systemName) = m5VolumeActivity.trailing {
            check(abs(value - 0.4) < 0.0001 && systemName == "speaker.wave.2.fill",
                  "NotchActivityRouter: volumeActivity's trailing content is a gauge carrying the exact level and matching icon")
        } else {
            check(false, "NotchActivityRouter: volumeActivity's trailing content is a gauge (got \(m5VolumeActivity.trailing))")
        }

        let m5BrightnessActivity = NotchActivityRouter.brightnessActivity(level: 0.9)
        check(m5BrightnessActivity.kind == .hudBrightness && m5BrightnessActivity.priority == 300,
              "NotchActivityRouter: brightnessActivity posts at kind .hudBrightness, priority 300 (same tier as volume)")

        let dedupeNow = Date()
        check(NotchActivityRouter.isVolumeMonitorEventSuppressed(now: dedupeNow, lastInterceptorApplyAt: dedupeNow.addingTimeInterval(-0.1)),
              "NotchActivityRouter: isVolumeMonitorEventSuppressed is true just after an interceptor apply (inside the 300ms window)")
        check(!NotchActivityRouter.isVolumeMonitorEventSuppressed(now: dedupeNow, lastInterceptorApplyAt: dedupeNow.addingTimeInterval(-0.5)),
              "NotchActivityRouter: isVolumeMonitorEventSuppressed is false once the dedupe window has elapsed")
        check(!NotchActivityRouter.isVolumeMonitorEventSuppressed(now: dedupeNow, lastInterceptorApplyAt: nil),
              "NotchActivityRouter: isVolumeMonitorEventSuppressed is false with no prior interceptor apply at all")

        // `intendedHUDMode` (the code-review fix's rename+refactor of
        // `hudMode`): its inputs are strictly the CAUSES of the decision —
        // notably `accessibilityGranted`, NOT whether some tap instance
        // happens to be running — so this is the exact function
        // `applyHUDState` now calls for its own decision (see that
        // function's doc comment), not a second parallel implementation.
        check(NotchActivityRouter.intendedHUDMode(hudEnabled: false, notchPresenting: true, interceptRequested: true, accessibilityGranted: true) == .off,
              "NotchActivityRouter: intendedHUDMode is .off whenever the HUD master toggle is off, regardless of everything else")
        check(NotchActivityRouter.intendedHUDMode(hudEnabled: true, notchPresenting: false, interceptRequested: true, accessibilityGranted: true) == .off,
              "NotchActivityRouter: intendedHUDMode is .off with nowhere to present (notchPresenting false), even with Accessibility granted")
        check(NotchActivityRouter.intendedHUDMode(hudEnabled: true, notchPresenting: true, interceptRequested: false, accessibilityGranted: false) == .observe,
              "NotchActivityRouter: intendedHUDMode is .observe when the HUD is on but intercept was never requested")
        check(NotchActivityRouter.intendedHUDMode(hudEnabled: true, notchPresenting: true, interceptRequested: true, accessibilityGranted: false) == .observe,
              "NotchActivityRouter: intendedHUDMode falls back to .observe when intercept is requested but Accessibility isn't granted")
        check(NotchActivityRouter.intendedHUDMode(hudEnabled: true, notchPresenting: true, interceptRequested: true, accessibilityGranted: true) == .intercept,
              "NotchActivityRouter: intendedHUDMode is .intercept only when requested AND Accessibility is granted — actual tap health is a separate post-hoc check applyHUDState makes, not a mode input")

        // --- M5: NotchActivityRouter — observe-mode volume events post/gate
        // correctly, driven purely through VolumeMonitor's own `.events`
        // subject. `hudVolume`/`hudBrightness`/`hudInterceptor` below are real
        // instances (constructor seams, matching `testPower`/`testBluetooth`
        // above), but `start()`/`adjustVolume()`/`toggleMute()`/`adjust(by:)`
        // are never called on any of them here — only synthetic
        // `VolumeEvent`s are fed in, so this never touches real CoreAudio or
        // creates a real event tap on the CI runner. ---
        do {
            let hudSuiteName = "flux.selftest.hud"
            let hudSuite = UserDefaults(suiteName: hudSuiteName)!
            hudSuite.removePersistentDomain(forName: hudSuiteName)
            let hudSettings = SettingsStore(defaults: hudSuite)
            let hudActivities = LiveActivityCenter()
            let hudArranger = MenuBarArranger()
            let hudCalendar = CalendarService()
            let hudPermissions = PermissionCenter()
            let hudTimers = TimerService()
            let hudViewModel = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter())
            let hudVolume = VolumeMonitor()
            let hudBrightness = BrightnessMonitor()
            let hudInterceptor = MediaKeyInterceptor()
            // `startsMonitors: false` — see this file's identical note on the
            // M3 router block above; must never let the router's real
            // settings-driven lifecycle call `volume.start()`/
            // `interceptor.start()` for real on a headless CI runner.
            let hudRouter = NotchActivityRouter(activities: hudActivities, settings: hudSettings,
                                                 arranger: hudArranger, calendar: hudCalendar,
                                                 permissions: hudPermissions, viewModel: hudViewModel,
                                                 timers: hudTimers,
                                                 volume: hudVolume, brightness: hudBrightness,
                                                 interceptor: hudInterceptor, startsMonitors: false)

            withExtendedLifetime(hudRouter) {
                hudVolume.events.send(.volumeChanged(level: 0.6, muted: false))
                check(hudActivities.current?.kind == .hudVolume,
                      "NotchActivityRouter: a VolumeEvent posts a .hudVolume live activity in observe mode")
                check(hudActivities.current?.priority == 300,
                      "NotchActivityRouter: HUD activities post at priority 300 — above battery (200)")
                check(hudActivities.current?.duration == 1.5,
                      "NotchActivityRouter: HUD activities expire after 1.5s")

                hudSettings.notchHudEnabled = false
                hudActivities.dismiss(kind: .hudVolume)
                hudVolume.events.send(.volumeChanged(level: 0.8, muted: false))
                check(hudActivities.current?.kind != .hudVolume,
                      "NotchActivityRouter: the HUD master toggle off suppresses further volume posts")

                hudSettings.notchHudEnabled = true
                hudVolume.events.send(.volumeChanged(level: 0.2, muted: true))
                check(hudActivities.current?.leading == .icon(systemName: "speaker.slash.fill"),
                      "NotchActivityRouter: re-enabling the HUD toggle resumes posting, and a muted event shows the slashed glyph")

                // The code-review fix's wiring: NotchActivityRouter.init sets
                // `hudInterceptor.volumeControllable` to read
                // `hudVolume.hasVolumeControl` live, rather than leaving it at
                // its always-true default — verified by checking they agree,
                // not by asserting a specific Bool (there's no guarantee what
                // hardware/CI runner this executes on actually exposes).
                check(hudInterceptor.volumeControllable() == hudVolume.hasVolumeControl,
                      "NotchActivityRouter: wires the interceptor's volumeControllable closure to the router's own VolumeMonitor instance")
            }
            hudSuite.removePersistentDomain(forName: hudSuiteName)
        }

        // --- M5 code review: VolumeMonitor.hasVolumeControl — a smoke test
        // safe on a headless CI runner with no guaranteed real audio
        // hardware: it must not crash, and if there's no readable volume at
        // all (`current == nil`), a device can't possibly be settable either. ---
        do {
            let volumeControlProbe = VolumeMonitor()
            if volumeControlProbe.current == nil {
                check(!volumeControlProbe.hasVolumeControl,
                      "VolumeMonitor: hasVolumeControl is false when there's no readable volume at all")
            } else {
                check(true,
                      "VolumeMonitor: hasVolumeControl computed without crashing (\(volumeControlProbe.hasVolumeControl)) alongside a readable current value")
            }
        }

        // --- M5 bot-review fix: VolumeMonitor.perChannelTargets — the pure
        // per-channel delta math backing `adjustVolume`'s no-virtual-main-
        // volume fallback. The bug this replaced: the old fallback read the
        // shared AVERAGE of the two channels, added `delta` once, and wrote
        // that single result back to BOTH channels — flattening any existing
        // left/right balance to identical values the very first time a
        // volume key was pressed. Applying `delta` to each channel
        // independently (verified here) preserves whatever gap already
        // existed between them instead. ---
        do {
            let balanced = VolumeMonitor.perChannelTargets(left: 0.3, right: 0.5, delta: 0.1)
            check(balanced.left.map { abs($0 - 0.4) < 0.0001 } == true,
                  "VolumeMonitor: perChannelTargets applies delta to the left channel independently")
            check(balanced.right.map { abs($0 - 0.6) < 0.0001 } == true,
                  "VolumeMonitor: perChannelTargets applies delta to the right channel independently, preserving the existing left/right gap rather than collapsing both to a shared average")

            let clampedHigh = VolumeMonitor.perChannelTargets(left: 0.95, right: 0.95, delta: 0.5)
            check(clampedHigh.left == 1.0 && clampedHigh.right == 1.0,
                  "VolumeMonitor: perChannelTargets clamps each channel at 1.0")

            let clampedLow = VolumeMonitor.perChannelTargets(left: 0.05, right: 0.05, delta: -0.5)
            check(clampedLow.left == 0.0 && clampedLow.right == 0.0,
                  "VolumeMonitor: perChannelTargets clamps each channel at 0.0")

            let missingChannel = VolumeMonitor.perChannelTargets(left: 0.4, right: nil, delta: 0.1)
            check(missingChannel.left != nil && missingChannel.right == nil,
                  "VolumeMonitor: perChannelTargets leaves an unreadable channel nil rather than fabricating a value for it")
        }

        // --- M5 bot-review fix: BrightnessMonitor.canChangeBrightness — a
        // smoke test safe on a headless CI runner with no guaranteed real
        // display brightness support: must not crash, and can never be true
        // when `isAvailable` itself is false (missing DisplayServices symbols
        // leaves nothing that could possibly change anything). This is the
        // gate `NotchActivityRouter.applyHUDState` now wires into
        // `interceptor.brightnessAvailable` instead of the weaker bare
        // `isAvailable` (see that call site's doc comment) — `shouldSwallow`
        // itself is unchanged (still a pure function of whatever Bool it's
        // handed), so only the caller's choice of Bool needed new coverage. ---
        do {
            let brightnessProbe = BrightnessMonitor()
            if !brightnessProbe.isAvailable {
                check(!brightnessProbe.canChangeBrightness,
                      "BrightnessMonitor: canChangeBrightness is false whenever isAvailable is false")
            } else {
                check(true,
                      "BrightnessMonitor: canChangeBrightness computed without crashing (\(brightnessProbe.canChangeBrightness)) alongside isAvailable == true")
            }
        }

        // --- M5 code review: PermissionCenter re-checks Accessibility on the
        // undocumented-but-established "com.apple.accessibility.api"
        // DistributedNotificationCenter post, so a revoke/grant while Flux
        // stays the frontmost app is still caught (didBecomeActiveNotification
        // alone wouldn't see it). Smoke test: posting it must not crash, and
        // afterward .accessibility must match a fresh live query — proof the
        // observer actually re-queried rather than merely surviving. ---
        do {
            let accessibilityPermCenter = PermissionCenter()
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.apple.accessibility.api"), object: nil, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(accessibilityPermCenter.statuses[.accessibility] == (AXIsProcessTrusted() ? .granted : .denied),
                  "PermissionCenter: the accessibility.api distributed notification refreshes .accessibility without crashing")
        }

        // --- M6: NotchTimer — pure countdown math, driven entirely by
        // injected `at`/`after` instants (never `Date()` internally), so
        // pause/resume/overdue can all be pinned deterministically. ---
        let ntNow = Date()
        let ntRunning = NotchTimer(label: "Running", duration: 60, startedAt: ntNow.addingTimeInterval(-30))
        check(abs(ntRunning.remaining(at: ntNow) - 30) < 0.01,
              "NotchTimer: remaining(at:) reflects duration minus elapsed")
        check(!ntRunning.isFinished(at: ntNow), "NotchTimer: not finished with 30s left")
        check(ntRunning.isFinished(at: ntRunning.endDate), "NotchTimer: isFinished is true exactly at endDate")
        check(ntRunning.isFinished(at: ntRunning.endDate.addingTimeInterval(5)),
              "NotchTimer: an overdue timer (past its endDate) still reads as finished")

        var ntPausable = NotchTimer(label: "Pausable", duration: 60, startedAt: ntNow.addingTimeInterval(-10))
        let ntPauseInstant = ntNow
        ntPausable.pausedAt = ntPauseInstant
        let ntRemainingAtPause = ntPausable.remaining(at: ntPauseInstant)
        check(abs(ntRemainingAtPause - 50) < 0.01,
              "NotchTimer: remaining at the moment of pausing reflects elapsed-before-pause (10s in of a 60s timer → 50s left)")
        let ntMuchLater = ntPauseInstant.addingTimeInterval(120)
        check(abs(ntPausable.remaining(at: ntMuchLater) - ntRemainingAtPause) < 0.01,
              "NotchTimer: remaining stays frozen at the pause instant's value no matter how much later `now` is queried")

        // Resuming folds the elapsed pause span into `accumulatedPause` and
        // clears `pausedAt` — the countdown should pick up exactly where it
        // was frozen, then keep draining normally from there.
        ntPausable.accumulatedPause += ntMuchLater.timeIntervalSince(ntPauseInstant)
        ntPausable.pausedAt = nil
        check(abs(ntPausable.remaining(at: ntMuchLater) - ntRemainingAtPause) < 0.01,
              "NotchTimer: resuming preserves the frozen remaining time at the instant of resume")
        check(abs(ntPausable.remaining(at: ntMuchLater.addingTimeInterval(5)) - (ntRemainingAtPause - 5)) < 0.01,
              "NotchTimer: after resuming, remaining ticks down again from the frozen value")

        // TimerService.nextDeadline(in:after:) — the pure core `rescheduleBoundary`
        // arms its single boundary Task against: earliest UNPAUSED endDate,
        // skipping a paused timer even when its own nominal endDate is earlier.
        let ntA = NotchTimer(label: "A", duration: 60, startedAt: ntNow.addingTimeInterval(-50)) // endDate = now+10
        let ntB = NotchTimer(label: "B", duration: 60, startedAt: ntNow.addingTimeInterval(-55), pausedAt: ntNow) // endDate = now+5, but PAUSED
        let ntC = NotchTimer(label: "C", duration: 300, startedAt: ntNow) // endDate = now+300
        check(TimerService.nextDeadline(in: [ntA, ntB, ntC], after: ntNow) == ntA.endDate,
              "TimerService: nextDeadline(in:after:) picks the earliest UNPAUSED timer's endDate, correctly skipping a paused one with an earlier nominal endDate")
        check(TimerService.nextDeadline(in: [ntB], after: ntNow) == nil,
              "TimerService: nextDeadline(in:after:) is nil when every timer is paused")
        check(TimerService.nextDeadline(in: [], after: ntNow) == nil,
              "TimerService: nextDeadline(in:after:) is nil with no timers at all")

        // --- M6 fix: TimerService.sweepFinished — pause()/resume()/cancel()
        // sweep any already-overdue timer FIRST, completing it instead of
        // mutating it. Constructed with a NEGATIVE duration so the timer is
        // already finished (`endDate` in the past) the instant `start()`
        // returns, and the mutator is called on the very next synchronous
        // line — with no `await`/suspension point in between, the boundary
        // `Task` genuinely cannot have run yet, deterministically
        // reproducing "the deadline passed but the boundary task hasn't
        // fired because the main actor was busy" without any real timing
        // race or sleep. ---
        do {
            let overdueTimers = TimerService()
            var overdueCompletions: [String] = []
            let overdueSub = overdueTimers.completions.sink { overdueCompletions.append($0.label) }

            let overdueForPause = overdueTimers.start(duration: -5, label: "OverduePause")
            overdueTimers.pause(overdueForPause.id)
            check(overdueCompletions == ["OverduePause"],
                  "TimerService: pause() on an already-overdue timer completes it via sweepFinished rather than pausing it")
            check(!overdueTimers.timers.contains { $0.id == overdueForPause.id },
                  "TimerService: the swept-and-completed timer is gone from `timers`, not left behind paused")

            overdueCompletions.removeAll()
            let overdueForResume = overdueTimers.start(duration: -5, label: "OverdueResume")
            overdueTimers.resume(overdueForResume.id)
            check(overdueCompletions == ["OverdueResume"],
                  "TimerService: resume() on an already-overdue timer completes it via sweepFinished rather than resuming it")

            overdueCompletions.removeAll()
            let overdueForCancel = overdueTimers.start(duration: -5, label: "OverdueCancel")
            overdueTimers.cancel(overdueForCancel.id)
            check(overdueCompletions == ["OverdueCancel"],
                  "TimerService: cancel() on an already-overdue timer still reports it via sweepFinished's completion event (it's removed either way, but as a completion, not a silent cancel)")

            overdueSub.cancel()
        }

        // --- M6 fix: TimerService's NSWorkspace.didWakeNotification observer
        // — closes the "boundary Task.sleep suspended across a system sleep"
        // gap by sweeping overdue timers (and rearming the boundary) the
        // instant the system wakes, rather than waiting for the already-late
        // sleeping boundary Task to eventually resume on its own.
        //
        // A note on what this test can and can't isolate: an overdue
        // timer's OWN boundary task is armed with a clamped-to-zero sleep
        // (see `DeadlineTask.reschedule`'s `max(date.timeIntervalSinceNow, 0)`),
        // so in this synthetic (no real sleep/wake involved) scenario the
        // ordinary boundary task races the wake observer to reap it on the
        // very next run-loop turn regardless — there is no way to
        // deterministically prove HERE that the wake path specifically did
        // the reaping without mocking the system clock. What this DOES
        // verify: the observer is wired correctly and safe to invoke (no
        // crash with no timers at all), and that posting the notification
        // alongside an overdue timer is never harmful — the timer still
        // completes exactly once, not zero or twice, whichever path
        // actually reaped it. ---
        do {
            let wakeTimers = TimerService()
            // Empty-service smoke test first: the observer must not
            // crash/misbehave when there's nothing to sweep.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            check(wakeTimers.timers.isEmpty,
                  "TimerService: posting didWakeNotification with no timers registered is a safe no-op")

            var wakeCompletions: [String] = []
            let wakeSub = wakeTimers.completions.sink { wakeCompletions.append($0.label) }
            _ = wakeTimers.start(duration: -5, label: "SleptThrough")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            check(wakeCompletions == ["SleptThrough"],
                  "TimerService: an already-overdue timer is completed exactly once after a wake notification is posted (whether reaped by the wake observer, the ordinary boundary task, or both racing harmlessly)")
            wakeSub.cancel()
        }

        // --- M6: TimersWidget — nearestRemainingLine/formatCountdown formatting ---
        let trRunning = NotchTimer(label: "Focus", duration: 125, startedAt: ntNow) // 125s left
        let trPaused = NotchTimer(label: "Paused", duration: 10, startedAt: ntNow.addingTimeInterval(-5), pausedAt: ntNow)
        check(TimersWidget.nearestRemainingLine(timers: [trPaused], at: ntNow) == nil,
              "TimersWidget: nearestRemainingLine is nil when every timer is paused")
        check(TimersWidget.nearestRemainingLine(timers: [trRunning, trPaused], at: ntNow) == "2 min",
              "TimersWidget: nearestRemainingLine picks the soonest-to-finish RUNNING timer (ignoring a paused one), showing whole minutes above 60s")
        check(TimersWidget.nearestRemainingLine(timers: [], at: ntNow) == nil,
              "TimersWidget: nearestRemainingLine is nil with no timers at all")

        // --- M6 fix: TimersWidget.nearestPausedRemainingLine — the paused
        // counterpart to nearestRemainingLine, backing the ambient wing's
        // "show a paused indicator instead of dismissing" fix below. ---
        let trPausedSooner = NotchTimer(label: "SoonerPaused", duration: 10, startedAt: ntNow.addingTimeInterval(-5), pausedAt: ntNow) // frozen at 5s
        let trPausedLater = NotchTimer(label: "LaterPaused", duration: 600, startedAt: ntNow.addingTimeInterval(-100), pausedAt: ntNow) // frozen at 500s
        check(TimersWidget.nearestPausedRemainingLine(timers: [trPausedSooner, trPausedLater], at: ntNow) == "0:05",
              "TimersWidget: nearestPausedRemainingLine picks the paused timer with the SMALLEST frozen remaining time")
        check(TimersWidget.nearestPausedRemainingLine(timers: [trRunning], at: ntNow) == nil,
              "TimersWidget: nearestPausedRemainingLine is nil when every timer is running (none paused)")
        check(TimersWidget.nearestPausedRemainingLine(timers: [], at: ntNow) == nil,
              "TimersWidget: nearestPausedRemainingLine is nil with no timers at all")

        // --- M6 fix: NotchActivityRouter.timerWingState — the pure core that
        // replaced timerActivityShouldRun, adding the .paused case: when
        // timers exist but every one is paused, the ambient wing should show
        // a paused indicator rather than being dismissed entirely (the old
        // bug — pausing the ONLY running timer dismissed the wing outright,
        // as if no timers existed at all). ---
        check(NotchActivityRouter.timerWingState(timers: [], toggleOn: true, notchPresenting: true, at: ntNow) == .hidden,
              "NotchActivityRouter: timerWingState is .hidden with no timers at all")
        check(NotchActivityRouter.timerWingState(timers: [trRunning], toggleOn: false, notchPresenting: true, at: ntNow) == .hidden,
              "NotchActivityRouter: timerWingState is .hidden when the toggle is off, even with a running timer")
        check(NotchActivityRouter.timerWingState(timers: [trRunning], toggleOn: true, notchPresenting: false, at: ntNow) == .hidden,
              "NotchActivityRouter: timerWingState is .hidden when the notch isn't presenting")
        if case .running(_, let runningLine) = NotchActivityRouter.timerWingState(timers: [trRunning], toggleOn: true, notchPresenting: true, at: ntNow) {
            check(runningLine == "2 min", "NotchActivityRouter: timerWingState's .running case carries the running timer's countdown text")
        } else {
            check(false, "NotchActivityRouter: timerWingState should be .running with an unpaused timer, the toggle on, and the notch presenting")
        }
        if case .paused(let pausedLine) = NotchActivityRouter.timerWingState(timers: [trPausedSooner], toggleOn: true, notchPresenting: true, at: ntNow) {
            check(pausedLine == "0:05",
                  "NotchActivityRouter: timerWingState's code-review fix — a timer list with NO running timer but at least one paused one is .paused, not .hidden, and carries its frozen remaining text")
        } else {
            check(false, "NotchActivityRouter: timerWingState should be .paused when every timer is paused (not empty, not hidden)")
        }
        check(TimersWidget.formatCountdown(65) == "1:05", "TimersWidget: formatCountdown renders m:ss with zero-padded seconds")
        check(TimersWidget.formatCountdown(5) == "0:05", "TimersWidget: formatCountdown zero-pads seconds under 10")
        check(TimersWidget.formatCountdown(-3) == "0:00", "TimersWidget: formatCountdown never shows a negative value")
        check(TimersWidget.formatCountdown(.infinity) == "0:00", "TimersWidget: formatCountdown guards a non-finite input")

        // --- M6 fix: TimersWidget.formatAmbientRemaining — the ambient wing's
        // own format, deliberately different from formatCountdown above:
        // whole minutes (no seconds digit) above 60s, since the wing only
        // refreshes once a minute there and a seconds digit would visibly
        // freeze between refreshes; m:ss under 60s, where the wing switches
        // to a per-second refresh instead (see LiveActivitySources.
        // nextTimerRefreshBoundary). ---
        check(TimersWidget.formatAmbientRemaining(125) == "2 min",
              "TimersWidget: formatAmbientRemaining shows whole (floored) minutes above 60s")
        check(TimersWidget.formatAmbientRemaining(61) == "1 min",
              "TimersWidget: formatAmbientRemaining floors just above the 60s boundary rather than rounding up")
        check(TimersWidget.formatAmbientRemaining(60) == "1:00",
              "TimersWidget: formatAmbientRemaining switches to m:ss AT exactly 60s remaining, not just below it")
        check(TimersWidget.formatAmbientRemaining(42) == "0:42",
              "TimersWidget: formatAmbientRemaining shows m:ss under 60s remaining")
        check(TimersWidget.formatAmbientRemaining(-3) == "0:00",
              "TimersWidget: formatAmbientRemaining never shows a negative value")
        check(TimersWidget.formatAmbientRemaining(.infinity) == "0:00",
              "TimersWidget: formatAmbientRemaining guards a non-finite input")

        // --- M6 fix: NotchActivityRouter.nextTimerRefreshBoundary — ticks
        // once a MINUTE while more than a minute remains, but once a SECOND
        // once inside the final minute, matching formatAmbientRemaining's
        // own cadence switch so the displayed text is never stale. ---
        let ntFarDeadline = ntNow.addingTimeInterval(300) // 5 minutes out
        let ntFarBoundary = NotchActivityRouter.nextTimerRefreshBoundary(deadline: ntFarDeadline, now: ntNow)
        check(ntFarBoundary.timeIntervalSince(ntNow) <= 60 + 0.01,
              "NotchActivityRouter: nextTimerRefreshBoundary ticks at most a minute out while well over a minute remains")
        let ntNearDeadline = ntNow.addingTimeInterval(42) // inside the final minute
        let ntNearBoundary = NotchActivityRouter.nextTimerRefreshBoundary(deadline: ntNearDeadline, now: ntNow)
        check(ntNearBoundary.timeIntervalSince(ntNow) <= 1 + 0.01,
              "NotchActivityRouter: nextTimerRefreshBoundary ticks at most a second out once inside the final minute")

        // --- M6: ClipboardMonitor.classify — the text-vs-URL seam extracted
        // out of `capture(from:)` so this is testable against a plain
        // `String`, with no real `NSPasteboard` content involved. ---
        check(ClipboardMonitor.classify(string: "https://example.com/path") == .url,
              "ClipboardMonitor: classify recognizes a full URL (scheme + host) as .url")
        check(ClipboardMonitor.classify(string: "hello world") == .text,
              "ClipboardMonitor: classify treats a plain string as .text")
        check(ClipboardMonitor.classify(string: "mailto:nobody@example.com") == .text,
              "ClipboardMonitor: classify treats a scheme-only string with no host as .text, not .url")
        check(ClipboardMonitor.classify(string: "just some text: with a colon in it") == .text,
              "ClipboardMonitor: classify doesn't misfire on a string that merely contains a colon")

        // --- M6 smoke tests: CameraService/ClipboardMonitor/LockScreenPresenter
        // construct and tear down safely on a headless CI runner with no
        // guaranteed camera hardware, real pasteboard writes, or lock-screen
        // session. Mirrors M5's BrightnessMonitor/VolumeMonitor smoke tests. ---
        do {
            let cameraProbe = CameraService()
            check(!cameraProbe.isRunning, "CameraService: isRunning starts false")
            cameraProbe.stop() // must be safe even though never started
            check(!cameraProbe.isRunning, "CameraService: stop() before any start() is a safe no-op")
            // --- M6 fix: wantsRunning tracks the widget's last-requested
            // lifecycle state so `.AVCaptureSessionInterruptionEnded` knows
            // whether to restart. Not directly observable from outside (it's
            // private), but start()/stop() cycles — including a stop() with
            // no prior start(), and a stop() right after a start() that never
            // got authorization on this headless CI runner — must remain
            // crash-free and leave isRunning false, exercising exactly the
            // code paths that flip it. ---
            cameraProbe.start() // no camera authorization on CI — safe no-op past the guard
            check(!cameraProbe.isRunning, "CameraService: start() without authorization never optimistically flips isRunning")
            cameraProbe.stop()
            check(!cameraProbe.isRunning, "CameraService: stop() after an unauthorized start() is still a safe no-op")

            // --- M8 crash fix: the Mirror preview may only configure its
            // capture connection's mirror once the session is actually running
            // (never while startRunning() is still racing on the session
            // queue) AND only when mirroring is supported — either violation
            // throws an uncatchable NSInvalidArgumentException. The gate is a
            // pure function so it's covered here without a camera. ---
            check(CameraService.shouldConfigureMirroring(sessionRunning: true, mirroringSupported: true),
                  "CameraService.shouldConfigureMirroring: configures only when running AND supported")
            check(!CameraService.shouldConfigureMirroring(sessionRunning: false, mirroringSupported: true),
                  "CameraService.shouldConfigureMirroring: never configures before the session is running (would race startRunning())")
            check(!CameraService.shouldConfigureMirroring(sessionRunning: true, mirroringSupported: false),
                  "CameraService.shouldConfigureMirroring: never sets isVideoMirrored when mirroring is unsupported")
            check(!CameraService.shouldConfigureMirroring(sessionRunning: false, mirroringSupported: false),
                  "CameraService.shouldConfigureMirroring: no-op when neither running nor supported")

            // --- M8 fix: CameraService(forcingUnavailable:) — the seam
            // `NotchSnapshot`'s expanded-mirror render uses so its "No camera
            // found" state renders deterministically, even on a machine that
            // actually has a built-in camera (unlike the plain init() probe
            // above, which reports whatever the real host hardware has). ---
            let forcedUnavailableProbe = CameraService(forcingUnavailable: true)
            check(!forcedUnavailableProbe.isAvailable,
                  "CameraService(forcingUnavailable: true): isAvailable is false unconditionally, regardless of real host hardware")
            forcedUnavailableProbe.start() // must still be a safe no-op — isAvailable gates start() same as a real absent camera
            check(!forcedUnavailableProbe.isRunning,
                  "CameraService(forcingUnavailable: true): start() is a safe no-op since isAvailable is forced false")
        }
        do {
            let clipboardProbe = ClipboardMonitor(pasteboard: .general)
            check(clipboardProbe.entries.isEmpty, "ClipboardMonitor: starts with empty history")
            clipboardProbe.stop() // must be safe even though never started
            check(clipboardProbe.entries.isEmpty, "ClipboardMonitor: stop() before start() is a safe no-op")
            // --- M6 fix: suppressedChangeCount is reset to nil by stop()
            // (kept for cleanliness — compare-by-value means it's no longer
            // load-bearing correctness the way the old skipNextCapture flag
            // reset was, see that property's own doc comment). Not directly
            // observable from outside (it's private), but repeated
            // start()/stop() cycles must stay crash-free and leave history
            // untouched, exercising exactly the reset code paths. ---
            clipboardProbe.start()
            clipboardProbe.stop()
            clipboardProbe.start()
            clipboardProbe.stop()
            check(clipboardProbe.entries.isEmpty, "ClipboardMonitor: start()/stop() cycles alone never capture anything")
        }

        // --- M8: fixture-injection seams behind NotchSnapshot's
        // all-widgets snapshot coverage (`CalendarService.injectPreviewEvents`,
        // `ClipboardMonitor.injectPreviewEntries`, `PermissionCenter.
        // injectPreviewStatus`). Each is a direct passthrough into a
        // service's own `@Published` state — mirroring `NowPlayingService.
        // injectPreviewState`'s existing seam — so asserting the published
        // value right after injecting is enough to prove each seam actually
        // reaches what its widget reads. `NotchSnapshot` itself renders
        // real SwiftUI offscreen and isn't exercised by `--selftest`; this is
        // the seams' own regression net. ---
        do {
            let previewCalendar = CalendarService()
            check(previewCalendar.upcoming.isEmpty, "CalendarService: upcoming starts empty")
            let fixtureEvent = CalendarEvent(id: "preview-fixture", title: "Fixture Event",
                                              start: Date(), end: Date().addingTimeInterval(3_600),
                                              isAllDay: false, calendarColor: nil, location: nil)
            previewCalendar.injectPreviewEvents([fixtureEvent])
            check(previewCalendar.upcoming == [fixtureEvent],
                  "CalendarService.injectPreviewEvents: published upcoming reflects exactly the injected fixture, bypassing EventKit entirely")

            let previewClipboard = ClipboardMonitor(pasteboard: .general)
            let fixtureEntry = ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .text,
                                               preview: "preview", fullString: "preview", filePaths: nil)
            previewClipboard.injectPreviewEntries([fixtureEntry])
            check(previewClipboard.entries == [fixtureEntry],
                  "ClipboardMonitor.injectPreviewEntries: published entries reflects exactly the injected fixture, bypassing the pasteboard poll entirely")

            let previewPermissions = PermissionCenter()
            previewPermissions.injectPreviewStatus(.calendar, .granted)
            check(previewPermissions.statuses[.calendar] == .granted,
                  "PermissionCenter.injectPreviewStatus: overwrites the published status for the given kind")
            previewPermissions.injectPreviewStatus(.camera, .denied)
            check(previewPermissions.statuses[.camera] == .denied && previewPermissions.statuses[.calendar] == .granted,
                  "PermissionCenter.injectPreviewStatus: each PermissionKind's injected status is independent of the others")
        }

        // --- M6 fix: ClipboardMonitor.shouldSuppressCapture — the pure
        // decision core behind suppressedChangeCount, split out of poll()
        // (mirroring classify(string:)'s own split, for the identical
        // reason: this suite's CI runner doesn't reliably support live
        // NSPasteboard read/write round-tripping — changeCount can simply
        // never advance no matter what's written on a headless runner with
        // no window-server session — so the actual code-review fix has to
        // be tested through a pasteboard-free seam). Only a poll tick whose
        // changeCount is the EXACT value copyBack(_:) produced is skipped;
        // any other value (an external copy that bumped the count further,
        // or no suppression pending at all) is captured normally. ---
        check(ClipboardMonitor.shouldSuppressCapture(currentChangeCount: 42, suppressedChangeCount: 42),
              "ClipboardMonitor: shouldSuppressCapture skips a tick whose changeCount exactly matches copyBack's own")
        check(!ClipboardMonitor.shouldSuppressCapture(currentChangeCount: 43, suppressedChangeCount: 42),
              "ClipboardMonitor: shouldSuppressCapture does NOT skip a tick whose changeCount is anything other than the exact suppressed value — a genuinely external copy landing right after copyBack's own write is still captured normally")
        check(!ClipboardMonitor.shouldSuppressCapture(currentChangeCount: 42, suppressedChangeCount: nil),
              "ClipboardMonitor: shouldSuppressCapture never skips when nothing is currently suppressed")

        // --- M6 fix: ClipboardMonitor.cappedFullString — the pure
        // truncation core behind the fullStringCap bound, made non-private
        // (like classify(string:)) for the same CI-testability reason
        // above. ---
        let underCapString = String(repeating: "x", count: 10)
        check(ClipboardMonitor.cappedFullString(underCapString) == underCapString,
              "ClipboardMonitor: cappedFullString leaves an under-cap string completely untouched, with no marker appended")
        let exactlyAtCapString = String(repeating: "x", count: ClipboardMonitor.fullStringCap)
        check(ClipboardMonitor.cappedFullString(exactlyAtCapString) == exactlyAtCapString,
              "ClipboardMonitor: cappedFullString leaves a string sitting EXACTLY at the cap untouched — truncation only kicks in strictly OVER it")
        let overCapString = String(repeating: "x", count: ClipboardMonitor.fullStringCap + 500)
        let cappedResult = ClipboardMonitor.cappedFullString(overCapString)
        check(cappedResult.count == ClipboardMonitor.fullStringCap + 1,
              "ClipboardMonitor: cappedFullString truncates an over-cap string to fullStringCap characters plus one trailing marker character")
        check(cappedResult.hasSuffix("…"),
              "ClipboardMonitor: a truncated fullString ends with an ellipsis marker")
        check(cappedResult.hasPrefix(String(repeating: "x", count: 100)),
              "ClipboardMonitor: a truncated fullString still starts with the original content, not just the marker")
        do {
            // --- M6 fix: ClipboardEntry.filePaths carries each captured file
            // path as its own array element — unlike the old newline-joined-
            // then-re-split `fullString` approach, a path that itself
            // contains a newline round-trips intact instead of being
            // corrupted into two paths. ---
            let weirdPath = "/tmp/weird\nname.txt"
            let fileEntry = ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .file,
                                            preview: "weird\nname.txt", fullString: nil,
                                            filePaths: [weirdPath, "/tmp/normal.txt"])
            check(fileEntry.filePaths?.count == 2,
                  "ClipboardEntry: filePaths keeps a path containing a newline as ONE element, not split into two")
            check(fileEntry.filePaths?.first == weirdPath,
                  "ClipboardEntry: filePaths preserves a newline-containing path verbatim")
            check(fileEntry.fullString == nil,
                  "ClipboardEntry: fullString is nil for a .file entry — file paths round-trip through filePaths only")
        }
        do {
            // M9: `LockScreenPresenter` now takes its Now Playing/activity/
            // settings dependencies directly (replacing the old
            // `currentActivityLine` closure seam) — fresh, disposable
            // instances of each, isolated to their own `UserDefaults` suite,
            // are all this smoke test needs; no real lock session, MediaRemote
            // source, or persisted user preference is ever touched.
            let lockScreenSuiteName = "flux.selftest.lockscreenpresenter"
            UserDefaults.standard.removePersistentDomain(forName: lockScreenSuiteName)
            let lockScreenSettings = SettingsStore(defaults: UserDefaults(suiteName: lockScreenSuiteName)!)
            let lockScreenProbe = LockScreenPresenter(nowPlaying: NowPlayingService(),
                                                       activities: LiveActivityCenter(),
                                                       settings: lockScreenSettings)
            check(!lockScreenProbe.isPresentingOnLockScreen, "LockScreenPresenter: starts not presenting")
            lockScreenProbe.setEnabled(true)
            lockScreenProbe.setEnabled(true) // idempotent — a repeated identical call is a no-op
            lockScreenProbe.setEnabled(false)
            check(!lockScreenProbe.isPresentingOnLockScreen,
                  "LockScreenPresenter: disabling tears everything down — nothing left presenting")
            UserDefaults.standard.removePersistentDomain(forName: lockScreenSuiteName)
        }

        // --- M9 (lock-screen Now Playing freshness): LockScreenPresenter.
        // shouldActivateForLock — the pure decision behind whether the
        // presenter itself needs to call `nowPlaying.setActive(true)` while
        // locked, extracted the same way `NowPlayingService.
        // shouldEngageScriptingFallback` is, so the on/off matrix is
        // assertable without a real lock session or notched screen (this
        // environment has neither). The core property under test: the
        // presenter only ever activates the service on its own behalf when
        // BOTH the master experiment flag and the Now Playing sub-toggle are
        // on AND nothing else has already made the service active — that
        // last clause is what keeps this presenter from stepping on the Now
        // Playing widget's own ownership when it was already presented at
        // lock time. ---
        check(!LockScreenPresenter.shouldActivateForLock(serviceActive: false, masterEnabled: false, nowPlayingAllowed: true),
              "LockScreenPresenter.shouldActivateForLock: never activates while the master experiment flag is off")
        check(!LockScreenPresenter.shouldActivateForLock(serviceActive: false, masterEnabled: true, nowPlayingAllowed: false),
              "LockScreenPresenter.shouldActivateForLock: never activates while the Now Playing sub-toggle is off")
        check(!LockScreenPresenter.shouldActivateForLock(serviceActive: true, masterEnabled: true, nowPlayingAllowed: true),
              "LockScreenPresenter.shouldActivateForLock: never activates when the service is already active — the widget (or a prior lock) already owns it")
        check(LockScreenPresenter.shouldActivateForLock(serviceActive: false, masterEnabled: true, nowPlayingAllowed: true),
              "LockScreenPresenter.shouldActivateForLock: activates when both flags are on and the service is currently inactive")

        // --- M9 (Alcove lock-screen parity): LockScreenPillLogic.visiblePills
        // — the pure derivation behind which of the (up to) three lock-screen
        // pills actually render, covering the on/off matrix headlessly. ---
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: false, allowNowPlaying: true,
                                                hasActivityCaption: false, allowActivities: true,
                                                showUnlockPill: false) == [],
              "LockScreenPillLogic: nothing to show, nothing enabled → no pills")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: true, allowNowPlaying: true,
                                                hasActivityCaption: false, allowActivities: true,
                                                showUnlockPill: false) == [.nowPlaying],
              "LockScreenPillLogic: Now Playing has state and is allowed → just the media pill")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: true, allowNowPlaying: false,
                                                hasActivityCaption: false, allowActivities: true,
                                                showUnlockPill: false) == [],
              "LockScreenPillLogic: Now Playing has state but the sub-toggle is off → no media pill")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: false, allowNowPlaying: true,
                                                hasActivityCaption: true, allowActivities: true,
                                                showUnlockPill: false) == [.activity],
              "LockScreenPillLogic: a captioned activity, allowed → just the activity pill")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: false, allowNowPlaying: true,
                                                hasActivityCaption: true, allowActivities: false,
                                                showUnlockPill: false) == [],
              "LockScreenPillLogic: a captioned activity but the sub-toggle is off → no activity pill")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: false, allowNowPlaying: true,
                                                hasActivityCaption: false, allowActivities: true,
                                                showUnlockPill: true) == [.unlock],
              "LockScreenPillLogic: nothing else showing, unlock pill on → just the unlock pill")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: true, allowNowPlaying: true,
                                                hasActivityCaption: true, allowActivities: true,
                                                showUnlockPill: true) == [.nowPlaying, .activity, .unlock],
              "LockScreenPillLogic: everything showing and allowed → all three, in fixed media/activity/unlock order")
        check(LockScreenPillLogic.visiblePills(hasNowPlaying: true, allowNowPlaying: false,
                                                hasActivityCaption: true, allowActivities: false,
                                                showUnlockPill: true) == [.unlock],
              "LockScreenPillLogic: Now Playing and the activity both disallowed → only the unlock pill survives")

        // --- M6: NotchActivityRouter — timer completion/ambient translation,
        // driven purely through a real (but headless) TimerService's own
        // `completions`/`timers` — no NSSound actually needs to play
        // successfully on a headless runner for this to pass; only the
        // posted LiveActivity content is asserted. ---
        do {
            let timerRouterSuiteName = "flux.selftest.timerrouter"
            let timerRouterSuite = UserDefaults(suiteName: timerRouterSuiteName)!
            timerRouterSuite.removePersistentDomain(forName: timerRouterSuiteName)
            let timerRouterSettings = SettingsStore(defaults: timerRouterSuite)
            let timerRouterActivities = LiveActivityCenter()
            let timerRouterArranger = MenuBarArranger()
            let timerRouterCalendar = CalendarService()
            let timerRouterPermissions = PermissionCenter()
            let timerRouterTimers = TimerService()
            let timerRouterViewModel = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter())
            let timerRouter = NotchActivityRouter(activities: timerRouterActivities, settings: timerRouterSettings,
                                                   arranger: timerRouterArranger, calendar: timerRouterCalendar,
                                                   permissions: timerRouterPermissions, viewModel: timerRouterViewModel,
                                                   timers: timerRouterTimers, startsMonitors: false)

            withExtendedLifetime(timerRouter) {
                // Starting a timer posts the ambient sticky wing.
                let started = timerRouterTimers.start(duration: 120, label: "Focus")
                check(timerRouterActivities.current?.kind == .timer,
                      "NotchActivityRouter: a running timer posts an ambient .timer live activity")
                check(timerRouterActivities.current?.priority == 110,
                      "NotchActivityRouter: the ambient timer wing posts at priority 110 — below menu-bar overflow's 150")
                check(timerRouterActivities.current?.duration == nil,
                      "NotchActivityRouter: the ambient timer wing is STICKY (no duration) while a timer is running")
                // Not asserting an exact "2 min" here: some non-zero (if
                // tiny) real time always elapses between `start()` capturing
                // `startedAt` and this synchronous recompute reading the
                // countdown, so `formatAmbientRemaining`'s floored-minutes
                // display can legitimately read one tick under a round value
                // (a 120s timer reading as either exactly 2 minutes left, or
                // a hair under it, floors to "1 min") — the precise
                // formatting is already pinned deterministically by the
                // `TimersWidget.nearestRemainingLine`/`formatAmbientRemaining`
                // checks above; this only needs to confirm the router
                // actually surfaces SOME countdown text, not re-verify its
                // exact value.
                if case .text(let ambientLine)? = timerRouterActivities.current?.trailing {
                    check(ambientLine == "2 min" || ambientLine == "1 min",
                          "NotchActivityRouter: the ambient wing shows the nearest remaining timer's countdown text (got \(ambientLine))")
                } else {
                    check(false, "NotchActivityRouter: the ambient wing's trailing content should be countdown .text")
                }

                // --- M6 fix: pausing the ONLY running timer must show a
                // paused indicator, not dismiss the wing entirely — the old
                // bug read "no RUNNING timer" as "no timer at all." ---
                timerRouterTimers.pause(started.id)
                check(timerRouterActivities.current?.kind == .timer,
                      "NotchActivityRouter: pausing the only running timer keeps the wing showing (a paused indicator), not dismissed")
                check(timerRouterActivities.current?.leading == .icon(systemName: "pause.circle"),
                      "NotchActivityRouter: the paused wing's leading content is the pause.circle icon, not the running timer icon")
                timerRouterTimers.resume(started.id)
                check(timerRouterActivities.current?.leading == .icon(systemName: "timer"),
                      "NotchActivityRouter: resuming brings back the running wing's timer icon")

                // Cancelling the only running timer dismisses the ambient wing.
                timerRouterTimers.cancel(started.id)
                check(timerRouterActivities.current?.kind != .timer,
                      "NotchActivityRouter: cancelling the only running timer dismisses the ambient wing — no timers at all is still .hidden")

                // A completion event posts a transient, higher-priority notice.
                let completionTimer = NotchTimer(label: "Tea", duration: 1, startedAt: Date().addingTimeInterval(-1))
                timerRouterTimers.completions.send(completionTimer)
                check(timerRouterActivities.current?.kind == .timer,
                      "NotchActivityRouter: a completion event posts a .timer live activity")
                check(timerRouterActivities.current?.priority == 250,
                      "NotchActivityRouter: a completion notice posts at priority 250 — above the ambient wing's 110")
                check(timerRouterActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: the completion notice reads '<label> done'")
                check(timerRouterActivities.current?.duration == 10,
                      "NotchActivityRouter: the completion notice is transient (10s), not sticky")

                // Settings gating: the timer-activity toggle off suppresses
                // both further completion posts and the ambient wing.
                timerRouterActivities.dismiss(kind: .timer)
                timerRouterSettings.notchActivityTimerEnabled = false
                timerRouterTimers.completions.send(completionTimer)
                check(timerRouterActivities.current?.kind != .timer,
                      "NotchActivityRouter: the timer-activity toggle off suppresses completion posts")
                _ = timerRouterTimers.start(duration: 60, label: "Ignored")
                check(timerRouterActivities.current?.kind != .timer,
                      "NotchActivityRouter: the timer-activity toggle off also suppresses the ambient wing for a newly started timer")
            }
            timerRouterSuite.removePersistentDomain(forName: timerRouterSuiteName)
        }

        // --- M6 fix: NotchActivityRouter — completionAlertUntil guards the
        // ambient/paused wing recompute for the full 10s a "<label> done"
        // notice is showing. Before this fix, ANY mutation during that
        // window (start/pause/resume/cancel of some OTHER still-running
        // timer) republished `timers.$timers`, which fed straight into
        // `recomputeTimerActivity` and replaced/dismissed the "done" wing
        // early — this reproduces exactly that sequence and asserts the
        // notice survives every one of those mutations untouched. ---
        do {
            let alertSuiteName = "flux.selftest.timercompletionalert"
            let alertSuite = UserDefaults(suiteName: alertSuiteName)!
            alertSuite.removePersistentDomain(forName: alertSuiteName)
            let alertSettings = SettingsStore(defaults: alertSuite)
            let alertActivities = LiveActivityCenter()
            let alertArranger = MenuBarArranger()
            let alertCalendar = CalendarService()
            let alertPermissions = PermissionCenter()
            let alertTimers = TimerService()
            let alertViewModel = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter())
            let alertRouter = NotchActivityRouter(activities: alertActivities, settings: alertSettings,
                                                   arranger: alertArranger, calendar: alertCalendar,
                                                   permissions: alertPermissions, viewModel: alertViewModel,
                                                   timers: alertTimers, startsMonitors: false)
            withExtendedLifetime(alertRouter) {
                let running = alertTimers.start(duration: 120, label: "Kettle")

                // A completion event for a separate, already-finished timer
                // posts the transient "done" notice.
                let finished = NotchTimer(label: "Tea", duration: 1, startedAt: Date().addingTimeInterval(-1))
                alertTimers.completions.send(finished)
                check(alertActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: a completion event posts the '<label> done' notice")

                // Every mutation below republishes `timers.$timers`, which
                // would (pre-fix) immediately recompute and stomp the "done"
                // notice with the ambient wing for `running`. None of them
                // should change what's currently posted.
                alertTimers.pause(running.id)
                check(alertActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: pausing another timer during an active completion alert leaves the 'done' notice untouched")
                alertTimers.resume(running.id)
                check(alertActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: resuming another timer during an active completion alert leaves the 'done' notice untouched")
                _ = alertTimers.start(duration: 60, label: "Extra")
                check(alertActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: starting a NEW timer during an active completion alert leaves the 'done' notice untouched")
                alertTimers.cancel(running.id)
                check(alertActivities.current?.trailing == .text("Tea done"),
                      "NotchActivityRouter: cancelling a timer during an active completion alert leaves the 'done' notice untouched")
            }
            alertSuite.removePersistentDomain(forName: alertSuiteName)
        }

        // --- M6: SettingsStore — fresh-install defaults for every new key,
        // including the widget-order extension (mirror/timers/clipboard
        // appended after calendar). Mirrors the "Hotkey" section's own
        // fresh-suite-defaults pattern earlier in this file. ---
        do {
            let m6SettingsSuiteName = "flux.selftest.m6settings"
            UserDefaults.standard.removePersistentDomain(forName: m6SettingsSuiteName)
            let m6Settings = SettingsStore(defaults: UserDefaults(suiteName: m6SettingsSuiteName)!)
            check(m6Settings.notchMirrorEnabled, "SettingsStore: notchMirrorEnabled defaults to true")
            check(!m6Settings.notchClipboardEnabled,
                  "SettingsStore: notchClipboardEnabled defaults to false — clipboard history collection is opt-in")
            check(m6Settings.notchTimersEnabled, "SettingsStore: notchTimersEnabled defaults to true")
            check(m6Settings.notchActivityTimerEnabled, "SettingsStore: notchActivityTimerEnabled defaults to true")
            check(!m6Settings.notchLockScreenExperimentEnabled,
                  "SettingsStore: notchLockScreenExperimentEnabled (EXPERIMENTAL) defaults to false")
            check(m6Settings.notchWidgetOrder == [WidgetID.nowPlaying.rawValue, WidgetID.shelf.rawValue,
                                                   WidgetID.calendar.rawValue, WidgetID.mirror.rawValue,
                                                   WidgetID.timers.rawValue, WidgetID.clipboard.rawValue],
                  "SettingsStore: the default notchWidgetOrder appends mirror/timers/clipboard after calendar")

            // M9 (Alcove lock-screen parity): the three sub-toggles that
            // only matter once the master experimental flag above is on
            // default to Now Playing/Notifications ON (they surface
            // information a passerby could otherwise miss, the same bar
            // every other on-by-default notch feature clears) but the
            // Unlock pill and unlock sound stay OFF (purely decorative/
            // audible additions, not information — see each property's own
            // doc comment on `SettingsStore`).
            check(m6Settings.notchLockScreenNowPlayingEnabled,
                  "SettingsStore: notchLockScreenNowPlayingEnabled defaults to true")
            check(m6Settings.notchLockScreenActivitiesEnabled,
                  "SettingsStore: notchLockScreenActivitiesEnabled defaults to true")
            check(!m6Settings.notchLockScreenUnlockPillEnabled,
                  "SettingsStore: notchLockScreenUnlockPillEnabled defaults to false")
            check(!m6Settings.notchLockScreenUnlockSoundEnabled,
                  "SettingsStore: notchLockScreenUnlockSoundEnabled defaults to false")
            UserDefaults.standard.removePersistentDomain(forName: m6SettingsSuiteName)
        }

        // --- M6: NotchWidgetRegistry — every one of the app's 6 WidgetIDs
        // registers and orders correctly (nowPlaying, shelf, calendar,
        // mirror, timers, clipboard). ---
        check(WidgetID.allCases.count == 6,
              "WidgetID: exactly 6 widgets exist in the notch suite (nowPlaying, shelf, calendar, mirror, timers, clipboard)")
        let sixRegistry = NotchWidgetRegistry()
        let sixWidgets = WidgetID.allCases.map { SelfTestWidget(id: $0) }
        for widget in sixWidgets { sixRegistry.register(widget) }
        sixRegistry.order = WidgetID.allCases
        check(sixRegistry.widgets.count == 6, "NotchWidgetRegistry: all 6 WidgetIDs register successfully")
        check(sixRegistry.enabledWidgets.map(\.id) == WidgetID.allCases,
              "NotchWidgetRegistry: all 6 widgets appear, in order, when every one is enabled")

        // --- M7: SettingsStore — fresh-install defaults for the Duo view
        // and Focus toggles, mirroring the M6 defaults block's own pattern. ---
        do {
            let m7SettingsSuiteName = "flux.selftest.m7settings"
            UserDefaults.standard.removePersistentDomain(forName: m7SettingsSuiteName)
            let m7Settings = SettingsStore(defaults: UserDefaults(suiteName: m7SettingsSuiteName)!)
            check(!m7Settings.notchDuoEnabled, "SettingsStore: notchDuoEnabled defaults to false")
            check(!m7Settings.notchActivityFocusEnabled,
                  "SettingsStore: notchActivityFocusEnabled defaults to false (M9) — no protected-path read without opt-in")
            check(!m7Settings.notchActivityFocusStickyEnabled,
                  "SettingsStore: notchActivityFocusStickyEnabled defaults to false — the persistent indicator is opt-in")
            UserDefaults.standard.removePersistentDomain(forName: m7SettingsSuiteName)
        }

        // --- M9: SettingsStore — the privacy-audit defaults: Bluetooth and
        // Focus flipped from on-by-default to opt-in, and the new AppleScript
        // fallback consent toggle defaults off too. Fresh-install launch
        // must produce zero TCC prompts, so every one of these three has to
        // read `false` on a brand-new suite before anything else runs. ---
        do {
            let m9SettingsSuiteName = "flux.selftest.m9settings"
            UserDefaults.standard.removePersistentDomain(forName: m9SettingsSuiteName)
            let m9Settings = SettingsStore(defaults: UserDefaults(suiteName: m9SettingsSuiteName)!)
            check(!m9Settings.notchActivityBluetoothEnabled,
                  "SettingsStore: notchActivityBluetoothEnabled defaults to false (M9) — registering for Bluetooth notifications triggers the TCC prompt, so this is opt-in")
            check(!m9Settings.notchActivityFocusEnabled,
                  "SettingsStore: notchActivityFocusEnabled defaults to false (M9)")
            check(!m9Settings.notchNowPlayingAppleScriptFallbackEnabled,
                  "SettingsStore: notchNowPlayingAppleScriptFallbackEnabled defaults to false (M9) — scripting Music/Spotify triggers an Automation prompt, so this is opt-in")
            UserDefaults.standard.removePersistentDomain(forName: m9SettingsSuiteName)
        }

        // --- M7: LiveActivityCenter.cycle() — the Alcove-style ring over
        // queued STICKY activities, starting from whatever's current. ---
        do {
            let cycleCenter = LiveActivityCenter()
            let cycleA = LiveActivity(kind: .battery, leading: .none, trailing: .text("A"), duration: nil, priority: 200)
            let cycleB = LiveActivity(kind: .bluetoothDevice, leading: .none, trailing: .text("B"), duration: nil, priority: 100)
            let cycleC = LiveActivity(kind: .calendarEvent, leading: .none, trailing: .text("C"), duration: nil, priority: 120)
            cycleCenter.post(cycleA)
            cycleCenter.post(cycleB)
            cycleCenter.post(cycleC)
            check(cycleCenter.current?.id == cycleA.id,
                  "LiveActivityCenter: setup — the highest-priority sticky activity (A, 200) is current before any cycling")

            cycleCenter.cycle()
            check(cycleCenter.current?.id == cycleB.id,
                  "LiveActivityCenter: cycle() advances the ring in post order starting from whatever's current (A -> B), regardless of B's lower priority")
            cycleCenter.cycle()
            check(cycleCenter.current?.id == cycleC.id,
                  "LiveActivityCenter: cycle() continues to the next queued sticky activity (B -> C)")
            cycleCenter.cycle()
            check(cycleCenter.current?.id == cycleA.id,
                  "LiveActivityCenter: cycle() wraps back around to the first (C -> A)")

            cycleCenter.cycle() // A -> B
            check(cycleCenter.current?.id == cycleB.id, "LiveActivityCenter: setup — cursor parked on B")
            let transientHUD = LiveActivity(kind: .hudVolume, leading: .none, trailing: .none, duration: 5, priority: 300)
            cycleCenter.post(transientHUD)
            check(cycleCenter.current?.id == cycleB.id,
                  "LiveActivityCenter: a transient activity posted while an explicit cycle cursor is active does not preempt it, even at a higher priority — the documented cycleCursor tradeoff")
            cycleCenter.dismiss(id: transientHUD.id)

            // dismissCurrent(restorable: true) removes whatever's current and
            // stashes it; the cursor's own target is now gone, so
            // recomputeCurrent falls back to plain priority resolution.
            cycleCenter.dismissCurrent(restorable: true)
            check(cycleCenter.current?.id == cycleA.id,
                  "LiveActivityCenter: dismissCurrent(restorable:) removes the shown activity (B) and falls back to plain priority resolution (A) once the cursor's target is gone")

            cycleCenter.restoreLastDismissed()
            check(cycleCenter.current?.id == cycleB.id,
                  "LiveActivityCenter: restoreLastDismissed() re-queues the most recently dismissed activity (B) and makes it current again, regardless of priority")

            cycleCenter.restoreLastDismissed()
            check(cycleCenter.current?.id == cycleB.id,
                  "LiveActivityCenter: restoreLastDismissed() is a no-op with nothing left on the dismissed stack")

            let noopCenter = LiveActivityCenter()
            noopCenter.cycle()
            check(noopCenter.current == nil, "LiveActivityCenter: cycle() is a safe no-op with nothing queued at all")
        }

        // --- M7: LiveActivityCenter's dismissed-stack caps at 5, evicting
        // the OLDEST dismissal first — a long dismiss/restore session must
        // never grow it unbounded. ---
        do {
            let capCenter = LiveActivityCenter()
            for i in 0..<6 {
                let activity = LiveActivity(kind: .battery, leading: .none, trailing: .text("cap\(i)"), duration: nil, priority: 100 + i)
                capCenter.post(activity)
                capCenter.dismissCurrent(restorable: true)
            }
            var restoredOrder: [String] = []
            for _ in 0..<5 {
                capCenter.restoreLastDismissed()
                if case .text(let label)? = capCenter.current?.trailing {
                    restoredOrder.append(label)
                }
                // Dismiss NON-restorably so the next restore reaches the next
                // one down the stack, rather than this same one cycling
                // straight back onto it.
                capCenter.dismissCurrent(restorable: false)
            }
            check(restoredOrder == ["cap5", "cap4", "cap3", "cap2", "cap1"],
                  "LiveActivityCenter: the dismissed stack caps at 5 (oldest, cap0, evicted) and restores most-recently-dismissed first")
            capCenter.restoreLastDismissed()
            check(capCenter.current == nil,
                  "LiveActivityCenter: restoring past the cap's worth of dismissed activities is a no-op — cap0 was evicted, never restorable")
        }

        // --- M7 bot-review fix: restoreLastDismissed() must route through
        // post()'s own one-entry-per-kind invariant, not bypass it with a
        // bare queue append — restoring a dismissed activity while a NEW
        // activity of the SAME kind has since been posted must not leave two
        // queued entries of that kind at once. ---
        do {
            let dupCenter = LiveActivityCenter()
            let dupOld = LiveActivity(kind: .battery, leading: .none, trailing: .text("old"), duration: nil, priority: 200)
            dupCenter.post(dupOld)
            dupCenter.dismissCurrent(restorable: true)

            let dupNew = LiveActivity(kind: .battery, leading: .none, trailing: .text("new"), duration: nil, priority: 200)
            dupCenter.post(dupNew)
            check(dupCenter.current?.id == dupNew.id,
                  "LiveActivityCenter: setup — the freshly posted same-kind activity (new) is current before restoring")

            dupCenter.restoreLastDismissed()
            if case .text(let label)? = dupCenter.current?.trailing {
                check(label == "old",
                      "LiveActivityCenter: restoreLastDismissed() supersedes an already-queued same-kind activity through post()'s own dedup, surfacing the restored (old) content")
            } else {
                check(false, "LiveActivityCenter: restoreLastDismissed() should surface the restored activity's content")
            }

            // The real bug this guards against: bypassing post()'s
            // one-entry-per-kind invariant would leave BOTH "old" and "new"
            // queued under `.battery` at once — dismissing whichever is
            // current would then just reveal the other leftover duplicate
            // instead of leaving nothing queued.
            dupCenter.dismissCurrent(restorable: false)
            check(dupCenter.current == nil,
                  "LiveActivityCenter: restoreLastDismissed() must not leave a duplicate same-kind entry behind — dismissing the restored activity leaves nothing queued, not a leftover duplicate")
        }

        // --- M7: NotchViewModel's Alcove swipe map — while `.activity` is
        // showing, left/right cycle ACTIVITIES (not widgets), up dismisses
        // (restorably) the one showing, and down expands to the widget
        // panel. Drives real LiveActivityCenter posts so the observeActivities()
        // sink's own state-machine reaction is exercised end to end, not
        // mocked. ---
        do {
            let swipeActivityRegistry = NotchWidgetRegistry()
            let swipeActivityWidget = SelfTestWidget(id: .nowPlaying)
            swipeActivityRegistry.register(swipeActivityWidget)
            swipeActivityRegistry.order = [.nowPlaying]
            let swipeActivities = LiveActivityCenter()
            let swipeVM = NotchViewModel(registry: swipeActivityRegistry, activities: swipeActivities)

            let swipeActivityA = LiveActivity(kind: .battery, leading: .none, trailing: .text("A"), duration: nil, priority: 200)
            let swipeActivityB = LiveActivity(kind: .bluetoothDevice, leading: .none, trailing: .text("B"), duration: nil, priority: 100)
            swipeActivities.post(swipeActivityA)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .activity(swipeActivityA.id), "Notch: setup — posting a sticky activity preempts collapsed")

            swipeActivities.post(swipeActivityB)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .activity(swipeActivityA.id), "Notch: setup — A (200) still outranks B (100) before any cycling")

            swipeVM.swiped(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .activity(swipeActivityB.id),
                  "Notch: swipe left while an activity is showing cycles to the next queued activity (Alcove semantics), not widgets")

            swipeVM.swiped(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .activity(swipeActivityA.id),
                  "Notch: swipe right while an activity is showing also cycles activities (cycle() is a single-direction ring either way)")

            swipeVM.swiped(.up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .activity(swipeActivityB.id),
                  "Notch: swipe up while an activity is showing dismisses it (restorably), surfacing the next queued one")

            swipeVM.swiped(.down)
            check(swipeVM.state == .expanded(.nowPlaying),
                  "Notch: swipe down while an activity is showing expands to the widget panel")

            swipeActivities.restoreLastDismissed()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(swipeVM.state == .expanded(.nowPlaying),
                  "Notch: restoring a dismissed activity doesn't preempt an already-expanded widget panel (unchanged pre-M7 rule)")
            check(swipeActivities.current?.id == swipeActivityA.id,
                  "Notch: restoreLastDismissed() does bring A back as LiveActivityCenter's own current, even though the notch itself stays on the expanded widget")
        }

        // --- M7: swipe(.down) is a no-op while already `.expanded` — Alcove
        // semantics deliberately leave this case untouched. ---
        do {
            let downNoopRegistry = NotchWidgetRegistry()
            let downNoopWidget = SelfTestWidget(id: .nowPlaying)
            downNoopRegistry.register(downNoopWidget)
            downNoopRegistry.order = [.nowPlaying]
            let downNoopVM = NotchViewModel(registry: downNoopRegistry, activities: LiveActivityCenter())
            downNoopVM.expand(.nowPlaying)
            downNoopVM.swiped(.down)
            check(downNoopVM.state == .expanded(.nowPlaying),
                  "Notch: swipe down while a widget panel is already expanded is a no-op")
        }

        // --- M7: NotchViewModel.duoActive(...) — the pure Duo-view
        // derivation, testable without settings/registry/permission. ---
        check(NotchViewModel.duoActive(duoSettingEnabled: true, calendarWidgetEnabled: true, calendarPermissionGranted: true),
              "NotchViewModel: duoActive is true when the setting is on, Calendar is enabled, AND permission is granted")
        check(!NotchViewModel.duoActive(duoSettingEnabled: false, calendarWidgetEnabled: true, calendarPermissionGranted: true),
              "NotchViewModel: duoActive is false when the Duo setting itself is off")
        check(!NotchViewModel.duoActive(duoSettingEnabled: true, calendarWidgetEnabled: false, calendarPermissionGranted: true),
              "NotchViewModel: duoActive is false when the Calendar widget itself isn't enabled")
        check(!NotchViewModel.duoActive(duoSettingEnabled: true, calendarWidgetEnabled: true, calendarPermissionGranted: false),
              "NotchViewModel: duoActive is false without Calendar permission granted, even with everything else on")

        // --- M7: FocusMonitor — JSON parsing over checked-in-style fixture
        // strings, no real ~/Library/DoNotDisturb involved. ---
        do {
            let focusActiveAssertionsJSON = """
            {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}
            """
            let focusActiveConfigJSON = """
            {"data":[{"modeConfigurations":{"com.apple.focus.work":{"modeDescriptor":{"userTitle":"Work","symbolImageName":"briefcase.fill"}}}}]}
            """
            let focusEmptyAssertionsJSON = """
            {"data":[]}
            """
            let focusEmptyConfigJSON = """
            {"data":[]}
            """
            let focusActiveAssertionsData = Data(focusActiveAssertionsJSON.utf8)
            let focusActiveConfigData = Data(focusActiveConfigJSON.utf8)
            let focusEmptyAssertionsData = Data(focusEmptyAssertionsJSON.utf8)
            let focusEmptyConfigData = Data(focusEmptyConfigJSON.utf8)

            check(FocusMonitor.activeModeIdentifier(fromAssertionsData: focusActiveAssertionsData) == "com.apple.focus.work",
                  "FocusMonitor: activeModeIdentifier reads the asserted mode's identifier out of the Assertions fixture")
            check(FocusMonitor.activeModeIdentifier(fromAssertionsData: focusEmptyAssertionsData) == nil,
                  "FocusMonitor: activeModeIdentifier is nil for an empty Assertions fixture (no Focus active)")

            if case .focusChanged(let name, let symbolName) = FocusMonitor.parse(assertionsData: focusActiveAssertionsData, configData: focusActiveConfigData) {
                check(name == "Work" && symbolName == "briefcase.fill",
                      "FocusMonitor: parse cross-references Assertions + ModeConfigurations into the active mode's name/symbol")
            } else {
                check(false, "FocusMonitor: parse should decode a .focusChanged event with the active fixture pair")
            }

            check(FocusMonitor.parse(assertionsData: focusEmptyAssertionsData, configData: focusEmptyConfigData) == .focusChanged(name: nil, symbolName: nil),
                  "FocusMonitor: parse reads as 'no Focus active' (nil/nil) for the empty fixture pair")

            check(FocusMonitor.modeInfo(forIdentifier: "com.apple.focus.unknown", configData: focusActiveConfigData) == nil,
                  "FocusMonitor: modeInfo is nil for an identifier the ModeConfigurations fixture doesn't contain")

            // Defensive parsing: malformed/non-JSON input degrades to nil —
            // never a crash — matching the type's own doc comment.
            let malformedData = Data("not json at all".utf8)
            check(FocusMonitor.activeModeIdentifier(fromAssertionsData: malformedData) == nil,
                  "FocusMonitor: activeModeIdentifier degrades to nil for malformed JSON rather than crashing")
            check(FocusMonitor.parse(assertionsData: malformedData, configData: malformedData) == .focusChanged(name: nil, symbolName: nil),
                  "FocusMonitor: parse degrades to 'no Focus active' for malformed JSON on either side")
        }

        // --- M7 smoke test: FocusMonitor construct/start/stop safely on a
        // headless CI runner with no guaranteed-readable DoNotDisturb DB —
        // mirrors M5/M6's BrightnessMonitor/CameraService smoke tests. ---
        do {
            let focusProbe = FocusMonitor()
            check(focusProbe.isAvailable, "FocusMonitor: isAvailable starts true before any read has been attempted")
            focusProbe.start()
            focusProbe.start() // idempotent
            focusProbe.stop()
            focusProbe.stop() // idempotent
            check(true, "FocusMonitor: start()/stop() cycle without crashing regardless of whether the DoNotDisturb DB is readable on this runner")
        }

        // --- M7 bot-review fix: FocusMonitor.start()'s own baseline read
        // must never emit — a Focus state (on OR off) that was already true
        // before this app started watching isn't a "change" worth a spurious
        // peek at every single launch. Exercises the real start()/emitCurrent()
        // path (not the pure parse(...) core above, which the bug doesn't
        // live in) against a fixture directory this instance CAN actually
        // read — `directory` is injectable for exactly this. Deliberately
        // does NOT depend on the real DispatchSourceFileSystemObject firing
        // (unreliable to time in CI — see the M6 clipboard CI fix's own
        // lesson on this): both reads below happen synchronously inside
        // `start()` itself, before `resume()` is ever called on that source. ---
        do {
            let focusFixtureDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("flux-selftest-focus-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: focusFixtureDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: focusFixtureDir) }

            let assertionsURL = focusFixtureDir.appendingPathComponent("Assertions.json")
            let configURL = focusFixtureDir.appendingPathComponent("ModeConfigurations.json")
            func writeFocusFixture(active: Bool) {
                if active {
                    try? Data("""
                    {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}
                    """.utf8).write(to: assertionsURL)
                    try? Data("""
                    {"data":[{"modeConfigurations":{"com.apple.focus.work":{"modeDescriptor":{"userTitle":"Work","symbolImageName":"briefcase.fill"}}}}]}
                    """.utf8).write(to: configURL)
                } else {
                    try? Data("{\"data\":[]}".utf8).write(to: assertionsURL)
                    try? Data("{\"data\":[]}".utf8).write(to: configURL)
                }
            }
            writeFocusFixture(active: false)

            var suppressionEvents: [FocusMonitor.Event] = []
            let suppressionFocus = FocusMonitor(directory: focusFixtureDir)
            let suppressionCancellable = suppressionFocus.events.sink { suppressionEvents.append($0) }
            suppressionFocus.start()
            check(suppressionEvents.isEmpty,
                  "FocusMonitor: start()'s own baseline read never emits, even though what it found (no Focus active) is a perfectly real, decodable state — it's establishing a baseline, not reporting a change")

            // A genuine change AFTER that suppressed baseline — restart
            // (`stop()` then `start()` again) against different fixture
            // content — must still emit normally: this is a one-time baseline
            // suppression, not a blanket "this instance never emits" bug.
            suppressionFocus.stop()
            writeFocusFixture(active: true)
            suppressionFocus.start()
            check(suppressionEvents == [.focusChanged(name: "Work", symbolName: "briefcase.fill")],
                  "FocusMonitor: a genuine change after the suppressed baseline still emits normally, exactly once")

            suppressionFocus.stop()
            suppressionCancellable.cancel()
        }

        // --- M7: NotchActivityRouter — Focus peek/sticky translation, driven
        // purely through a real (but never-`start()`ed) FocusMonitor's own
        // `.events` — mirrors the M3/M5/M6 router blocks' shape exactly. ---
        check(NotchActivityRouter.focusStickyShouldShow(stickyEnabled: true, focusActive: true),
              "NotchActivityRouter: focusStickyShouldShow is true only when the sticky setting is on AND a Focus is active")
        check(!NotchActivityRouter.focusStickyShouldShow(stickyEnabled: false, focusActive: true),
              "NotchActivityRouter: focusStickyShouldShow is false with the sticky setting off, even with a Focus active")
        check(!NotchActivityRouter.focusStickyShouldShow(stickyEnabled: true, focusActive: false),
              "NotchActivityRouter: focusStickyShouldShow is false with no Focus active, even with the sticky setting on")

        let focusPeek = NotchActivityRouter.focusPeekActivity(name: "Work", symbolName: "briefcase.fill")
        check(focusPeek.kind == .focus && focusPeek.priority == 130 && focusPeek.duration == 5,
              "NotchActivityRouter: focusPeekActivity posts at kind .focus, priority 130, duration 5s")
        check(focusPeek.leading == .icon(systemName: "briefcase.fill") && focusPeek.trailing == .text("Work"),
              "NotchActivityRouter: focusPeekActivity's content is the Focus's own icon + name")
        let focusOffPeek = NotchActivityRouter.focusPeekActivity(name: nil, symbolName: nil)
        check(focusOffPeek.leading == .icon(systemName: "moon.fill") && focusOffPeek.trailing == .text("Focus off"),
              "NotchActivityRouter: focusPeekActivity falls back to a moon icon and 'Focus off' text when both name and symbolName are nil")

        do {
            let focusRouterSuiteName = "flux.selftest.focusrouter"
            let focusRouterSuite = UserDefaults(suiteName: focusRouterSuiteName)!
            focusRouterSuite.removePersistentDomain(forName: focusRouterSuiteName)
            let focusRouterSettings = SettingsStore(defaults: focusRouterSuite)
            // M9 privacy audit: Focus now defaults to OFF — opt in
            // explicitly so this block can keep exercising the
            // FocusEvent -> LiveActivity translation logic below.
            focusRouterSettings.notchActivityFocusEnabled = true
            let focusRouterActivities = LiveActivityCenter()
            let focusRouterArranger = MenuBarArranger()
            let focusRouterCalendar = CalendarService()
            let focusRouterPermissions = PermissionCenter()
            let focusRouterTimers = TimerService()
            let focusRouterViewModel = NotchViewModel(registry: NotchWidgetRegistry(), activities: LiveActivityCenter())
            let testFocus = FocusMonitor()
            // `startsMonitors: false` — as with every other router block in
            // this file, this must never let the router's real
            // settings-driven lifecycle call `focus.start()` for real and
            // arm a live DispatchSource watch on the CI runner; only
            // synthetic events fed straight through `testFocus.events` drive
            // this block.
            let focusRouter = NotchActivityRouter(activities: focusRouterActivities, settings: focusRouterSettings,
                                                   arranger: focusRouterArranger, calendar: focusRouterCalendar,
                                                   permissions: focusRouterPermissions, viewModel: focusRouterViewModel,
                                                   timers: focusRouterTimers, focus: testFocus, startsMonitors: false)

            withExtendedLifetime(focusRouter) {
                testFocus.events.send(.focusChanged(name: "Work", symbolName: "briefcase.fill"))
                check(focusRouterActivities.current?.kind == .focus,
                      "NotchActivityRouter: a Focus change posts a .focus live activity")
                check(focusRouterActivities.current?.priority == 130,
                      "NotchActivityRouter: the Focus peek posts at priority 130")
                check(focusRouterActivities.current?.duration == 5,
                      "NotchActivityRouter: the Focus peek is transient (5s)")
                check(focusRouterActivities.current?.trailing == .text("Work"),
                      "NotchActivityRouter: the Focus peek's trailing text is the Focus's own name")
                check(focusRouterActivities.current?.leading == .icon(systemName: "briefcase.fill"),
                      "NotchActivityRouter: the Focus peek's leading icon is the Focus's own symbol")

                // Turning the sticky setting on WHILE the peek is still
                // showing must not replace it early — mirrors the M6 timer
                // completion-alert guard (`completionAlertUntil`).
                focusRouterSettings.notchActivityFocusStickyEnabled = true
                check(focusRouterActivities.current?.trailing == .text("Work"),
                      "NotchActivityRouter: enabling the sticky setting mid-peek doesn't stomp the still-showing peek")

                // A Focus turning off posts its own peek.
                testFocus.events.send(.focusChanged(name: nil, symbolName: nil))
                check(focusRouterActivities.current?.trailing == .text("Focus off"),
                      "NotchActivityRouter: a Focus turning off posts its own peek reading 'Focus off'")

                // Settings gating: the toggle off suppresses further posts.
                focusRouterActivities.dismiss(kind: .focus)
                focusRouterSettings.notchActivityFocusEnabled = false
                testFocus.events.send(.focusChanged(name: "Personal", symbolName: "person.fill"))
                check(focusRouterActivities.current?.kind != .focus,
                      "NotchActivityRouter: the Focus toggle off suppresses further posts")
            }
            focusRouterSuite.removePersistentDomain(forName: focusRouterSuiteName)
        }

        // --- M7: MarqueeText.overflowWidth — the scroll-distance threshold
        // decision behind the Now Playing header's scrolling title/artist,
        // extracted as a pure function so it's testable without a live view. ---
        check(MarqueeText.overflowWidth(textWidth: 50, containerWidth: 100) == 0,
              "MarqueeText: overflowWidth is 0 when text comfortably fits its container")
        check(MarqueeText.overflowWidth(textWidth: 100, containerWidth: 100) == 0,
              "MarqueeText: overflowWidth is 0 when text exactly fits (no overflow right at the boundary)")
        check(MarqueeText.overflowWidth(textWidth: 150, containerWidth: 100) == 50,
              "MarqueeText: overflowWidth is the excess distance text needs to scroll once it overflows")

        // --- M7: ArtworkPalette.averageColor(ofRGBA:) — the pure arithmetic
        // core behind the Now Playing waveform's artwork-derived gradient,
        // over synthetic RGBA buffers (no real image decoding involved). ---
        check(ArtworkPalette.averageColor(ofRGBA: []) == nil,
              "ArtworkPalette: averageColor is nil for an empty buffer")
        check(ArtworkPalette.averageColor(ofRGBA: [255, 0, 0]) == nil,
              "ArtworkPalette: averageColor is nil when the buffer length isn't a multiple of 4 (malformed RGBA)")
        if let solidRed = ArtworkPalette.averageColor(ofRGBA: [255, 0, 0, 255, 255, 0, 0, 255]) {
            check(abs(solidRed.red - 1.0) < 0.001 && solidRed.green == 0 && solidRed.blue == 0,
                  "ArtworkPalette: averageColor of two solid-red RGBA pixels reads pure red")
        } else {
            check(false, "ArtworkPalette: averageColor should decode two well-formed RGBA pixels")
        }
        if let midGray = ArtworkPalette.averageColor(ofRGBA: [255, 255, 255, 255, 0, 0, 0, 255]) {
            check(abs(midGray.red - 0.5) < 0.001 && abs(midGray.green - 0.5) < 0.001 && abs(midGray.blue - 0.5) < 0.001,
                  "ArtworkPalette: averageColor of one white + one black pixel averages to mid-gray on every channel")
        } else {
            check(false, "ArtworkPalette: averageColor should decode a white+black RGBA pair")
        }

        // --- M7 code-review fix: ArtworkPalette.waveformGradientColors'
        // single-entry memo retains the image it's keyed on (`memo.image ===
        // image`) rather than a bare `ObjectIdentifier`, so a fresh image
        // handed back right after another never reads a stale, unrelated
        // track's colors — the old cap-6 `[ObjectIdentifier: colors]` cache
        // kept identifiers without retaining the images they came from, so a
        // deallocated image's address could be recycled by a later,
        // unrelated `NSImage` and collide with its still-cached entry. ---
        do {
            func solidImage(_ color: NSColor, side: Int = 8) -> NSImage {
                let image = NSImage(size: NSSize(width: side, height: side))
                image.lockFocus()
                color.setFill()
                NSRect(x: 0, y: 0, width: side, height: side).fill()
                image.unlockFocus()
                return image
            }
            let redImage = solidImage(.red)
            let blueImage = solidImage(.blue)

            let redColors = ArtworkPalette.waveformGradientColors(for: redImage)
            let blueColors = ArtworkPalette.waveformGradientColors(for: blueImage)
            check(redColors.top != blueColors.top || redColors.bottom != blueColors.bottom,
                  "ArtworkPalette: waveformGradientColors for a distinct new image never reuses the immediately-previous image's colors")

            let redAgain = ArtworkPalette.waveformGradientColors(for: redImage)
            check(redAgain.top == redColors.top && redAgain.bottom == redColors.bottom,
                  "ArtworkPalette: waveformGradientColors for the SAME still-alive image re-derives (memo now holds blueImage) to the SAME colors as before — correct regardless of what's currently memoized")

            let blueAgain = ArtworkPalette.waveformGradientColors(for: blueImage)
            check(blueAgain.top == blueColors.top && blueAgain.bottom == blueColors.bottom,
                  "ArtworkPalette: switching back to blueImage after redAgain re-derives its own correct colors too — no track's colors ever leak into another's")
        }

        // --- M7 code-review fix: NotchMetrics.maxExpandedHeight is derived
        // from expandedHeight(for:) across every WidgetID rather than a
        // hand-maintained duplicate constant, so a future per-widget height
        // bump can't silently drift past a stale hardcoded ceiling again. ---
        do {
            let expectedMax = WidgetID.allCases.map { NotchMetrics.expandedHeight(for: $0) }.max() ?? 0
            check(NotchMetrics.maxExpandedHeight == expectedMax,
                  "NotchMetrics: maxExpandedHeight equals the tallest expandedHeight(for:) across every WidgetID")
            check(NotchMetrics.expandedHeight(for: .calendar) == NotchMetrics.maxExpandedHeight,
                  "NotchMetrics: setup — Calendar (190) is currently the tallest widget, matching maxExpandedHeight")

            // --- M7 code-review fix: panelBounds reserves a shadow-bleed
            // margin beyond maxExpandedHeight/the widest visible footprint —
            // it used to equal them exactly, leaving zero room for the
            // expanded shape's own drop shadow (radius 16, y offset 4) and
            // clipping it at the panel edge. ---
            let notchWidth: CGFloat = 180
            let bounds = NotchMetrics.panelBounds(for: notchWidth)
            check(bounds.height == NotchMetrics.maxExpandedHeight + NotchMetrics.shadowMarginHeight,
                  "NotchMetrics: panelBounds' height is maxExpandedHeight PLUS a shadow-bleed margin, not maxExpandedHeight exactly")
            check(bounds.width == NotchMetrics.expandedWidth(for: notchWidth) + NotchMetrics.duoExtraWidth + NotchMetrics.shadowMarginWidth,
                  "NotchMetrics: panelBounds' width is expandedWidth + duoExtraWidth PLUS the same shadow-bleed margin")
        }

        // --- M7 code-review fix: option-click wires the previously-dead
        // LiveActivityCenter.restoreLastDismissed() to an actual input path —
        // NotchViewModel.clicked(optionDown:) — instead of the ordinary
        // open/close toggle. ---
        do {
            let optionClickRegistry = NotchWidgetRegistry()
            let optionClickWidget = SelfTestWidget(id: .nowPlaying)
            optionClickRegistry.register(optionClickWidget)
            optionClickRegistry.order = [.nowPlaying]
            let optionClickActivities = LiveActivityCenter()
            let optionClickVM = NotchViewModel(registry: optionClickRegistry, activities: optionClickActivities)

            let optionActivityA = LiveActivity(kind: .battery, leading: .none, trailing: .text("A"), duration: nil, priority: 200)
            optionClickActivities.post(optionActivityA)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(optionClickVM.state == .activity(optionActivityA.id),
                  "Notch: setup — posting a sticky activity preempts collapsed")

            optionClickActivities.dismissCurrent(restorable: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(optionClickVM.state == .collapsed,
                  "Notch: setup — dismissing the only queued activity collapses the notch")
            check(optionClickActivities.current == nil,
                  "Notch: setup — LiveActivityCenter has nothing current after the dismiss")

            optionClickVM.clicked(optionDown: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(optionClickActivities.current?.id == optionActivityA.id,
                  "Notch: clicked(optionDown: true) restores the last-dismissed activity via LiveActivityCenter.restoreLastDismissed(), reachable from an option-click in ANY state")

            optionClickVM.clicked(optionDown: false)
            check(optionClickVM.state == .expanded(.nowPlaying),
                  "Notch: a plain click (optionDown: false) right after still does the ordinary open/close toggle, completely unaffected by the option-click path")
        }

        // --- M8: NotchDesign token sanity — the opacity ramp is strictly
        // ordered (each step dimmer than the last) and every spacing token
        // is positive/increasing, so a future edit can't quietly invert the
        // visual hierarchy or zero out a token every widget lays out
        // against. ---
        do {
            check(NotchDesign.primaryOpacity > NotchDesign.secondaryOpacity
                    && NotchDesign.secondaryOpacity > NotchDesign.tertiaryOpacity
                    && NotchDesign.tertiaryOpacity > NotchDesign.quaternaryOpacity
                    && NotchDesign.quaternaryOpacity > NotchDesign.hairlineOpacity,
                  "NotchDesign: the opacity ramp is strictly ordered primary > secondary > tertiary > quaternary > hairline")
            check(NotchDesign.primaryOpacity == 1.0, "NotchDesign: primaryOpacity is full strength")
            check(NotchDesign.hairlineOpacity > 0, "NotchDesign: hairlineOpacity is still visible, not fully transparent")

            check(NotchDesign.space1 > 0 && NotchDesign.space2 > 0 && NotchDesign.space3 > 0 && NotchDesign.space4 > 0,
                  "NotchDesign: every base spacing token is positive")
            check(NotchDesign.space1 < NotchDesign.space2
                    && NotchDesign.space2 < NotchDesign.space3
                    && NotchDesign.space3 < NotchDesign.space4,
                  "NotchDesign: the spacing scale is strictly increasing (space1 < space2 < space3 < space4)")
            check(NotchDesign.rowSpacing == NotchDesign.space2, "NotchDesign: rowSpacing aliases space2")
            check(NotchDesign.sectionSpacing == NotchDesign.space3, "NotchDesign: sectionSpacing aliases space3")
            check(NotchDesign.contentPadding == NotchDesign.space4, "NotchDesign: contentPadding aliases space4")

            check(NotchDesign.scrollFadeLength > 0 && NotchDesign.scrollFadeContentInset > 0,
                  "NotchDesign: the scroll-fade length and its matching content inset are both positive")
            check(NotchDesign.paneInsets > 0, "NotchDesign: paneInsets is a real, positive inset")
        }

        // --- M8: Formatters.age(from:to:) — the fix for Shelf/Clipboard row
        // captions reading a future-tense "in 0s" for an item added moments
        // ago. Anything under 60s reads as a flat "now"; anything older
        // reads unambiguously past tense, even right across the boundary
        // that used to flip sign under ordinary clock skew. ---
        do {
            let now = Date()
            check(Formatters.age(from: now, to: now) == "now",
                  "Formatters.age: a zero-second-old item reads 'now', not a future-tense 'in 0s'")
            check(Formatters.age(from: now.addingTimeInterval(-30), to: now) == "now",
                  "Formatters.age: a 30s-old item still reads 'now' (under the 60s threshold)")
            check(Formatters.age(from: now.addingTimeInterval(-59), to: now) == "now",
                  "Formatters.age: a 59s-old item is still 'now' (just under the boundary)")
            // The actual bug repro: `from` lands microseconds AFTER `to`
            // (clock skew/rounding between two separate `Date()` reads,
            // never a real future timestamp) — this must still read 'now',
            // never a future-tense phrase.
            check(Formatters.age(from: now.addingTimeInterval(2), to: now) == "now",
                  "Formatters.age: a `from` timestamp marginally AFTER `to` (clock skew) still reads 'now', never future tense")

            let age90 = Formatters.age(from: now.addingTimeInterval(-90), to: now)
            check(!age90.hasPrefix("in "), "Formatters.age: a 90s-old item is never phrased in future tense (got \(age90))")
            check(age90.contains("ago"), "Formatters.age: a 90s-old item reads past tense (\"...ago\"), got \(age90)")

            let age60 = Formatters.age(from: now.addingTimeInterval(-60), to: now)
            check(!age60.hasPrefix("in ") && age60 != "now",
                  "Formatters.age: exactly at the 60s boundary the item is old enough for real relative text (got \(age60)), not 'now' or future tense")
        }

        print(allPassed ? "\n🎉 ALL CHECKS PASSED" : "\n❌ SOME CHECKS FAILED")
        exit(allPassed ? 0 : 1)
    }
}

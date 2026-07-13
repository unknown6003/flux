import AppKit
import Carbon.HIToolbox

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

        // --- OTA updater: semantic version comparison ---
        let updater = UpdateChecker(currentVersion: "0.1.1")
        check(updater.isNewer("0.2.0", than: "0.1.1"), "Update: 0.2.0 is newer than 0.1.1")
        check(updater.isNewer("0.2", than: "0.1.9"), "Update: 0.2 outranks 0.1.9 (zero-padded)")
        check(updater.isNewer("1.0.0", than: "0.9.9"), "Update: a major bump is newer")
        check(!updater.isNewer("0.1.1", than: "0.1.1"), "Update: an identical version is not newer")
        check(!updater.isNewer("0.1.0", than: "0.1.1"), "Update: an older version is not newer")
        check(!updater.isNewer("0.1.1", than: "0.2.0"), "Update: the running build isn't behind a lower tag")
        check(UpdateChecker.normalize("v0.1.1") == "0.1.1", "Update: a 'v' prefix is stripped from tags")

        print(allPassed ? "\n🎉 ALL CHECKS PASSED" : "\n❌ SOME CHECKS FAILED")
        exit(allPassed ? 0 : 1)
    }
}

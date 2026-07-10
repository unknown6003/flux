import AppKit

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

        // Seeding puts the chevron rightmost and the Always-Hidden divider far left.
        layoutSuite.removeObject(forKey: posKey("flux.divider.alwaysHidden"))
        ControlItem.assignDefaultPositionsIfUnset(defaults: layoutSuite)
        let posChevron = layoutSuite.double(forKey: posKey("flux.chevron"))
        let posHidden = layoutSuite.double(forKey: posKey("flux.divider.hidden"))
        let posAlways = layoutSuite.double(forKey: posKey("flux.divider.alwaysHidden"))
        check(posChevron < posHidden,
              "Layout: chevron (\(Int(posChevron))) seeds right of the Hidden divider (\(Int(posHidden)))")
        check(posAlways > posHidden + 100,
              "Layout: Always-Hidden divider (\(Int(posAlways))) seeds far left of Hidden (\(Int(posHidden))) → empty zone")
        layoutSuite.removePersistentDomain(forName: layoutSuiteName)

        // --- MenuBarManager: full state machine, asserting REAL bar geometry ---
        // Clean slate so defaults are deterministic (autoHideOnLaunch=true,
        // showAlwaysHiddenSection=true).
        let suiteName = "flux.selftest"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let arranger = MenuBarArranger()
        let manager = MenuBarManager(settings: settings, arranger: arranger, onOpenSettings: {})

        func isHidden(_ length: CGFloat?) -> Bool { (length ?? 0) > 5_000 }
        func isRevealed(_ length: CGFloat?) -> Bool { (length ?? 99) < 5 }

        // Launch state: auto-hide on → everything collapsed, chevron shows ‹.
        let s0 = manager.diagnostics
        check(!s0.revealHidden && !s0.revealAlwaysHidden,
              "Launches collapsed when auto-hide-on-launch is on")
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

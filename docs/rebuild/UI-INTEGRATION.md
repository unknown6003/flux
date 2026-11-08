# FluxUI integration

FluxUI is an AppKit-only Swift 6 library. It has no SwiftUI, WebKit, timers, background tasks, global event monitors, telemetry, persistence, network or hardware calls. Every type that owns a view is `@MainActor`. State comes in from the parent and requests go out through callbacks.

## Status

- **Not compiled.** This Linux host has no Swift or macOS SDK. The root must compile on macOS.
- **Not run.** No layout, focus, VoiceOver or keyboard behavior is proven yet.
- The optional 1–5 rating view is not written.

## Manifest (root owns it)

```swift
.target(name: "FluxUI", dependencies: ["FluxCore"], path: "Sources/FluxUI")
```

FluxUI uses these FluxCore types: `ApplicationID`, `MenuBarGroup`, `MenuBarCapability`, `Widget`, `Appearance`. It adds an internal `Widget.displayName` extension. It declares no public name that FluxCore already has.

Strings use `NSLocalizedString` with table `FluxUI` in `Bundle.main`. The English text is the fallback.

## Files

| File | Public API |
|---|---|
| `Sources/FluxUI/FluxUIStyle.swift` | `FluxUIStyle.accent` (amber, darker in light mode) |
| `Sources/FluxUI/SettingsWindowController.swift` | `SettingsPage`, `SettingsPageFocus`, `SettingsWindowController` |
| `Sources/FluxUI/MenuBarPreferencesModel.swift` | `MenuBarPageMode`, `MenuBarApplyResult`, `MenuBarAppRow`, `MenuBarPageState`, `MenuBarPageActions` |
| `Sources/FluxUI/MenuBarPreferencesController.swift` | `MenuBarPreferencesController` |
| `Sources/FluxUI/AnalyticsSettingsView.swift` | `AnalyticsStatus`, `AnalyticsSettingsView` |
| `Sources/FluxUI/PermissionCardView.swift` | `PermissionCardView`, `PermissionCardView.Content` |
| `Sources/FluxUI/NotchPanelController.swift` | `NotchGeometry`, `NotchPanelController` |
| `Sources/FluxUI/FormPageController.swift` | `FormPageController`, `UpdateStatus` |
| `Sources/FluxUI/ShortcutRecorderView.swift` | `Shortcut` |
| `Sources/FluxUI/GeneralPreferencesController.swift` | `LoginStatus`, `ShortcutConflict`, `GeneralPreferencesState`, `GeneralPreferencesAction`, `GeneralPreferencesController` |
| `Sources/FluxUI/AboutPreferencesController.swift` | `DiagnosticStatus`, `AboutPreferencesState`, `AboutPreferencesAction`, `AboutPreferencesController` |

## Settings window

```swift
let settings = SettingsWindowController(initialPage: .general) { page in
    switch page {
    case .menuBar: return MenuBarPreferencesController(state: state, actions: actions)
    default: return parentMadePage(page)
    }
}
settings.onPageWillDisappear = { page in /* stop page work, e.g. icon capture */ }
settings.onClose = { [weak self] in self?.settings = nil }
settings.show()           // or settings.show(.menuBar)
```

- The factory runs only for the selected page. On a switch, the old controller and its view are removed and released. Nothing is cached.
- Bind the "Settings…" menu item (⌘,) to `show(_:)`. Esc closes the window.
- A page that adopts `SettingsPageFocus` gets its `preferredFirstResponder` focused when `show(_:)` opens it.
- Teardown: `onClose` runs once, after the page is discarded. Release the controller there. The window has `isReleasedWhenClosed = false`.
- Sidebar groups follow the design: **Flux** (Menu Bar, Notch, Lock Screen) and **System** (General, About).
- FluxUI now gives the General and About pages. Root must still build the Notch and Lock Screen page contents. FluxUI gives the permission cards for them.

## Menu Bar page

`MenuBarPreferencesController(state:actions:)`, then `update(_:)` with a full new `MenuBarPageState` after each change.

- Rows are kept by `ApplicationID`. A name, icon, width or title change never drops a row or rejects a choice. The focused row keeps focus when it moves to another lane.
- Each row has a Shown / Hidden / Always segmented control. `isFixed` rows (default: `id.isManagedBySystem`) show "Managed by macOS" and no control. The Always segment is off when `alwaysHiddenEnabled` is false, and those rows sit in the Hidden lane.
- The segmented control calls `actions.assign(id, group)` only. The UI does not move the row by itself. The parent sends the new state.
- `MenuBarApplyResult` is separate from `group`. Only `.savedInMacOS` shows "Saved in macOS", and the parent may set it only after a passed policy read-back. `.asked` says Flux asked macOS. `.notMovedYet` is for by-position mode. The status line uses the last row that has a result, and VoiceOver announces it once.
- `mode`: `.perApplication`, `.byPosition`, `.needsAccessibility` (lanes are replaced by one Accessibility card with Open Settings and Check Again), `.paused`, `.failed(code:)`. `MenuBarPageMode(_ capability: MenuBarCapability)` maps `.unavailable` to `.paused`. Set `savedLayoutStillApplies` to show "Flux can't read icons. Your saved layout still hides them."
- Arrange: `beginArrange` asks the parent to reveal all icons and set `isArranging = true`. The card teaches ⌘-drag, with Done and Esc, which both call `endArrange`. There is no Cancel or Undo for OS moves. Flux never moves icons. There is no in-window drag.
- `showRealIcons` only calls the parent. The parent owns Screen Recording, capture, the 3-second deadline and stopping capture in `onPageWillDisappear`. Set `showsRealIcons` and `preview` per row to show captured glyphs. App icons work without Screen Recording.
- `refresh`, `checkAccessibility`, `openAccessibilitySettings`, `reviewIdentity(id)` only call the parent. Rows with `needsIdentityReview` also show a Review row at the top.
- `isRefreshing` shows the static text "Reading the menu bar…". There is no spinner.
- Search is local and matches the name or the bundle ID.
- Parent owns: backend, deadlines, undo of a saved choice, read-back, and the Always Hidden, re-hide delay, icon style and spacing options below the lanes.

## Analytics group (General)

```swift
let analytics = AnalyticsSettingsView(status: collection.enabled ? .on : .off)
analytics.onSetEnabled = { on in analytics.update(.working); Task { await collection.setEnabled(on); analytics.update(on ? .on : .off) } }
analytics.onResetID = { analytics.update(.working); Task { await collection.resetIdentity(); analytics.update(.reset) } }
```

- Default state is `.off`. Pass `.on` only after a saved opt-in.
- The view never shows or logs the ID. It never sends anything.
- Copy names only fixed feature names, results, error codes and a random ID. It does not mention OS versions, replay, surveys, autocapture or crash reports.
- Off text says requests already received can't be recalled. Reset text says data sent before stays with the old ID.
- The `Task` above is the parent's code, not FluxUI's.

## Permission and empty-state cards

`PermissionCardView(content: .init(symbolName:title:message:actionTitle:secondaryTitle:))`, then set `onAction` and `onSecondary`. Use `Content.empty(symbolName:message:)` for one-line empty states such as "No events today". Show a card only inside the feature that needs the grant.

## Notch panel

```swift
let geometry = NotchGeometry(screenFrame: screen.frame,
                             topLeftArea: screen.auxiliaryTopLeftArea,
                             topRightArea: screen.auxiliaryTopRightArea,
                             menuBarHeight: NSStatusBar.system.thickness)
let panel = NotchPanelController(widgets: enabledInSavedOrder, geometry: geometry) { widget in
    parentWidgetController(widget)
}
panel.onWillSwitch = { from, to in /* stop camera/media of `from` */ }
panel.onWillDismiss = { widget in /* stop all widget hardware */ }
```

- The root view is a solid black `CAShapeLayer` with a 28 pt bottom radius, always in dark appearance. The camera area (`cameraRect`) is an empty spacer.
- `wingRect(extent:)` is the notch plus up to 40 pt per side. `expandedRect(contentHeight:)` is up to 440 pt wide and never wider than the screen. With no notch, `cameraWidth` is 0.
- Exactly one widget controller is a child at a time. `show(_:)`, `setWidgets(_:)`, `dismiss()`. On a switch or dismiss, the callback runs first, then the old child is removed and released.
- Keys: ← → switch tabs when the panel has focus. Esc dismisses and orders the window out. `viewDidDisappear` also dismisses, so no widget stays loaded while hidden.
- Reduce Motion: the 0.15 s fade between widgets is skipped.
- The parent owns the panel window, hover zone, hotkey, closed and wing states, and every camera or media session.

## Proof the root must run

1. Compile FluxUI on macOS with Swift 6 strict concurrency.
2. Keyboard pass: sidebar arrows, ⌘,, Esc, Tab through Menu Bar rows, ← → in the notch.
3. VoiceOver reads each row as "name, count, group" and announces the status line.
4. Memory: switching pages and closing Settings releases page controllers; switching notch tabs releases the old widget.

## Layout fix (slice 2)

The fixture captures at `build/native-ui-d8a951d` and `build/native-ui-51d1d63` showed the lane groups at zero height, with rows drawn over the lane headers. The cause was in FluxUI. `FluxUIStyle.group` put a stack view in `NSBox.contentView`. NSBox sizes its content view by autoresizing, so the stack's constraints never set the box height.

- `FluxUIStyle.group` now returns `GroupView`. It pins its content with constraints and 10/12 pt insets, so its height follows the content. It fills with `quaternarySystemFill`, resolved for the view's appearance in `updateLayer`.
- `FluxUIStyle.page(_:)` is the shared page root: a vertical scroll view with a flipped document that is as wide as the clip view and as tall as the content.
- `vstack` uses `.width` alignment by default, so the search field, groups and rows fill the page width at 680 and 840 pt.
- Wrapping labels have low horizontal compression resistance. App names use one line with tail truncation and a tooltip. Segmented controls, buttons and "Managed by macOS" resist compression, so the group choices stay reachable.
- Not proven: no new capture has run with this fix. The root probe must capture again on macOS.
- The probe's General fixture hosts `AnalyticsSettingsView` with no bottom constraint. That is valid, because the view now has a fitting height.

## Slice 2 additions

- `FormPageController` (public base class): builds a page from sections of native controls. On `rebuild()` it restores focus to the control with the same identifier.
- `UpdateStatus` (public enum): `.idle`, `.checking`, `.upToDate`, `.available(version:)`, `.installing`, `.failed(code:)`.
- `Shortcut(keyCode:carbonModifiers:)` (public) and the internal `ShortcutRecorderView`. The recorder reads only `keyDown` and `performKeyEquivalent` while it is first responder. It installs no event monitor. Esc cancels. A shortcut must have ⌘, ⌃ or ⌥.

## General page (slice 3)

```swift
let general = GeneralPreferencesController(state: GeneralPreferencesState(
    launchAtLoginRequested: store.value(for: Preferences.launchAtLogin),
    loginStatus: .disabled,              // mapped from SMAppService.mainApp.status
    hotkeysEnabled: store.value(for: Preferences.enableHotkey),
    revealShortcut: Shortcut(keyCode: 3, carbonModifiers: 6400),
    revealConflict: .clear,
    notchShortcut: Shortcut(keyCode: 45, carbonModifiers: 6400),
    notchConflict: .clear,
    appearance: store.value(for: Preferences.appearance),
    automaticUpdateChecks: store.value(for: Preferences.automaticUpdateChecks),
    update: .idle,
    analytics: .off                      // .on only after a saved opt-in
)) { action in parentHandle(action) }
general.update(state: next)              // after each saved change
```

The `store.value(for:)` calls are the parent's reads. FluxUI reads nothing.

State fields, all `let`: `launchAtLoginRequested: Bool`, `loginStatus: LoginStatus` (`.disabled`, `.enabled`, `.requiresApproval`, `.unavailable`), `hotkeysEnabled: Bool`, `revealShortcut: Shortcut`, `revealConflict: ShortcutConflict`, `notchShortcut: Shortcut`, `notchConflict: ShortcutConflict` (`.clear`, `.otherFluxShortcut`, `.unavailable`), `appearance: Appearance`, `automaticUpdateChecks: Bool`, `update: UpdateStatus`, `analytics: AnalyticsStatus`. The conflicts, update and analytics fields have defaults: `.clear`, `.idle`, `.off`.

`GeneralPreferencesAction` cases: `.setLaunchAtLogin(Bool)`, `.openLoginItems`, `.setHotkeysEnabled(Bool)`, `.setRevealShortcut(Shortcut)`, `.setNotchShortcut(Shortcut)`, `.setAppearance(Appearance)`, `.setAutomaticUpdateChecks(Bool)`, `.checkForUpdates`, `.installUpdate`, `.setAnalyticsEnabled(Bool)`, `.resetAnalyticsID`.

- Sections: Startup, Keyboard shortcuts, Appearance, Updates, then the existing `AnalyticsSettingsView`. The page owns one analytics view and routes its two callbacks into the action enum.
- The login switch shows the requested value. Its helper text names the effective status. `.unavailable` turns the switch off for input but keeps the value. `.requiresApproval` adds a "Needs approval in Login Items" row with Open Login Items.
- Each recorder sends one action. It reads keys only while it has focus, through `ShortcutRecorderView`. With global shortcuts off, both recorders are off for input and keep their values. Each recorder shows its own conflict text.
- The update button says Install Update only for `.available(version:)`. Otherwise it says Check for Updates. It is off while `.checking` or `.installing`.
- `update(state:)` ignores an equal state. Otherwise it rebuilds the rows and gives focus back to the control with the same identifier. It never sends an action.
- Identifiers: `general.login`, `general.login.approve`, `general.hotkeys`, `general.shortcut.reveal`, `general.shortcut.notch`, `general.appearance`, `general.updates.auto`, `general.updates.action`, `analytics.enabled`, `analytics.reset`.
- Parent owns: saving, `SMAppService`, opening Login Items, Carbon registration and conflict checks, the update checker and installer, and `UsageCollection`.

## About page (slice 3)

```swift
let about = AboutPreferencesController(state: AboutPreferencesState(
    version: bundleShortVersion, build: bundleVersion,   // from Bundle.main
    update: .idle, diagnostics: .ready
)) { action in parentHandle(action) }
about.update(state: next)
```

State fields, all `let`: `version: String`, `build: String`, `update: UpdateStatus`, `diagnostics: DiagnosticStatus` (`.ready`, `.copied`, `.unavailable`).

`AboutPreferencesAction` cases: `.checkForUpdates`, `.installUpdate`, `.copyDiagnosticReport`, `.openMediaRemoteAdapterLicense`, `.openSourceRepository`.

- Shows "Flux", "Version <version> (<build>)" exactly as passed, and the design's trust note "Self-signed. Not notarized." Then Updates, Diagnostics and Credits.
- Diagnostic text is fixed per status. The page never shows the report, logs, error text or IDs. Copy is off for `.unavailable`.
- Credits name MediaRemoteAdapter by Jonas van den Berg and contributors, BSD 3-Clause (`Vendor/mediaremote-adapter/LICENSE`). The parent opens the license and the source repository.
- Identifiers: `about.updates.action`, `about.diagnostics.copy`, `about.credits.license`, `about.credits.source`.

## Teardown

Both pages hold no timers, monitors, tasks or observers. Control closures live in the page and capture it weakly. Settings releases the page on a page switch or close. The parent drops any reference it kept in `onPageWillDisappear` or `onClose`. A late `update(state:)` before the view loads only stores the state.

## Not written yet

- The Notch and Lock Screen page controllers.
- The fixed 1–5 feedback form. A later About action can carry a FluxCore `UsageRating`.
- The General Permissions list and the About crash report banner from the design.
- General and About are not compiled or run. This host has no Swift. The root's macOS build and capture must prove them.

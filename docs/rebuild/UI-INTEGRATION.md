# FluxUI integration

FluxUI is an AppKit-only Swift 6 library. It has no SwiftUI, WebKit, timers, background tasks, global event monitors, telemetry, persistence, network or hardware calls. Every type that owns a view is `@MainActor`. State comes in from the parent and requests go out through callbacks.

## Status

- **Slice 4 not compiled.** This Linux host has no Swift or macOS SDK. The parent reports that General and About compiled and four UI tests passed on Mac CI run 42517294441 at 430ad53. The Notch, Lock Screen and rating files have no compile yet.
- **Not run.** No layout, focus, VoiceOver or keyboard behavior is proven yet.
- The fixed 1 to 5 rating form is written but not compiled or run.
- **Slice 6 not compiled.** The Now Playing, Calendar and Mirror widget controllers were written on Linux at base 6f1d987. They have no compile or run yet.
- **Slice 5 not compiled.** Menu Bar options, General Permissions, the About crash notice and the focus fallback have no compile yet. The parent's CI at c380847 stopped at Platform isolation before tests, so it does not prove that FluxUI compiles at the latest commit.

## Manifest (root owns it)

```swift
.target(name: "FluxUI", dependencies: ["FluxCore"], path: "Sources/FluxUI")
```

FluxUI uses these FluxCore types: `ApplicationID`, `MenuBarGroup`, `MenuBarCapability`, `Widget`, `ExpansionTrigger`, `Appearance`, `UsageRating`. It adds an internal `Widget.displayName` extension with the five existing names: Now Playing, File Shelf, Calendar, Mirror, Clipboard. It declares no public name that FluxCore already has.

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
| `Sources/FluxUI/NotchPreferencesController.swift` | `WidgetPreference`, `ShelfExpiry`, `NotchActivity`, `NotchAccessKind`, `NotchAccessStatus`, `NotchPreferencesState`, `NotchPreferencesAction`, `NotchPreferencesController` |
| `Sources/FluxUI/LockScreenPreferencesController.swift` | `LockScreenCapability`, `LockScreenPreferencesState`, `LockScreenPreferencesAction`, `LockScreenPreferencesController` |
| `Sources/FluxUI/FeedbackRatingController.swift` | `FeedbackSubmission`, `FeedbackRatingState`, `FeedbackRatingAction`, `FeedbackRatingController` |
| `Sources/FluxUI/NowPlayingWidgetController.swift` | `NowPlayingSourceOption`, `NowPlayingWidgetStatus`, `NowPlayingWidgetState`, `NowPlayingWidgetAction`, `NowPlayingWidgetController` |
| `Sources/FluxUI/CalendarWidgetController.swift` | `CalendarWidgetColor`, `CalendarWidgetEvent`, `CalendarWidgetState`, `CalendarWidgetAction`, `CalendarWidgetController` |
| `Sources/FluxUI/MirrorWidgetController.swift` | `MirrorWidgetStatus`, `MirrorWidgetAction`, `MirrorWidgetController` |
| `Sources/FluxUI/NotchWidgetStyle.swift` | none (internal `NotchWidgetStyle`, `NotchCardHost`) |

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
- FluxUI gives all five pages: `MenuBarPreferencesController`, `NotchPreferencesController`, `LockScreenPreferencesController`, `GeneralPreferencesController`, `AboutPreferencesController`.

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
- Parent owns: backend, deadlines, undo of a saved choice, read-back, and saving the options below the lanes.

## Menu Bar options (slice 5)

`MenuBarPageState.options: MenuBarOptions` (default `MenuBarOptions()`) and the existing `alwaysHiddenEnabled` drive two sections below the tools. They show in every mode, also without Accessibility, because they are saved values only.

| Row | Identifier | State | Action | Saved key |
|---|---|---|---|---|
| Always Hidden group | `menuBar.option.always` | `alwaysHiddenEnabled` | `.setAlwaysHiddenEnabled(Bool)` | `Preferences.alwaysHiddenEnabled` |
| Hide icons again | `menuBar.option.rehide` | `options.autoRehide` (true) | `.setAutoRehide(Bool)` | `Preferences.autoRehide` |
| Delay | `menuBar.option.delay` | `options.autoRehideDelay` (8) | `.setAutoRehideDelay(TimeInterval)` | `Preferences.autoRehideDelay` |
| Compact icon spacing | `menuBar.option.spacing` | `options.compactSpacing: Bool?` (nil) | `.setCompactSpacing(Bool)` | none in Core |
| Flux icon in the menu bar | `menuBar.option.icon` | `options.iconStyle` (`.chevron`) | `.setIconStyle(MenuBarIcon)` | `Preferences.iconStyle` |

- **Breaking:** `MenuBarPageActions.init` now needs `setOption: (MenuBarOptionAction) -> Void`. It has no default, so a missing handler fails the build instead of dropping saves. `Scripts/rebuild/UIProbe/UIProbe.swift:74` must pass one.
- Delay is a pop-up: 2, 3, 5, 8, 10, 15, 20, 30 s, plus the saved value if it is another value. The old range 2 to 30 s clamps the shown value. Delay is off while re-hide is off.
- Compact spacing is hidden while `compactSpacing` is nil. Core has no saved key. The old app wrote `NSStatusItemSpacing` in the current-host global domain. The parent owns that write and the read-back. The helper text says only that it may need a new login.
- The section rebuilds only when `options` or `alwaysHiddenEnabled` change, and keeps focus by identifier. FluxUI makes no OS calls for these rows.

## General Permissions (slice 5)

`GeneralPreferencesState.permissions: [PermissionRow]` (default empty, which hides the section). The section sits before Analytics, in the order the parent sends.

- `PermissionRow(kind: PermissionKind, status: PermissionStatus)`.
- `PermissionKind`: `.accessibility`, `.screenRecording`, `.calendar`, `.camera`, `.bluetooth`. Each has a fixed title and a fixed line that names the feature that uses it.
- `PermissionStatus`: `.allowed`, `.notAsked`, `.notAllowed`, `.unknown`. Fixed text only.
- Rows that are not `.allowed` show Open Settings, identifier `general.permission.<kind>`, which sends `.openPermissionSettings(kind)`. The parent opens the System Settings pane. It must not show a macOS permission prompt for this action, and must not read Screen Recording status in a way that prompts. Send `.unknown` when it can't read a status without a prompt.

## About crash notice (slice 5)

`AboutPreferencesState.crashNotice: CrashNotice` (default `.none`).

- `.previousSessionUnclean(cameraWasRunning: Bool)` shows a banner under the version: a fixed title, a fixed detail that names crash, Force Quit and logout as causes, and one more fixed line when the camera was on. It shows no log text, paths, codes or error content.
- Copy Diagnostic Report (`about.crash.copy`) sends the existing `.copyDiagnosticReport` and follows `diagnostics`. Dismiss (`about.crash.dismiss`) sends `.dismissCrashNotice`. The parent saves the dismissal and sends `.none`.

## Focus fallback (slice 5)

`FormPageController.rebuild()` and the Menu Bar options section use `FormControls.restoreFocus`. If the focused control is disabled after the new state, for example Move Up on the new first widget, focus goes to the nearest enabled control in the same row. On a tie the later control wins, so a disabled Up goes to Down and a disabled Down goes to Up. If the row has no enabled control, focus does not move to a disabled one. The control helpers moved from `FormPageController` into `FormControls`. The page methods `toggle`, `popup` and `button` keep their signatures.

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
- `vstack` uses `.leading` alignment and `WidthStackView`, which gives each arranged view an explicit width constraint equal to the stack. Groups and rows fill the page width at 680 and 840 pt. No FluxUI code uses `.alignment = .width`.
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

## Notch page (slice 4)

```swift
let notch = NotchPreferencesController(state: NotchPreferencesState(
    isEnabled: store.value(for: Preferences.notchEnabled),
    trigger: store.value(for: Preferences.expansionTrigger),
    hoverCloseDelay: store.value(for: Preferences.hoverCloseDelay),
    showInFullscreen: store.value(for: Preferences.showInFullscreen),
    widgets: savedOrder.map { WidgetPreference(widget: $0, isEnabled: enabled($0)) },
    duoEnabled: store.value(for: Preferences.duoEnabled),
    shelfExpiry: ShelfExpiry(rawValue: Int(store.value(for: Preferences.shelfExpiryDays))) ?? .never,
    clipboardSaving: store.value(for: Preferences.clipboardPersistenceEnabled),
    enabledActivities: savedActivities,      // Set<NotchActivity>
    calendarAccess: .notAsked, cameraAccess: .notAsked, accessibilityAccess: .allowed  // parent reads, never prompts
)) { action in parentHandle(action) }
notch.update(state: next)
```

The `store` reads, `savedOrder`, `enabled(_:)` and `savedActivities` are the parent's. Every field is required. There are no defaults.

State fields, all `let`: `isEnabled: Bool`, `trigger: ExpansionTrigger`, `hoverCloseDelay: Double` (seconds), `showInFullscreen: Bool`, `widgets: [WidgetPreference]` (all five in saved order; `WidgetPreference(widget: Widget, isEnabled: Bool)`), `duoEnabled: Bool`, `shelfExpiry: ShelfExpiry` (`.never` = 0, `.oneDay` = 1, `.threeDays` = 3, `.sevenDays` = 7, the raw value of `flux.notch.shelf.expiryDays`), `clipboardSaving: Bool`, `enabledActivities: Set<NotchActivity>` (`.battery`, `.bluetooth`, `.calendarEvent`, `.timer`, `.soundHUD`), `calendarAccess`, `cameraAccess`, `accessibilityAccess: NotchAccessStatus` (`.allowed`, `.notAsked`, `.denied`, `.unavailable`).

`NotchPreferencesAction` cases: `.setEnabled(Bool)`, `.setTrigger(ExpansionTrigger)`, `.setHoverCloseDelay(Double)`, `.setShowInFullscreen(Bool)`, `.setWidgetEnabled(Widget, Bool)`, `.moveWidgetUp(Widget)`, `.moveWidgetDown(Widget)`, `.setDuoEnabled(Bool)`, `.setShelfExpiry(ShelfExpiry)`, `.setClipboardSaving(Bool)`, `.clearClipboardHistory`, `.setActivity(NotchActivity, Bool)`, `.requestAccess(NotchAccessKind)`, `.openAccessSettings(NotchAccessKind)`. `NotchAccessKind`: `.calendar`, `.camera`, `.accessibility`.

- Sections: Notch, Behavior, Widgets, Clipboard, Live Activities, Access.
- The Clipboard widget switch is collection (`flux.notch.clipboard.enabled`). Its helper says Flux checks the clipboard for new copies while it is on. It names no rate; add one only after measurement. Save clipboard history is a separate switch (`flux.notch.clipboard.persistence.enabled`). Its helper says only text, links and colors are saved, never image or file contents.
- Clear Saved History opens an `NSAlert` sheet. `.clearClipboardHistory` is sent only on Clear History. With no window, the button does nothing.
- Widget rows show a switch, then up and down buttons named "Move <name> earlier/later". Up is off on the first row and down is off on the last. The page never reorders by itself; the parent sends the new order.
- Master off turns off every dependent control and keeps its value. Close delay is off when the trigger is Click. Duo is off unless Now Playing and Calendar are on. Auto-clear is off when File Shelf is off. Save history is off when Clipboard is off. Clear Saved History stays on.
- Access rows show fixed status text. `.notAsked` shows Allow (`.requestAccess`). `.denied` shows Open Settings (`.openAccessSettings`). FluxUI never asks macOS. The parent asks only after Allow, never at launch.
- A saved close delay outside the menu values (0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.0 s) is added to the menu, so it shows as is.
- Identifiers: `notch.enabled`, `notch.trigger`, `notch.closeDelay`, `notch.fullscreen`, `notch.widget.<rawValue>`, `notch.widget.<rawValue>.up`, `notch.widget.<rawValue>.down`, `notch.duo`, `notch.shelf.expiry`, `notch.clipboard.save`, `notch.clipboard.clear`, `notch.activity.<battery|bluetooth|calendarEvent|timer|soundHUD>`, `notch.access.<calendar|camera|accessibility>`.
- This page only edits settings. Widgets, their in-panel Allow cards and the notch panel stay as they are.

## Lock Screen page (slice 4)

```swift
let lock = LockScreenPreferencesController(state: LockScreenPreferencesState(
    isEnabled: store.value(for: Preferences.lockScreenEnabled),
    showsNowPlaying: store.value(for: Preferences.lockScreenNowPlaying),
    showsActivities: store.value(for: Preferences.lockScreenActivities),
    playsUnlockSound: store.value(for: Preferences.lockScreenUnlockSound),
    capability: .available,      // parent's check
    failureCode: nil             // or a short code from the last failed attempt
)) { action in parentHandle(action) }
```

State fields, all `let`, no defaults: `isEnabled`, `showsNowPlaying`, `showsActivities`, `playsUnlockSound: Bool`, `capability: LockScreenCapability` (`.available`, `.unavailable`, `.needsPermission`), `failureCode: String?`.

`LockScreenPreferencesAction` cases: `.setEnabled(Bool)`, `.setNowPlaying(Bool)`, `.setActivities(Bool)`, `.setUnlockSound(Bool)`, `.openSystemSettings`, `.checkAgain`.

- Sections: Lock Screen (master switch and one status row), then Show (three switches).
- The three switches are on for input only when the master is on and capability is `.available`. They keep their values.
- `.unavailable` turns off the master switch for input and keeps its value. `.needsPermission` shows one row with Open Settings and Check Again. A `failureCode` shows "Last attempt failed (<code>)" and Check Again. Only one status row shows at a time. The text claims nothing about how macOS shows the lock screen.
- Identifiers: `lockScreen.enabled`, `lockScreen.nowPlaying`, `lockScreen.activities`, `lockScreen.unlockSound`, `lockScreen.open`, `lockScreen.check`.
- Parent owns: the lock-state checks, their cost text after measurement, and the private window bridge.

## Rating form (slice 4)

```swift
let rating = FeedbackRatingController(state: FeedbackRatingState(
    collectionEnabled: collection.enabled,   // saved opt-in
    submission: .ready
)) { action in
    switch action {
    case .submit(let value): parentSend(.surveyAnswered(survey: config.survey, question: config.question, rating: value, submission: UUID()))
    case .cancel: parentClose()
    }
}
presentingController.presentAsSheet(rating)   // only from a user action
```

State fields, all `let`, no defaults: `collectionEnabled: Bool`, `submission: FeedbackSubmission` (`.ready`, `.sending`, `.sent`, `.failed(code:)`).

`FeedbackRatingAction` cases: `.submit(UsageRating)`, `.cancel`. `UsageRating` is the FluxCore type in `Sources/FluxCore/Telemetry/PostHogWire.swift` (`.one` ... `.five`, raw values "1" to "5").

- One `NSSegmentedControl` with segments 1 to 5, no first choice, labels "1 Poor" and "5 Great". Submit is off until a choice exists, while sending, after `.sent`, and whenever `collectionEnabled` is false. Return submits. Esc and Cancel send `.cancel`.
- With collection off, the text says Flux can't send a rating. It never shows "sent" unless the parent sets `.sent`. Set `.sent` only after the client reports a send.
- No text field, no IDs, no network, no timers. FluxUI never opens it. About does not open it. The parent holds the survey config, opens the form only on a user action, and sends only after opt-in.
- Identifiers: `feedback.rating`, `feedback.cancel`, `feedback.submit`.

## Notch widgets (slice 6)

Return one of these from the `NotchPanelController` factory. The panel keeps one child at a time and owns show and hide. The widgets add no dismissal timer, no timer of any kind, and no global monitor. Each one builds its views in `loadView`, so nothing loads before the panel shows that tab. Each root has dark appearance and fills the panel's 440 pt maximum width minus the panel's 16 pt insets.

All five update controls in place. After an update, focus goes back to the control that had it, if that control is still shown. Programmatic value changes send no action. Every action goes to the parent through one typed callback. No widget changes its own state.

### Now Playing

```swift
let widget = NowPlayingWidgetController(state: NowPlayingWidgetState(
    status: .playing,                 // .playing, .paused, .empty, .noAccess
    title: title, artist: artist,
    artwork: nsImage,                 // nil shows a music note
    sources: [NowPlayingSourceOption(id: appID, name: "Music")],
    selectedSource: appID,
    elapsed: 42, duration: 215,       // seconds; nil or 0 duration turns seek off
    canGoPrevious: true, canGoNext: true
)) { action in parentHandle(action) }
widget.update(newState)               // send a new elapsed when the parent wants time to move
```

- `NowPlayingWidgetAction`: `.togglePlayPause`, `.previous`, `.next`, `.seek(TimeInterval)`, `.selectSource(ApplicationID)`, `.openSource`, `.checkAgain`.
- The seek slider has `isContinuous = false`. It sends one `.seek` when the user lets go. The parent sends the new `elapsed`.
- The source menu shows only with two or more sources. Choosing the selected source again sends nothing.
- `.empty` shows "Nothing playing" and a fixed Check Again button. `.noAccess` shows "Flux can't read what's playing" and Check Again. Both send `.checkAgain`.
- The play button label is Play or Pause from `status`. VoiceOver reads the widget as "Now Playing: title, artist" and the slider as "0:42 of 3:35".
- The parent owns the media adapter, the playback clock and artwork decoding.

### Calendar

```swift
let widget = CalendarWidgetController(state: .events(today: todayRows, tomorrow: tomorrowRows)) { action in ... }
// rows: CalendarWidgetEvent(id:title:location:start:end:isAllDay:color:)
// color: CalendarWidgetColor(red:green:blue:), sRGB 0...1, nil uses the Flux accent
widget.update(.needsPermission)       // or .unavailable
```

- The parent maps `AgendaSnapshot` / `AgendaEntry` to `CalendarWidgetEvent` and splits today and tomorrow. FluxUI has no EventKit and reads no clock.
- Each day shows at most `CalendarWidgetController.maximumRowsPerDay` (4) rows, then an "N more" button. It sends `.openCalendar(.today)` or `.openCalendar(.tomorrow)`. The parent opens Calendar on that day, so no hidden event is out of reach. Rows show a 7 pt color dot, the title, then "start – end · location" or "All-day · location". Times use `DateFormatter` short style in the user's locale and time zone.
- Both days empty shows "No upcoming events".
- `.needsPermission` shows Grant Access (`.requestAccess`). `.unavailable` shows Open Settings (`.openSettings`) and Check Again (`.checkAgain`). The widget never says access is given.
- `update(_:)` ignores an equal state, so a repeated snapshot rebuilds nothing.

### Mirror

```swift
let widget = MirrorWidgetController(status: .starting, preview: cameraPreviewView) { action in ... }
widget.update(.running)               // .starting, .running, .needsPermission, .unavailable, .interrupted, .failed
widget.setPreview(otherView)          // or nil; the parent keeps ownership of the view and its layer
```

- The preview sits in a black area, 150 pt high, with a 16 pt continuous corner radius that clips it. Mirroring, the session and the layer stay with the parent's `CameraFeed`.
- `.starting` shows "Starting camera…" over the black area. `.running` shows the preview. With no preview view, it shows "No camera picture".
- `.needsPermission`: Grant Access (`.requestPermission`). `.unavailable`: "No camera found", Open Settings (`.openSettings`) and Check Again (`.retry`). `.interrupted` and `.failed`: Try Again (`.retry`).
- The widget does not start or stop the camera. Stop it from `onWillSwitch` or `onWillDismiss`, which run before the panel removes the widget.
- No frame capture, snapshot or image cache.

### File Shelf

```swift
let widget = FileShelfWidgetController(state: FileShelfWidgetState(
    items: [FileShelfWidgetItem(id: uuid, name: "Report.pdf",
                                image: thumbnailOrAppIcon,   // nil shows a document symbol
                                dragURL: ownedFileURL,       // nil turns drag out off
                                status: .ready)],            // .ready, .copying, .failed
    status: .ready                                           // .ready, .loading, .busy, .failed
)) { action in ... }
```

- `FileShelfWidgetAction`: `.drop([URL])`, `.open(UUID)`, `.showInFinder(UUID)`, `.airDrop(UUID)`, `.copy(UUID)`, `.remove(UUID)`, `.clearAll`, `.retry`.
- The whole widget takes file URL drops when `status` is `.ready`. One drop sends one `.drop` with every file URL. It reads the drag pasteboard only in that drop. A drag that starts in the shelf list is refused.
- Drag out writes the row's `dragURL` as a file URL, copy only, for `.ready` rows. The parent checks that the URL is a shelf-owned file before it sends it.
- Double click or Enter sends `.open`. Delete sends `.remove`. The row menu has Open, Show in Finder, AirDrop, Copy, then Remove. A `.copying` or `.failed` row allows only Remove.
- Clear All shows "Remove all files from the shelf?" with Cancel and Clear. Only Clear sends `.clearAll`. Escape cancels.
- `.copying` rows show "Copying…". `.loading` and `.busy` show one fixed line. `.failed` shows "Can't read the shelf" with Try Again (`.retry`). No spinner or timer.
- Empty and `.ready` shows "Drop files here". The list shows 4 rows of 36 pt, then scrolls. Cells are reused.
- The parent owns copying, checks, expiry, persistence, the share picker, thumbnails and the item cap. The widget does no file work.

### Clipboard

```swift
let widget = ClipboardWidgetController(state: ClipboardWidgetState(
    items: [ClipboardWidgetItem(id: uuid, preview: text,   // cut to 200 characters
                                kind: .text,               // .text, .url, .color, .file, .image, .other
                                image: smallThumbnail,     // never the full image
                                color: ClipboardWidgetColor(red: 1, green: 0.5, blue: 0),
                                hasPayload: true,
                                link: checkedURL)],        // Open in Browser only for http and https
    copiedID: lastCopiedID                                 // shows "Copied" until the parent clears it
)) { action in ... }
```

- `ClipboardWidgetAction`: `.copy(UUID)`, `.remove(UUID)`, `.openLink(UUID)`, `.clearAll`.
- The widget shows at most `ClipboardWidgetController.maximumItems` (50) rows, newest first as given. The parent caps history and keeps every payload.
- The search field filters previews in the widget. Down moves into the list. Enter in the field copies the first match.
- Click or Enter on a row sends `.copy`. Delete sends `.remove`. The row menu has Copy, Open in Browser for a checked http or https link, then Remove. Rows with `hasPayload: false` read "No longer available" and do not copy.
- Clear All shows "Remove all clipboard items?" with Cancel and Clear. Only Clear sends `.clearAll`.
- Empty shows "Nothing copied yet". No match shows "No matching items".
- The widget never reads the pasteboard, polls, or stores history. The parent copies back with the exact type and opens links.

## Widget layout fix

The widget captures at `build/native-ui-75d067c` showed four layout faults in the 408 x 440 pt host. File Shelf and Clipboard had the header in mid-panel and the list at the bottom. Calendar stretched its first row to about 200 pt. Row titles were 0 to 130 pt wide, and the Now Playing controls sat at the left.

The causes were in FluxUI:

- Each widget pinned its stack to all four edges of its root. The panel container and the fixture host both set a fixed height, so the stack stretched its lowest-hugging view. Widgets now use `NotchWidgetStyle.pinTop`. The stack's bottom edge may leave space, so rows keep their own height and sit at the top.
- One-line labels had horizontal compression resistance 250, the same as the stack hugging. The text column then took the width of the shortest label. `NotchWidgetStyle.fillWidth` sets 490 on row titles, details, the Clear All header and the Now Playing title, so text gets the free width and truncates at the row edge.
- The list column kept the default `NSTableColumn` width. `NotchListScrollView` sets the column to the visible width on each layout.
- The Now Playing transport used two spacers with equal priority. `NotchWidgetStyle.centered` now centers the buttons with a constraint. A spacer puts the source menu and Open button at the trailing edge. The elapsed and remaining times no longer compress.
- Calendar "N more" text is leading-aligned.

The production host matches the fixture. `NotchPanelController` pins the widget to a container that is 440 - 2 x 16 = 408 pt wide, and the parent sets the height. The root must rebuild on macOS and capture each widget state again. This change has no capture yet.

## Teardown

These pages and the rating form hold no timers, monitors, tasks or observers. Control closures live in the page and capture it weakly. Settings releases the page on a page switch or close. The parent drops any reference it kept in `onPageWillDisappear` or `onClose`. A late `update(state:)` before the view loads only stores the state.

## Not written yet

- "Show on displays without a notch". FluxCore has no key for it, so the Notch page has no switch.
- Clipboard check rate and lock-state check cost text. Both wait for measurement.
- Slice 6 widgets, File Shelf and Clipboard are not compiled or run. They need a macOS build, a capture of each state in the panel, and keyboard and VoiceOver passes.
- Slices 4 and 5 are not compiled or run. This host has no Swift. The root's macOS build, capture at 680 and 840 pt, keyboard and VoiceOver passes must prove them. The slice 5 focus fallback needs a keyboard check: move the second widget up, then confirm focus is on its Down button.

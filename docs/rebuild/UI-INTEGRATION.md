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

FluxUI uses these FluxCore types: `ApplicationID`, `MenuBarGroup`, `MenuBarCapability`, `Widget`. It adds an internal `Widget.displayName` extension. It declares no public name that FluxCore already has.

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
- Root must still build the General, Notch, Lock Screen and About page contents. FluxUI gives the Analytics group and permission cards for them.

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

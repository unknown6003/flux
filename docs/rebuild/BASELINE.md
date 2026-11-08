Source anchors below refer to baseline commit `2d81d9dd0549324dbfef3bf8da2aa68665e84229`, not the replacement code. The audit was read-only.

# Flux rebuild inventory

Read-only source audit, 8 November 2026. Baseline `/var/lib/t3code/dev/flux`, commit `2d81d9dd0549324dbfef3bf8da2aa68665e84229`, shipped 0.21.35 build 62. No build or app interaction ran. References below are relative to this checkout. This is a preservation map, not proof that all existing behavior works.

Outcome: identify the full replacement scope without silently losing features or saved user data.
Proof: counted source, traced settings and runtime owners, and read build/update contracts.
Constraints: no repo edits, no app state changes, no child agents, no native runtime claims.

## Size and feature count

84 Swift files contain 27,310 physical lines. These counts include comments and blank lines. `Support/SelfTest.swift` alone is 3,676 lines; the rest is 23,634. No SwiftPM package dependency is declared. The app target uses Swift tools 6, Swift 5 language mode, and macOS 14 minimum. The UI uses SwiftUI hosted by AppKit windows. `Package.swift:1-20`.

| Source group | Files | Physical lines |
| --- | ---: | ---: |
| App | 2 | 649 |
| MenuBar | 12 | 3,700 |
| Settings | 10 | 2,144 |
| Notch, including widgets | 24 | 9,032 |
| Services | 14 | 5,042 |
| Support | 14 | 5,500 |
| Hotkey | 3 | 353 |
| Login | 1 | 80 |
| Update | 3 | 755 |
| Entry point | 1 | 55 |

For planning, the inventory below has 34 user task groups across 9 areas. This is an explicit counting scheme, not a marketing feature count. Five widget types, eight live-activity kinds, five Settings tabs, two independent global shortcut slots, three icon lanes, and 34 saved SettingsStore keys are directly present in source.

## User flows to preserve or explicitly replace

| Area | Count | Existing tasks and file evidence |
| --- | ---: | --- |
| Menu bar drawer | 5 | Click or shortcut reveal/collapse; keep reveal while using another menu-bar icon; collapse on window click; timed re-hide; right/control-click shared menu. `MenuBar/MenuBarManager.swift:101-152,225-253,261-293` |
| Icon management | 5 | Open Settings with all zones revealed; drag to a lane or exact insertion gap; choose Shown/Hidden/Always Hidden via item menu or Tab/Space; move left/right via menu; refresh, help report, and access recovery. Apple/system items remain fixed. macOS 27 actions affect every icon from the same app. `Settings/Tabs/MenuBarTab.swift:45-124`; `Settings/MenuBarIconDropZone.swift:90-119,162-193` |
| Menu bar options | 3 | Enable Always Hidden zone; set re-hide delay 2–30 seconds; set Chevron/Dot/Line and global compact spacing. `MenuBarTab.swift:93-101,127-154`; `MenuBar/MenuBarIconStyle.swift:7-17` |
| Notch shell | 5 | Hover/click open with configurable close delay; shortcut toggle; swipe enabled widgets in saved order; cycle/dismiss/restore activity queue; auto-expand shelf during file drag. Fullscreen and display/lid changes have separate lifecycle handling. `Notch/NotchViewModel.swift:380-401,545-636`; `Notch/LiveActivity.swift:225-291`; `Notch/NotchWindowController.swift:286-340,395-427,1099-1190` |
| Media and calendar | 4 | Now Playing artwork/title/artist with previous/play/next and seek; open playback app; Today/Tomorrow read-only agenda with calendar color/time/location; optional media/calendar Duo layout. `Notch/Widgets/NowPlayingWidget.swift:187-366`; `Notch/Widgets/CalendarWidget.swift:161-239`; `App/AppDelegate.swift:352-371` |
| Shelf and mirror | 3 | Copy files/folders into a persistent shelf, open/drag out/AirDrop/Finder/copy/remove/clear; auto-clear Never/1/3/7 days; live mirrored camera preview with grant/unavailable/starting states and stop on dismissal. `Notch/Widgets/ShelfWidget.swift:92-229`; `Settings/Tabs/NotchTab.swift:286-331`; `Notch/Widgets/MirrorWidget.swift:78-145`; `Services/CameraService.swift:269-316` |
| Clipboard | 3 | Collect and recopy text/link/color/file/image history, open links, remove or clear; turn collection on/off separately from persistence; clear saved history from Settings. `Services/ClipboardMonitor.swift:14-18,422-451,916-959`; `Notch/Widgets/ClipboardWidget.swift:197-204,272-310`; `Settings/Tabs/NotchTab.swift:130-161` |
| Activities and lock screen | 3 | Battery/Bluetooth/calendar/timer/sound notices and volume key replacement; start 1/5/10/25-minute timers or stop all from shared menu; optional lock-screen silhouette/media controls/activity caption/unlock click. `Notch/LiveActivity.swift:12-14`; `Notch/LiveActivitySources.swift:171-199,227-247,849-976`; `MenuBar/MenuBarManager.swift:303-338`; `Settings/Tabs/LockScreenTab.swift:11-46` |
| App maintenance | 3 | Login startup plus two rebindable conflict-aware shortcuts; manual/automatic update installation with fallback and rollback; General/Menu Bar/Notch/Lock Screen/About navigation, dark/light/system appearance, crash report copy/dismiss, attribution, quit. `Settings/SettingsView.swift:4-25`; `Settings/Tabs/GeneralTab.swift:25-145,168-268,302-344`; `Settings/Tabs/AboutTab.swift:20-52` |

TimerService also exposes pause/resume internally, but there is no dedicated timer widget in the five-item WidgetID enum. Do not mistake internal methods for a visible timer UI. Five widget stable IDs are `nowPlaying`, `shelf`, `calendar`, `mirror`, `clipboard`. `Notch/NotchWidget.swift:7-21`.

Eight activity kinds are battery, bluetoothDevice, timer, shelfDrop, menuBarOverflow, nowPlaying, calendarEvent, soundHUD. The dismissed activity stack cap is five and is in-memory. `Notch/LiveActivity.swift:12-14,129-135`.

## Preference migration contract

Keep the same defaults domain `com.flux.menubar`, or perform a typed one-time migration with rollback. Do not overwrite an existing explicit value with a new factory default. New defaults need a deliberate policy choice.

All 34 preference keys below are defined at `Settings/SettingsStore.swift:385-419`. Their default values are at 344-382. Default shortcut key codes and modifier mask are at `Hotkey/HotkeyShortcut.swift:23-33`.

| Key | Current new-profile default |
| --- | --- |
| `flux.launchAtLogin` | false |
| `flux.showAlwaysHiddenSection` | true |
| `flux.autoRehide` | true |
| `flux.autoRehideDelay` | 8.0 seconds |
| `flux.enableHotkey` | true |
| `flux.automaticUpdateChecks` | true |
| `flux.appearance` | `dark`, also accepts `light`, `system` |
| `flux.iconStyle` | `chevron`, also accepts `dot`, `line` |
| `flux.hotkey.keyCode` | ANSI F virtual key, 3 |
| `flux.hotkey.modifiers` | Carbon control/option/command mask, 6400 |
| `flux.notch.enabled` | true |
| `flux.notch.expansionTrigger` | `hover`, also accepts `click` |
| `flux.notch.hoverCloseDelay` | 0.40 seconds |
| `flux.notch.showInFullscreen` | true |
| `flux.notch.widgetOrder` | `[nowPlaying,shelf,calendar,mirror,clipboard]` |
| `flux.notch.nowPlayingEnabled` | true |
| `flux.notch.shelf.enabled` | true |
| `flux.notch.shelf.expiryDays` | 0, Never |
| `flux.notch.calendar.enabled` | true |
| `flux.notch.activities.battery` | true |
| `flux.notch.activities.bluetooth` | true |
| `flux.notch.activities.calendarEvent` | true |
| `flux.notch.duo` | false |
| `flux.notch.mirror.enabled` | true |
| `flux.notch.clipboard.enabled` | true |
| `flux.notch.clipboard.persistence.enabled` | true |
| `flux.notch.activities.timer` | true |
| `flux.notch.activities.soundHUD` | true |
| `flux.notch.lockScreenExperiment` | true |
| `flux.notch.lockScreen.nowPlaying` | true |
| `flux.notch.lockScreen.activities` | true |
| `flux.notch.lockScreen.unlockSound` | true |
| `flux.notch.hotkey.keyCode` | ANSI N virtual key, 45 |
| `flux.notch.hotkey.modifiers` | Carbon control/option/command mask, 6400 |

Other state with migration meaning:

- `flux.macOS27IconLayout` is a dictionary with `hidden` and `alwaysHidden` arrays of app bundle IDs. In this baseline Always Hidden is a subset of Hidden. Apple apps are filtered on read. There is no schema-version field. Preserve that meaning if the new format stores disjoint categories. `MenuBar/MacOS27Hider.swift:141,197-202,492-508`.
- `NSStatusItem Preferred Position flux.chevron`, `... flux.divider.hidden`, `... flux.divider.alwaysHidden`, plus `.v27` autosave suffix on macOS 27. `flux.layoutVersion` is 5. macOS owns these positions, measured as distance from right. The legacy code sanitizes positions above 8,000pt and uses 10,000pt collapsed dividers. `MenuBar/ControlItem.swift:25-57,111-112,164-169,192-197`.
- `flux.menuBar.ownsStatusItemSpacing`, `flux.menuBar.previousStatusItemSpacing`, `flux.menuBar.previousStatusItemSelectionPadding` protect the user's prior global values. Never discard this restore stash. The actual global current-host keys are `NSStatusItemSpacing` and `NSStatusItemSelectionPadding`; Flux compact value is 6. Restore only if global value is still Flux's value. `MenuBar/MenuBarSpacing.swift:18-26,56-68,80-92,130-139`.
- `flux.loginItem.bundleRegistration.v1` marks completion of the old unbundled-login registration cleanup. Avoid re-running the destructive unregister/re-register migration as a fresh install. `Login/LoginItemManager.swift:25,63-77`.
- `flux.lockScreen.notchGeometry.v2` stores last-known notch and screen rectangles by scalar keys. It is a geometry cache, not user content; safe to revalidate against displays. `Notch/LockScreenPresenter.swift:197,275-309`.
- Old `flux.notch.style` is removed on SettingsStore construction. It is obsolete, not a feature to restore. `Settings/SettingsStore.swift:54-56`.

## Saved files and content boundaries

| Location under `~/Library/Application Support/Flux` | Format and preservation rules |
| --- | --- |
| `Shelf/manifest.json` | JSON array of ShelfItem, with UUID `id`, original `fileName`, `addedAt`. Each payload is `Shelf/<UUID>/<fileName>`. Preserve payloads, basename, UUID references, duplicate names and directories. Load reconciles missing files and leaves unrelated/orphan files in place. `Services/Shelf/ShelfItem.swift:14-43`; `Services/Shelf/ShelfStore.swift:69,100-123,344-391` |
| `clipboard-history.json` | JSON object `version:1`, `entries:[{capturedAt,kind,text}]`; ISO8601 dates. Only text/url/color persist. Maximum 50 entries, 32,000 chars/entry, 1,000,000 file bytes, 30-day retention. Private directory mode0700, file0600, atomic writes. Turning persistence off or clearing history deletes file. Never carry image/file bytes into the saved format. `Services/ClipboardMonitor.swift:152-165,238-265,305-354,360-407` |
| `session.json` | Previous run status and non-content breadcrumbs. It drives unclean-session banner and report. A rewrite must end its own session cleanly, but should not mistake old schema failure for a new crash. `Support/CrashReporter.swift:65-125,146-180` |

Clipboard collection excludes concealed, transient and auto-generated NSPasteboard markers. In memory, full text cap is100,000 characters, retained image payload budget48MiB with8MiB per image,64px thumbnails. This is a deliberate content-memory budget that can dominate the base app. `Services/ClipboardMonitor.swift:179-191,735-755`.

Shelf copies files larger than64MiB and unknown-size folders on a background task. Thumbnails are lazy, newest100 only, and cached NSImages remain in the store. No total shelf storage cap is present. Expiry sweeps occur on configure/load/add, not an always-running expiry timer. `Services/Shelf/ShelfStore.swift:58-62,128-135,158-260,321-342,409-418`.

## OS interfaces and permission map

| Interface | Use and limits |
| --- | --- |
| AppKit NSStatusItem | Three Flux-owned controls, drawer, status icon and native app menus. Agent app has no Dock/Cmd-Tab entry. `MenuBar/MenuBarManager.swift:49-52`; `main.swift:45-54`; `Resources/Info.plist` |
| Accessibility and CGEvent posting | Read owner AX status trees, identify items, and synthesize Command-drag. User opens Accessibility settings, does not get an automatic AX prompt. `MenuBar/MenuBarIconManager.swift:318,355,442-501,1021-1051`. AX trust can cache denial; same signed executable `--flux-check-access` child probes current trust with1.5-second deadline. `Support/AccessibilityAccess.swift:11-53` |
| Private MenuBarClientCore on macOS27 | Dynamically load `MBAssessmentModeAssertion` and `MBAssessmentModeConfiguration`; allowlist all system items0...63 plus selected running app IDs. Hiding granularity is per app, not individual icon. Pending activation has10-second deadline; absent/private-interface failure must expose a usable visible state. `MenuBar/MacOS27Hider.swift:8-12,36-47,59-109,128-135` |
| Legacy drawer macOS14–26 | Expanding NSStatusItem width to10,000pt pushes left peers offscreen. New engine must either preserve tested support or explicitly set a higher minimum OS. `MenuBar/ControlItem.swift:18-33` |
| Optional Screen Recording | Actual icon previews request CG screen-capture access, then use ScreenCaptureKit screenshots of menu-bar band only while editor open. App icons work without it. Tasks time out after3seconds and clear on close. `MenuBar/MenuBarIconImages.swift:21-23,40-44,53-80,93-108`; `Settings/Tabs/MenuBarTab.swift:67-70` |
| EventKit | Read upcoming events after explicit full Calendar grant. Not write-only. Separate permission and fetch stores. `Support/PermissionCenter.swift:49-62,97-120`; `Services/CalendarService.swift:133-164` |
| AVFoundation | Camera permission explicitly requested; session and device/layer discovery lazy; start/stop only while Mirror presented, serialize operations on dedicated queue. `Support/PermissionCenter.swift:124-130`; `Services/CameraService.swift:52-93,269-316` |
| IOKit and CoreAudio | Battery/AC power events; Bluetooth audio/HID device registry notifications and battery; default-output/volume/mute listeners. No Bluetooth prompt path in DeviceMonitor. `Services/PowerMonitor.swift:99-147`; `Services/DeviceMonitor.swift:184-238,285-324`; `Services/VolumeMonitor.swift:40-53` |
| CGEvent tap | Replace volume bezel and alter output volume/mute only when interception permission/control available. Otherwise OS keeps its own UI. Tap listens system-defined event14. Resume attempts on wake/app activation. `Services/MediaKeyInterceptor.swift:34-95` |
| Private media adapter | Vendored BSD3 MediaRemoteAdapter.framework and Perl script. Spawns `/usr/bin/perl ... stream`, reads JSON notifications, launches commands for transport/seek. No AppleScript fallback remains despite build comments. `Services/NowPlaying/MediaRemoteAdapterSource.swift:97-108`; `Services/NowPlaying/NowPlayingService.swift:5-11`; `Vendor/mediaremote-adapter/PROVENANCE.md` |
| Private lock-screen bridge | SkyLight `SLSMainConnectionID`, `SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSShowSpaces`, `SLSSpaceAddWindowsAndRemoveFromSpaces`; undocumented lock/unlock notifications and CG session dictionary lock key. Separate mouse-transparent silhouette and card-sized interactive media panel. `Notch/SkyLightLockScreenBridge.swift:32-53`; `Notch/LockScreenPresenter.swift:331-359,419-425,737-744,801-844` |
| SMAppService and Carbon | Modern bundled login startup; two independently registered shortcuts and conflict UI. Never register bare CLI process for login. `Login/LoginItemManager.swift:14-56`; `Hotkey/HotkeyManager.swift`; `Settings/Tabs/GeneralTab.swift:81-145` |

No App Sandbox entitlement is configured by Package.swift/build_app.sh. Keeping or removing sandboxing is a migration decision because current file, menu-bar and private integration behavior assumes this packaging. The saved self-signed identity is not Apple notarization.

## Allocation and wakeup facts

These are source-derived rates and ownership facts, not measured CPU/RSS results.

| Feature state | Work in current app |
| --- | --- |
| Defaults, collapsed notch on built-in display | Mouse-position timer every0.10s with0.05s tolerance, plus global/local move and click monitors. Poll is stopped in expanded state when both move monitors exist; no notch/display stops it. `Notch/NotchWindowController.swift:221,575-616,625-650,395-405` |
| Defaults, lock-screen feature on, even unlocked | Lock-state reconciliation Task every350ms. Disable cancels poll, observers and windows. Presenter is created only at first enable, remains retained after disable. `Notch/LockScreenPresenter.swift:198,227-245,397-408,438-449`; `App/AppDelegate.swift:318-328` |
| Defaults, clipboard on |5Hz pasteboard changeCount timer plus Cmd-C/Cmd-X monitors; persistence restores at collection start. Widget closed does not stop collection. Feature off stops timer and shortcut monitors, but retains entries. `Services/ClipboardMonitor.swift:422-451`; `App/AppDelegate.swift:299-305` |
| Now Playing, after first active use | Perl stream stays warm when widget closes. Only all media features off stop process and clear state/artwork. No stream polling, but process memory counts toward full app cost. Raw artwork and downsampled image are both held. `Services/NowPlaying/NowPlayingService.swift:64-91,157-180`; `Services/NowPlaying/MediaRemoteAdapterSource.swift:45-79,97-108` |
| Shelf disabled/not used | Store constructed with deferLoad=true; no manifest load for disabled shelf. When expiry is nonnil and shelf enabled, setting it loads/sweeps. Visited shelf retains thumbnail cache. `App/AppDelegate.swift:19,292-297`; `Services/Shelf/ShelfStore.swift:78-115,409-418` |
| Mirror disabled/not open | Camera service object exists, but no capture device/session/preview layer until use. After use stopRunning releases active capture but session/layer remain cached. `App/AppDelegate.swift:26`; `Services/CameraService.swift:50-93,304-316` |
| Battery/Bluetooth/sound disabled | Router is lazy until notch first on; once created service objects and subscriptions persist. Corresponding native listeners/tap stop while toggle off or no presentation. MediaKeyInterceptor retains its wake/activation observers until deinit. `App/AppDelegate.swift:278-288`; `Notch/LiveActivitySources.swift:116-136,752-788`; `Services/MediaKeyInterceptor.swift:34-44,88-96` |
| Calendar disabled/no grant/no presentation | Router stops service, cancels observation/rollover and clears events. Active fetch triggers are change notifications, immediate start and midnight, plus one event-soon boundary. `Services/CalendarService.swift:133-164,197-207`; `Notch/LiveActivitySources.swift:776-815` |
| Automatic updates off | Scheduler cancels launch Task and6-hour timer. On uses initial4-second check and common-mode6-hour timer. Updater object/URLSession still constructed. `App/AutomaticUpdateScheduler.swift:15-48`; `App/AppDelegate.swift:9`; `Update/UpdateChecker.swift:62-69` |
| Timers absent | No countdown tick in TimerService, only wake observer. Timers arm nearest deadline. Visible timer activity uses second-boundary display work. `Services/TimerService.swift:97-122,138-144,259-261`; `Notch/LiveActivitySources.swift:923-976,1013-1025` |
| Whole notch disabled at launch | Notch controller/model/registry, five widget objects, permission center, clipboard/camera/calendar/media/shelf/timer services still exist; native expensive hardware/media/listener work is gated. Router and lock-screen presenter avoid construction. `App/AppDelegate.swift:15-38,121-125,258-288` |

Base memory optimization targets are therefore lazy service graph construction, release of hidden hosting trees/caches, eliminating permanent fallback polls where a reliable event path exists, and accounting for helper processes. Deleting useful history solely to reduce a memory number would violate the user's data contract.

## Updater, signing and install contracts

- Bundle ID `com.flux.menubar`, executable `Flux`, app basename `Flux.app`, LSUIElement true, minimum macOS14. `Resources/Info.plist`.
- Signed updates must use the saved PKCS12 certificate matched to public `Resources/FluxSigning.pem`. Re-signing ad hoc can lose TCC grants. Nested media framework is signed inside-out. `Scripts/import_signing.py`; `Scripts/build_app.sh:74-100`; `.github/workflows/ci.yml:175-180`.
- DMG asset must remain `Flux.dmg` with `Flux.app` at image root. Applications symlink supports drag install. Existing updater uses latest non-draft/non-prerelease GitHub release at `unknown6003/flux`, picks first.dmg, and compares semantic version. Version must exceed0.21.35. `Update/UpdateChecker.swift:13-22,182-209,323-340`; `Scripts/build_dmg.sh:13-35`.
- Existing installed updater checks candidate bundle ID, requested version, executable and strict deep signature, stages beside current.app, mounts/copies before quit, and falls back to Downloads when not writable. **It does not pin the expected signer**; add this check in new updater. `Update/UpdateInstaller.swift:25-70`; `Update/UpdateChecker.swift:255-265`.
- Crucial incoming update protocol: old app launches new executable with `--flux-update-token UUID --flux-update-receipt /tmp/flux-update-UUID/startup`. New executable must atomically write token/PID/resolved bundle path/`started`, then `ready` after successful service startup. Old helper waits20seconds and2seconds stability, then deletes backup. Without receipt compatibility, new app remains unconfirmed even when visibly running. `Update/UpdateStartup.swift:8-31`; `main.swift:3-4`; `App/AppDelegate.swift:146`; `Update/UpdateInstaller.swift:234-295`.
- Failure to swap or a confirmed exited new process rolls back. Unknown/live PID retains old backup rather than replacing a live app. Preserve this safety behavior. `Update/UpdateInstaller.swift:220-295`.
- Single-instance policy yields to newer version and terminates older/equal other instances, delayed400ms startup when another instance existed. Retest launcher conflicts instead of blindly retaining this policy. `App/AppDelegate.swift:51-80`.

## Documentation drift to resolve

1. README says clipboard is off and memory-only; actual defaults enable collection and persistence. It also says lock-screen experiment off; actual default is on. `Settings/SettingsStore.swift:373-380`.
2. README says nothing polls; current default notch/lock/clipboard rates are10Hz,2.86Hz and5Hz respectively. OS timer coalescing means these are requested rates, not independently additive measured wakeups.
3. README says no Screen Recording needed anywhere; optional actual-icon preview does request it. `MenuBar/MenuBarIconImages.swift:21-23`.
4. README says Option-click reveals Always Hidden. Actual ControlItem click handler only distinguishes right/control versus left, and normal toggle explicitly keeps Always Hidden closed. Management Settings reveals it. `MenuBar/ControlItem.swift:380-387`; `MenuBar/MenuBarManager.swift:101-134`.
5. README describes labeled Arrange mode and Done. Current visible user path is Settings lanes. Legacy isArranging rendering remains, but does not prove an available current Arrange mode.
6. Build script says missing adapter falls back to AppleScript. Actual NowPlayingService removed that fallback. `Scripts/build_app.sh:30-55`; `Services/NowPlaying/NowPlayingService.swift:5-11`.

## Proposed acceptance cases for the full replacement

1. Upgrade an actual signed0.21.35 app through its own updater. Observe incoming started/ready receipt, one new process, old backup cleanup, same TCC identity and all34 explicit preference values. Repeat failure-before-ready and failed-swap rollback in disposable fixture.
2. Seed baseline layout with Hidden and Always Hidden apps, multi-icon app, unknown new app, Apple icons. Upgrade, reveal/collapse, restart, sleep/wake, revoke Accessibility and repeat saved-layout hiding. New unknown apps remain visible. Prove physical pixels with identical recorded screen coordinates.
3. On real macOS27, start from fresh Settings, fast-insert a dynamic wide Notion-style item, then two left/right cycles without Refresh, keyboard neutralization or opening diagnostic menu while busy. Independently verify exact peers and saved category after each settled move. Also test a narrow icon, same-bundle siblings, stale removed source, changed title/width, app relaunch and anchor disappearance.
4. Cancel native work during drag, Escape, close Settings, active physical input, screen change and permission revoke. Prove zero late drag, no held synthetic modifier/button, no false success, no saved layout on unproved result. User can reach recovery controls and the menu remains usable.
5. Whole-notch off and each feature individually off, before and after use. Measure CPU, physical footprint, RSS, wakeups, threads, helper processes, timers/listeners and open hardware. Include per-process and combined helper memory. Compare default and feature-off against exact signed baseline, equal workloads and window visibility, repeated runs.
6. Notch real hover/click, lost first event, hotkey, fullscreen, Spaces, external-only/clamshell and lid return. Transparent area passes clicks and unrelated drags to app underneath. Reduced motion, keyboard navigation, VoiceOver names, 1x/2x display geometry and both themes.
7. Media play/pause/seek/next/source switching, long title, artwork updates and helper death/retry. Camera grant/revoke, no device, quick show/hide/reopen, interruption and device disconnect. No camera runs while hidden.
8. Shelf duplicate names, folder,64MiB+ payload, moved/deleted original, drag out/AirDrop/copy, expiry, restart and malformed manifest. Prove original file never deleted and stored data survives migration.
9. Clipboard opt-out and persistence-off, concealed/transient markers, screenshot images,48MiB budget, huge text, rapid successive copies, copy-back suppression, clear/restart and permissions0600. No content in logs or diagnostics.
10. Calendar grant/revoke, midnight/timezone, Today/Tomorrow and Duo; battery connect/low/recovery; Bluetooth connect/disconnect; sound output without volume control; timer completion across sleep. No empty permanently spinning states.
11. Lock-screen opt-in/out, repeated lock/unlock, disabled switches, no user content beyond configured choice, functional password/login controls and no mouse-blocking silhouette. Private bridge unavailable gives a usable fallback and no loop.
12. Clean action recording and screenshots must show real operations and final state, captured without unrelated windows or private desktop Spaces. Preserve original frame rate, inspect delivered media, and distinguish source tests from real Mac proof.

Existing tests are implementation-coupled. Preserve their behavior contracts while replacing their imports/fixtures. Baseline CI runs build/signing, CPU/IO comparisons, update scheduling and rollback, icon movement, layout reads, Settings cancellation, real arrow visibility, selftests and UI snapshots. `Scripts/probe_idle_resources.py:4-26` specifically asserts clipboard file state, not a low-memory bound. Neither compilation nor a fixed offscreen screenshot proves runtime reliability.

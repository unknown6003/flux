# Flux menu bar research

Researched on 16 October 2026. Sources were read on this date unless a date is stated.

Outcome: define a smaller Settings editor that makes moving menu bar icons clear and keeps idle work low.
Proof: inspect first-party screenshots and source, then map each recommendation to Flux's code and a real verification path.
Constraints: research only. No repository edits or native app changes. Do not add a new permission merely to match a reference image.

## Decision

Use one editor with three clear destinations, Shown, Hidden, and Always Hidden. Make the whole item the drag source and the whole destination accept drops. Keep one explicit Move menu and keyboard-accessible order controls. Preserve native Command-drag in the actual menu bar.

Ice and Barbee both show the user's actual items in horizontal lanes. This gives people a direct map between a section and its contents. Hidden Bar shows how little explanation a basic divider needs. Flux currently combines a diagram of coloured dots, a long list, tiny handles, optional grips under real menu bar icons, and separate drop strips. Remove that duplication before adding more controls.

For this release, use the owning app's icon and a short name if exact menu glyphs require Screen Recording. Clearly distinguish two icons from the same app with their item names. A real app icon plus a name is a better trade than a permission request for a thumbnail. AppKit provides an owning app image through NSRunningApplication.icon. [Apple API](https://developer.apple.com/documentation/appkit/nsrunningapplication/icon).

These are design recommendations from the evidence below. They are not measured improvements or claims of perfect reliability.

## What the references show

### Ice

The official layout image shows a title, one instruction, one Command-drag tip, and three broad horizontal lanes. Icons sit at the right, as they do in the menu bar. It separates layout from appearance in the sidebar. The second bar and search window reuse the same recognisable glyphs. [Official gallery](https://icemenubar.app/), [layout image](https://icemenubar.app/gallery/menu-bar-layout.png), [search image](https://icemenubar.app/gallery/menu-bar-item-search.png).

The inspected source is pinned to commit `11edd39115f3f43a83ae114b5348df6a0e1741cf`. Its commit date is 20 September 2025. Treat it as a useful implementation reference, not proof of compatibility with macOS 27. [Pinned tree](https://github.com/jordanbaird/Ice/tree/11edd39115f3f43a83ae114b5348df6a0e1741cf).

The layout item is an AppKit view that starts an `NSDraggingSession` from its full bounds. It carries a drag image, disables external refresh of the source container during a drag, and remembers the original container and index. A cancelled drop restores that index. Immovable or unresponsive apps get a specific explanation. [Layout item source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarItemView.swift).

The container creates a live insertion gap by moving the placeholder among nearby item centres. It supports empty destinations. It reuses existing views by identity and avoids a swap while the target is animating. [Container source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarContainer.swift).

At drop, the destination derives a position from the adjacent item or section divider, runs the actual move, and shows an error if it fails. The code has a 25 ms dispatch delay before movement. Do not copy that delay without proving Flux needs it. [Drop source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarPaddingView.swift).

The image cache tries one composite capture for a section, then crops item images. It falls back to per-window capture. Refresh signals are throttled. Capture stops when the relevant UI is hidden, when Settings is not showing Layout, or while an item is moving or recently moved. A three-second publisher still wakes. Copy the visibility checks and batching, not the standing timer by default. [Image cache source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemImageCache.swift).

Ice distinguishes required Accessibility access from optional Screen Recording access. Its source assigns Screen Recording to appearance and item images. Its Layout page still requires Screen Recording. Flux can keep its name-based editor available without it. [Permission model](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Permissions/Permission.swift), [layout pane](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift).

Ice is not a small implementation to copy wholesale. Its item manager has complex event routing, five move attempts, cursor hiding and restoration, item wakeup, and polling. Its current `slowMove` verification loop has no sleep in the loop body. Those details need separate measurement and safety review. Reuse the interaction model, not its entire event system. [Item manager source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift).

### Bartender

The current official site advertises Bartender 7 for macOS 27. It says this version moves items without touching the mouse. Its support page says Bartender 6 on Tahoe may move the mouse to maintain a live layout and offers on-demand mode. This is a useful distinction for Flux: a saved layout should not cause an endless background fight with the user. These are vendor claims, not independent speed tests. [Current site](https://www.macbartender.com/), [support and mode differences](https://www.macbartender.com/Bartender6/support/).

Bartender 6 offers a second bar for notch overflow and keyboard search. Its product page explicitly notes that those features can show the macOS screen capture indicator. A second bar solves access when a row cannot fit. It should not make Settings more complex. [Bartender 6 product page](https://www.macbartender.com/Bartender6/).

The release notes are a useful list of real failure cases. Versions 6.6.1 and 6.6.2 address high memory after leaving Layout, disappearing images during moves, and extra reorder work. Version 6.5.1 changes on-demand layout to move the edited items rather than sort the whole bar. Version 6.4.1 keeps unidentified items in place. Version 6.3.1 fixes duplicate apps swapping. Version 6.3.0 aborts movement when locking, changing Spaces, or entering full screen. Use these as scenarios to test, not evidence that Flux has each bug. [Bartender 6 release notes](https://www.macbartender.com/Bartender6/release_notes/).

In its dated 13 September 2025 announcement, Bartender says menu item images stay in memory, are not persisted, and are captured less often. It also describes arranging once, then turning off capture access for a limited mode. This is a sound product boundary for an optional future glyph cache. [Bartender 6 announcement](https://www.macbartender.com/B5blog/Meet-Bartender-6/).

### Barbee

The developer's App Store screenshot shows Shown Items, Hidden Items, and Always Hidden Items as three horizontal lanes. It uses a single instruction above them and keeps appearance on another page. A fourth Special Item Library holds extra features. Its screenshot also shows much more sidebar scope than Flux needs. Copy the three destinations. Do not add its library, automation, profiles, or new visual settings to fix an icon editor. [Developer App Store listing](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12).

The same listing's recent version history reports work on energy use, mouse interference, item ordering, and missing icons. It does not publish benchmark methods or numbers. No speed or reliability ranking can be made from that text. The current `macbarbee.com` homepage is a placeholder, so it was not used for technical claims. [App Store release history](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12), [placeholder site](https://macbarbee.com/).

### Hidden Bar

Its repository screenshot has two tabs, a diagram that labels Hidden and Shown, and a few standard controls below. The setup instruction asks users to Command-drag in the real menu bar. It has no separate in-window icon editor in that historical image. This is a useful example of small scope, but its large static tutorial would waste most of Flux's editor space. [Repository screenshot](https://raw.githubusercontent.com/dwarvesf/hidden/develop/img/screen1.png), [README](https://github.com/dwarvesf/hidden).

The manual describes an auto-collapse countdown that defers while the pointer remains in the menu bar, and a shortcut to reveal hidden items. For the macOS 27 direct build, it documents per-app hiding, system icons staying visible, and Accessibility access to read item positions. This is close to Flux's macOS 27 constraint. Two items from one app must not appear independently hideable if the engine changes both. [Manual](https://github.com/dwarvesf/hidden/blob/develop/docs/MANUAL.md).

The architecture document describes a one-shot auto-hide timer and an optional hover monitor. The monitor is absent when the option is off. It also describes a single engine boundary around hiding. This supports a cheap idle path and one clear place to switch OS mechanisms. [Architecture document](https://github.com/dwarvesf/hidden/blob/develop/docs/ARCHITECTURE.md).

There is a documentation conflict. The manual describes a native macOS 27 engine, while Architecture still says the factory always selects the old length engine and says macOS 27 breaks it. The head inspected was `47937b9d8aede0325ca87a7880af13433e7c5cf8`, dated 19 September 2026. Do not transplant its hiding code or quote its line count as the complete current app without checking source. This report uses those docs for specific design patterns only. [Pinned Hidden Bar tree](https://github.com/dwarvesf/hidden/tree/47937b9d8aede0325ca87a7880af13433e7c5cf8).

### Dato

Dato is a useful small-tool reference for named commands and keyboard recovery. Its official help documents keyboard actions and `Command+,` to open Settings even if the toolbar is hidden. It also explains that one app can have several menu bar items. Flux needs item names and a Settings route that survives a hidden control icon. The downloaded images show 2023 example dates and are historical visual references, not the current settings design. [Official Dato page and help](https://sindresorhus.com/dato).

## Apple's interaction rules

Apple recommends a non-drag way to perform the same action, a drag image after a short movement, an insertion point or destination highlight, feedback on invalid drops, and a way to undo. It also advises one continuous select-and-drag motion. Flux should use standard AppKit drag sessions and regular buttons or menus for the fallback. [Apple drag and drop guidance](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop).

A responsive tile should react before the Accessibility move finishes. That does not mean it should claim the external move succeeded. Keep a pending marker until the engine confirms the new location. Apple puts noticeable discrete interaction delays near 100 ms and suggests less than 5 ms of main-thread work for continuous updates. These are guidance thresholds, not a promise that a remote app will finish a move in 100 ms. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

Apple's Mac energy guide advises returning to idle, stopping invisible work, avoiding polling, batching work, and keeping long or unbounded work off the main thread. Its guide is archived, but these recommendations match the costly operations seen in Flux. [Mac energy best practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html).

## Flux findings

File references below describe the checkout read during research. The implementation may move these lines.

| Observation | Source | Effect |
| --- | --- | --- |
| The preview uses hard-coded coloured circles. It has no relation to discovered app identities. | `Sources/Flux/Settings/Tabs/MenuBarTab.swift:278` | It teaches the section model but does not help find an icon. |
| The editor instructs users about row handles, extra grips below the live menu bar, and Command-drag. | `Sources/Flux/Settings/Tabs/MenuBarTab.swift:86` | The first task has three gesture models and several caveats. |
| Each section has a separate 30-point strip that says Drop icons here. Rows below it do not form one destination. | `Sources/Flux/Settings/Tabs/MenuBarTab.swift:154`, `Sources/Flux/Settings/MenuBarIconDropZone.swift:8` | A large section looks droppable while only a small strip is active. |
| The draggable row source is an 18 by 22 point handle. It uses a generic menu bar symbol in the drag image. | `Sources/Flux/Settings/Tabs/MenuBarTab.swift:220`, `Sources/Flux/MenuBar/MenuBarDragController.swift:240` | Grabbing and tracking the intended app is harder than it needs to be. |
| Three section filters run as part of the view body. | `Sources/Flux/Settings/Tabs/MenuBarTab.swift:156` | Small cost at normal icon counts. Do not make this the main performance claim. |
| Extra menu bar dragging uses a 250 ms heartbeat and rescans after three seconds. It refreshes overlay windows at each idle tick. | `Sources/Flux/MenuBar/MenuBarDragController.swift:144` | An extra interaction model owns repeated main-thread work. |
| macOS 27 refresh walks running apps and asks each for AXExtrasMenuBar. Each owner gets a 0.2-second AX timeout. | `Sources/Flux/MenuBar/MenuBarIconManager.swift:403` | A broad synchronous scan can block Settings. Several slow processes can add up. |
| Drag commit refreshes and checks ID, title, source, frame, and live identity before moving. | `Sources/Flux/MenuBar/MenuBarDragController.swift:201` | Preserve identity safety. Do not remove checks merely to make a failing drop pass. |
| The manager already waits for its own popup menu to close, with a three-second deadline, before a macOS 27 move. | `Sources/Flux/MenuBar/MenuBarIconManager.swift:666` | The new Move menu must keep this path. Moving while its menu is open can interfere with input. |
| The model already distinguishes three sections, tracks busy state, and reports move failures. | `Sources/Flux/MenuBar/MenuBarSection.swift`, `Sources/Flux/MenuBar/MenuBarIconManager.swift:27` | Reuse the engine contract. A UI cleanup should not replace the tested move system. |

The source files in MenuBar and Settings totalled 5,825 lines at inspection. This is a scope count, not the app's total. A lower line count is useful only if it removes state, duplicate work, or a failure path. It is not a performance result.

## Proposed Settings behaviour

### Layout

Keep Flux's existing five top-level pages. Reduce the width and decoration of the sidebar only if it makes more room for the editor without hiding names.

In Menu Bar, put the layout editor first. Use a short instruction such as "Drag an app to move it. Use Move for more options." Below it, show the current icons grouped by their actual section. Put counts in the section headers. Use short text that explains when a section appears.

Use app tiles if the available width can show names without truncating most of them. A compact row with a full-row drag source is acceptable if that gives clearer names. The required improvement is one direct source and one generous destination per section. It does not depend on copying a horizontal strip exactly.

Put a Move menu on each item, or show a selected item's Move menu in a stable footer. It must be visible through keyboard focus. It must work without dragging. Keep explicit "Move left" and "Move right" names in accessibility labels and tooltips. Use the same underlying commit path for both controls and dragging.

If Always Hidden is off, show one short enable action with that destination, or hide the empty destination. Do not show a dead drop strip and direct the user to another control far below.

Put auto re-hide, spacing, and the Flux glyph below the editor in one compact options group. Use a disclosure for diagnostics. Do not show "Copy menu bar report" as a normal setup action.

### Drag feedback

1. Start from the full item area after the drag threshold. Use its app image and title.
2. Leave a placeholder in the source. Freeze view replacement during the session.
3. Highlight only the current valid section. Give empty sections the same hit area as populated ones.
4. Show the insertion position if reordering is supported. If this release only changes section, say that and use left/right controls for order.
5. On release, mark the item as moving. Commit once. Reuse the current identity checks and bounded verification.
6. Update to the verified layout. On failure or cancel, return to the source and keep a short, actionable error near the item.
7. Escape, closing Settings, a Space change, or loss of access must cancel safely. No overlays, event taps, or pending work may outlive the editor.

These steps are Flux recommendations based on the source and Apple guidance. They are not claims that every competitor implements all seven.

### Permission and error text

At the point of need, explain that Accessibility lets Flux read and move menu bar icons. Show one primary "Open Accessibility Settings" action. Check again when Flux becomes active. Put certificate or stale-entry repair steps behind Help, after the ordinary path fails.

Do not show an app bundle path and instructions to remove a permission entry to every first-time user.

If Flux can still reveal a saved layout without access, keep that control working and state the limit. On macOS 27, explain once that icons from one app hide together and Apple system icons stay visible.

Give specific states for missing access, loading, no items, busy, unsupported macOS build, stale identity, an app that exited, and a failed move. A blank lane is not enough feedback for those cases.

## Performance and code reduction

The largest likely wins are avoiding repeated AX scans, overlay maintenance, and unneeded service work. A cosmetic rewrite or combining files will not prove them.

Use one management-session lifetime. Open it when the editor is visible. Close it when the user leaves the page or window. Own its AX cache, pending refresh, drag state, and observers there. Make close idempotent.

Refresh after a launch or termination signal, display change, completed move, return from System Settings, or explicit Refresh. Coalesce repeated signals. Avoid a full rescan inside drag-update callbacks. An optional slow safety refresh should only run while the editor is visible and idle.

Publish the item list only when its value changed. Cache app images by stable app identity. Reuse them across rows and drag images. Clear entries when their app exits or the session closes if no other view needs them.

Do not remove per-app AX timeouts, identity validation, generation checks, or bounded retry just to save lines. Delete duplicate UI paths and duplicate work before weakening safety.

If the global grip mode goes away, remove its toggle, overlay source panels, return target panels, heartbeat, and dedicated input tap together. Keep native Command-drag detection and layout persistence. First confirm that no other feature still owns those paths.

Use event and scan counters in the developer report. A before/after trace should show which repeated operation disappeared. No target percentage should be claimed until that trace and a normal runtime sample agree.

## Verification plan

These are proposed acceptance checks, not results from this research run.

| Path | Required observation |
| --- | --- |
| Open Menu Bar Settings with 0, 10, 30, and many icons | Names remain clear. The first useful UI appears without a main-thread hang. Loading has a visible state. |
| Drag to each section, including an empty one | Whole destination responds. One commit happens. Displayed section matches the actual menu bar after verification. |
| Drop outside, Escape, close window, change page | Original item remains. No move persists. Drag resources return to zero. |
| Move menu and left/right controls | Same external result as dragging. Keyboard and VoiceOver names identify the item and action. |
| Two icons from one app, two running copies, duplicate labels | Stable identity. No other icon moves. Per-app hiding limits are clear. |
| App quits or changes an icon during drag | Stale operation fails safely and offers Refresh. |
| Open another app's menu, type, use Command-drag | Flux does not move the pointer or commit while input is unsafe. |
| Deny or revoke access, then grant it | Saved reveal remains available where supported. Editing resumes after a bounded recheck. |
| Sleep/wake, lock/unlock, display hot-plug, Space/full-screen change | Pending work cancels or revalidates. Coordinates and sections recover. |
| Open/close the editor 50 times | Memory settles. No growth in observers, timers, taps, windows, or scan rate. |
| Hide and reveal 100 times | No lost icons, order drift, sticky menu, or input capture. |

Run the same release build on the same Mac before and after. Record OS build, hardware, display layout, icon count, active optional modules, and whether access was granted. Measure idle with Settings closed, idle with the editor open, active dragging, a complete move, and repeated open/close.

Use Time Profiler and a short main-thread sample to locate AX waits. Record process CPU time, resident memory, wakeups where available, AX scans, writes, and movement retries. Report median and slow-tail input/commit times separately. Include WindowServer during long editing sessions because competitor release notes identify that as a real failure class.

A Linux unit test, static render, or isolated data benchmark can prove its own path. It cannot prove live Accessibility movement, menu bar persistence, system permissions, pointer safety, or macOS idle power use.

## Visual assets and provenance

All listed image files were downloaded from a first-party source with bounded curl and inspected with view_image. They are references only. No competitor asset should ship inside Flux's app bundle.

| Local file under /tmp/flux-menu-research | Source | What it shows |
| --- | --- | --- |
| `ice-layout.png` | [Ice layout](https://icemenubar.app/gallery/menu-bar-layout.png) | Three lanes with actual status glyphs. Best layout reference. |
| `ice-bar.png` | [Ice Bar](https://icemenubar.app/gallery/ice-bar.png) | Hidden items in a second bar. |
| `ice-search.png` | [Ice search](https://icemenubar.app/gallery/menu-bar-item-search.png) | Names and app images with keyboard confirmation. |
| `barbee-screen1.webp` | [Developer's listing](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12) | Second bar on a desktop. |
| `barbee-screen2.webp` | [Developer's listing](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12) | Three layout lanes and a separate item library. |
| `barbee-screen3.webp` | [Developer's listing](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12) | Appearance controls on another page. |
| `bartender6-bar.png` | [Bartender Bar image](https://www.macbartender.com/Bartender6/img/BartenderBar.png) | A second bar with broad click targets. |
| `hidden-screen1.png` | [Hidden Bar screenshot](https://raw.githubusercontent.com/dwarvesf/hidden/develop/img/screen1.png) | Small preferences scope and a direct native-drag instruction. Historical screenshot. |
| `hidden-screen2.png` | [Hidden Bar About](https://raw.githubusercontent.com/dwarvesf/hidden/develop/img/screen2.png) | Historical About window, version 1.4 visible. |
| `dato-main.jpg` | [Dato screenshot 1](https://sindresorhus.com/dato/screenshot1.jpg) | Compact native popover. Historical 2023 example content. |
| `dato-event-menu.jpg` | [Dato screenshot 4](https://sindresorhus.com/dato/screenshot4.jpg) | Named menu commands and key equivalents. Historical 2023 example content. |

Two key images, `ice-layout.png` and `barbee-screen2.webp`, are kept in `docs/research/menu-bar-references`. The other downloads remain in the local research cache at `/tmp/flux-menu-research`. `source-downloads.json` preserves exact URLs. `asset-manifest.json` records sizes and hashes for the downloaded images. No reference asset is bundled in Flux.

The attempted `hidden-preferences.png` URL returned 404. The real README assets are `screen1.png` and `screen2.png`. No missing image is used as evidence. The web reader could not fetch Ice's large layout image, so curl downloaded it and view_image inspected the local file.

## What not to copy

- Do not turn Flux into Bartender Pro or Barbee. Profiles, widgets, automation, extra palettes, and more appearance controls do not fix dragging.
- Do not make exact glyph capture a requirement for a named editor that works without it.
- Do not expose three separate drag modes in the first-run flow.
- Do not silently move unknown or duplicate identities.
- Do not rescan every app while the pointer moves across a destination.
- Do not fake success by moving only the tile. Verify the system result.
- Do not force a sort of the whole bar after one item changes.
- Do not copy old separator-length hiding onto macOS 27.
- Do not claim "perfect reliability", zero energy, or a performance percentage from screenshots, source inspection, or vendor release notes.

## Evidence limits

No competitor app was installed or run in this research task. Their precise current keyboard navigation, VoiceOver output, animation timing, CPU use, memory use, and live permission behaviour were not tested.

The screenshots establish visible layout only. Source establishes the pinned code path only. Bartender and Barbee release histories establish what the vendors report fixing. Flux's actual reliability and speed need the native verification above.


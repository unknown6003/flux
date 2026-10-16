# Visual icon strips: Ice and Barbee

Researched 16 October 2026. Read-only. Sources were read on this date.

Outcome: give the parent a concrete, cited picture of the current Ice and Barbee icon-organising strips, so the Flux Settings editor can copy the interaction and not the app.
Proof: pinned Ice source, the current Ice gallery image, and the current Barbee listing screenshot, each checked at a named ref or asset id.
Constraints: no app edits. No new macOS permission. Preserve Flux's macOS 27 grouped app hiding. No claim about Barbee behaviour that its listing does not state.

The companion file `docs/research/menu-bar-interface.md` holds the wider comparison. This file covers only the strip structure, insertion rules, capture path, keyboard, overflow, and cancel policy.

## Versions and refs checked

| Item | Ref | Note |
| --- | --- | --- |
| Ice repo | `jordanbaird/Ice`, default branch `main` | Not archived. Latest push to some branch 6 October 2026. |
| Ice `main` HEAD | `11edd39115f3f43a83ae114b5348df6a0e1741cf`, 20 September 2025 | Equals the pinned commit already used in `menu-bar-interface.md`. No newer `main` code exists. |
| Ice latest stable release | `0.11.12`, 29 October 2024 | Release notes mention a limited mode without Screen Recording. |
| Ice latest pre-release | `0.11.13-dev.2`, 16 September 2025, titled "Ice 0.11.13 (macOS Tahoe Beta 2)" | The newest Ice build. |
| Ice other branches | `macos-26` head `6d74d25c33a9ab04307c1f222fbe68ad71847234` (20 September 2025, "Bump version and build numbers"), `macos-26-old`, `profiles` | The strip code was read from `main`. |
| Ice gallery layout image | `https://icemenubar.app/gallery/menu-bar-layout.png` | Downloaded again this run. sha256 `4437e61cbde37ea5f155dabfe4e511c70d7456a60bd0e6523b216800579af59b`, 2416x1468. Identical to the retained file. The reference image is still current. |
| Barbee listing | `https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12` | Version 5.0, "Sep 10", macOS 11.0+, seller 翔 何 / HyperartFlow Apps. Free with in-app purchases. |

Ice source paths below are relative to the pinned tree `https://github.com/jordanbaird/Ice/tree/11edd39115f3f43a83ae114b5348df6a0e1741cf`.

## Ice strip structure and order

Source: `Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift`, `Ice/UI/LayoutBar/LayoutBar.swift`, `Ice/MenuBar/MenuBarSection.swift`.

The page shows one header, one tip box, then one lane per enabled section.

1. Header, `Text("Drag to arrange your menu bar items")`, font `.title2` (line 26).
2. Tip group box, a `Label` with the `lightbulb` SF Symbol and the exact text `Tip: you can also arrange menu bar items by Command + dragging them in the menu bar` (line 35).
3. `VStack(spacing: 25)` running `ForEach(MenuBarSection.Name.allCases)` over `visible`, `hidden`, `alwaysHidden`, in that order (line 46, enum order at `MenuBarSection.swift` lines 12 to 15).
4. Each lane is `VStack(alignment: .leading, spacing: 4)` holding a 14-point label and the strip (lines 80 to 86).

The lane labels come from `Name.displayString`: `Visible`, `Hidden`, `Always-Hidden`, so the rendered titles are `Visible Section`, `Hidden Section`, `Always-Hidden Section`.

A lane appears only when `section.isEnabled` is true (line 78). `isEnabled` is `true` for `visible`, and `controlItem.isAddedToMenuBar` for the other two (`MenuBarSection.swift` lines 101 to 108). A disabled section therefore disappears instead of leaving a dead empty lane.

Strip geometry, `LayoutBar.swift` lines 42 to 52:

- Height fixed at 50 points, full available width.
- Clipped to `RoundedRectangle(cornerRadius: 9, style: .circular)` with a `.quaternary` stroke.
- Filled with the menu bar's cached average colour, so captured glyphs sit on a menu-bar-like background. Text colour flips on a brightness threshold of 0.67.
- If the image cache failed for the section, the strip is replaced by `Text("Unable to display menu bar items")` (line 57).

Inside the strip, `LayoutBarScrollView` holds a `LayoutBarPaddingView` that holds a `LayoutBarContainer` of `LayoutBarItemView` values. Items lay out left to right in array order (`LayoutBarContainer.swift` lines 55 to 57). Each item view is sized to the real menu bar item frame and draws its captured image centred (`LayoutBarItemView.swift` lines 74 to 79, 124 to 131).

Observed in `docs/research/menu-bar-references/ice-layout.png`: sidebar with General, Menu Bar Layout, Menu Bar Appearance, Hotkeys, Advanced, Updates, About. Right pane has the header, the tip box, and three labelled blue lanes with real menu bar glyphs.

## Insertion semantics

Sources: `Ice/UI/LayoutBar/LayoutBarItemView.swift`, `Ice/UI/LayoutBar/LayoutBarPaddingView.swift`, `Ice/UI/LayoutBar/LayoutBarContainer.swift`.

Drag start. `mouseDragged` on the item view begins an `NSDraggingSession` from the view's full bounds, with the captured image as the drag image (lines 152 to 177). The pasteboard type is the bundle id plus `.layout-bar-item` (line 231). The whole item is the source, not a handle.

Drop target. The padding view registers for that type and forwards `entered`, `exited`, `updated`, and `ended` to the container (lines 61 to 85). The whole lane is the drop target.

Live gap. `updateArrangedViewsForDrag(.updated)` finds the arranged view nearest the pointer's x by midpoint distance (`LayoutBarContainer.swift` lines 246 to 257, 295 to 301). A swap needs the pointer within half the destination's width of its midpoint, that is, near the horizontal centre (lines 259 to 267). The code refuses a move onto a disabled view or a view whose layer has running animations (lines 251 to 254).

Same-section reorder. When the source is already in the container, the code applies `arrangedViews.move(fromOffsets: [sourceIndex], toOffset: targetIndex)`, where `targetIndex` is the destination index, plus one when the destination index is larger, so the item lands after the destination (lines 268 to 275).

Cross-section insert. When the source comes from another container, the code applies `arrangedViews.insert(sourceView, at: destinationIndex)` (line 279).

Empty section. With no enabled arranged views, the code inserts the source at index 0 (lines 240 to 245). An empty lane keeps working as a destination.

Single-item lane. At drop time, a one-item lane cannot use a neighbour, so the code picks a target: `hidden` uses `.hiddenControlItem`, `alwaysHidden` uses `.alwaysHiddenControlItem`, and `visible` uses `nil` with the comment that the visible section always has more than one item (`LayoutBarPaddingView.swift` lines 98 to 112).

Commit. `performDragOperation` derives the destination from a neighbour: right neighbour uses `.leftOfItem(target)`, else left neighbour uses `.rightOfItem(target)` (lines 113 to 121). The move waits 25 ms, runs `itemManager.slowMove(item:to:)`, then clears the temporary shown-item cache; an error raises `NSAlert(error:)` (lines 127 to 142). The drop returns `true` even when a one-item visible lane finds no target; that path logs `No target item for layout bar drag`.

## Capture permission, real glyphs against app icons

Sources: `Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift`, `Ice/MenuBar/MenuBarItems/MenuBarItemImageCache.swift`, `Ice/Utilities/ScreenCapture.swift`, `Ice/Permissions/Permission.swift`.

Ice lanes show real menu bar glyphs, not app icons. The item view draws `images[item.info]`, a cropped capture of the live menu bar window (`LayoutBarItemView.swift` lines 92 to 102). The cache captures window images with `ScreenCapture.captureWindows` and crops each item frame, with a per-window fallback when the composite capture fails (`MenuBarItemImageCache.swift` lines 135 to 187). There is no owner-app-icon fallback in the strip.

Screen Recording is required for this strip. The pane's body checks `ScreenCapture.cachedCheckPermissions()` and otherwise shows `Menu bar layout requires screen recording permissions` with a link button to Advanced Settings (lines 12 to 15, 60 to 72). The permission itself is declared optional (`isRequired: false`) with the detail `Display images of individual menu bar items.`, while Accessibility is required with `Arrange menu bar items.` (`Permission.swift` lines 118 to 157). The release notes for 0.11.12 confirm a limited mode without Screen Recording.

The permission probe reads a non-Ice menu bar item title and falls back to `CGPreflightScreenCaptureAccess()`; the request uses `SCShareableContent` on macOS 15 and later, else `CGRequestScreenCaptureAccess()` (`ScreenCapture.swift` lines 12 to 55).

Consequence for Flux. Keep Screen Recording optional. Show real glyphs after an explicit grant, and use the owning app icon without that grant. Capture only while the editor is open. This updates the earlier app-icon-only decision in `menu-bar-interface.md`.

## Keyboard path

No explicit keyboard reorder handler was found in the inspected Ice editor files. A grep for `keyDown`, `keyboard`, and `keyEquivalent` across the read LayoutBar files returns nothing. The only accessibility hooks are `LayoutBarScrollView.accessibilityChildren()` returning the arranged views, and `LayoutBarItemView: NSAccessibilityLayoutItem` (`LayoutBarScrollView.swift` line 73, `LayoutBarItemView.swift` line 227). The inspected files do not prove a working VoiceOver move action. No runtime accessibility test was run.

The only documented non-drag route is the native Command-drag on the real menu bar, named in the tip box. Global Hotkeys toggle whole sections (README: `Toggle individual menu bar sections`), not item order.

Flux should keep an explicit Move menu and keyboard reorder actions with accessibility labels. Barbee keyboard behaviour remains unknown.

## Overflow and scroll

Source: `Ice/UI/LayoutBar/LayoutBarScrollView.swift`.

The strip is an `NSScrollView` with `hasHorizontalScroller = true`, a custom mini `NSScroller` whose knob slot is transparent, and `autohidesScrollers = true` (lines 38 to 44, 78 to 92). Both scroll elasticities are `.none` and it does not draw a background.

The document view is constrained to the content height, given a width greater than or equal to the content view, and its trailing anchor equals the content view's trailing anchor (lines 51 to 63). A long section therefore scrolls horizontally and the items stay pinned to the right edge, matching the menu bar. A short section pins right as well.

## Stale target and cancel policy

Sources: `LayoutBarItemView.swift`, `LayoutBarContainer.swift`, `LayoutBarPaddingView.swift`, `MenuBarItemImageCache.swift`.

- No fly-back animation: `session.animatesToStartingPositionsOnCancelOrFail = false` (line 194).
- The source draws nothing while dragging: `isDraggingPlaceholder` is set true asynchronously at session begin and false at session end (lines 196 to 213).
- Cancel into no lane: the container's arranged views are frozen during the session with `canSetArrangedViews = false` (lines 189 to 191), and the source records its origin once at the first `.updated` as `oldContainerInfo = (container, index)` (`LayoutBarContainer.swift` lines 234 to 239). If the item never entered a lane (`hasContainer == false`), end-of-session reinserts it into the original container at the original index without animating (lines 215 to 223). `oldContainerInfo` is always cleared at the end (lines 203 to 206).
- Leaving a lane mid-drag removes the source from that lane's arranged views (`LayoutBarContainer.swift` lines 227 to 232).
- Immovable item: `isEnabled` is `item.isMovable`. A drag attempt shows `Menu bar item is not movable.` with `macOS prohibits "<name>" from being moved.` The image draws at 0.67 opacity (lines 79, 110 to 115, 130, 155 to 159).
- Unresponsive owner: a warning badge draws in the item corner; a drag attempt shows `"<name>" is unresponsive. Until it is restarted, it cannot be moved. Movement of other menu bar items may also be affected until this is resolved.` (lines 117 to 122, 132 to 148, 161 to 165).
- Stale capture: the refresh sources merge, then throttle for 0.5 s with `latest: false`, and a 3-second timer still fires at minimum (`MenuBarItemImageCache.swift` lines 43 to 61). `updateCache` skips when the Ice Bar and search are not presented unless the app is frontmost and Settings is on Menu Bar Layout, and skips while `isMovingItem` or `itemHasRecentlyMoved` is true (lines 224 to 258). `cacheFailed(section)` returns true with no Screen Recording, so the lane shows its failure text (lines 85 to 98).
- The pane also blocks with `Ice cannot arrange menu bar items in automatically hidden menu bars` when the system hides the menu bar (`MenuBarLayoutSettingsPane.swift` lines 14 to 15, 53 to 57).

## Barbee: observed layout

Observed from the retained `docs/research/menu-bar-references/barbee-screen2.webp`, which is screenshot 2 of 3 in the current listing. The asset id `PurpleSource211/v4/64/5a/81/645a8160-7465-c981-2205-732bf49e2616/2.png` still resolves in the listing HTML fetched this run, so the retained screenshot is the current v5.0 asset.

What the screenshot shows:

- Right pane title `Preferences`, with a star icon on the instruction line.
- Instruction: `Drag to arrange your menu bar items as you want!`, then an orange tip: `Tip: You can also hold down command ⌘ and drag the icon in the menu bar to change the menu bar layout.`
- Four labelled horizontal lanes, top to bottom: `Shown Items:`, `Hidden Items:`, `Always Hidden Items:`, `Special Item Library:`.
- The first three lanes are blue rounded strips with glyphs right-aligned, matching the menu bar. The Shown lane ends with a clock reading `Sun Aug 31 9:31 PM`. The Hidden lane holds several coloured app tiles (a gear, a person, GitHub, and a few square tiles). Always Hidden holds two tiles plus an ellipsis tile. Special Item Library holds red, purple, and blue symbol tiles.
- Sidebar: General, Menu Bar Layout (selected), Menu Bar Appearance, Widget, Quick Search, Shortcuts, Automation, Profile. Toolbar: coffee cup, gear, ellipsis.

What the screenshot does not establish. The listing never says how Barbee renders those glyphs, so whether it captures real menu bar images, uses owner app icons, or a mix is [unknown]. Do not claim a Barbee capture permission. Everything above is [observed screenshot] for layout only.

Listing text, version 5.0, 10 September: "Refactored the codebase for better compatibility with the latest macOS." and "Improved overall stability and reliability." No layout change is documented, so the retained screenshot is still a fair picture of the current design. The listing sells VIP for unlimited show and hide, notch support, spacing reduction, and cloud profiles. `macbarbee.com` was a placeholder when the earlier run checked it and is not used for technical claims.

## Practical design for Flux

Flux keeps its engine and its macOS 27 path. These points change only the editor.

- One instruction, three lanes, appearance on another page. Ice uses exactly this, and Barbee adds a fourth "Special Item Library" lane plus sidebar scope that Flux should not copy.
- Whole item is the drag source, whole lane is the drop target. Ice drags the item's full bounds and treats the whole padding view as the destination. The earlier Flux row editor had a small handle. The current candidate uses the full icon cell and lane.
- Empty lane must accept a drop. Ice inserts at index 0 when no enabled views remain. Give empty Flux sections the same hit area as populated ones.
- Support exact insertion inside and across lanes. Ice moves the placeholder live and commits once. Flux now records adjacent icons, validates the fresh destination, and verifies physical order before saving.
- Cancel restores the original index with no animation, and nothing persists. Ice freezes the view set during the drag and reinserts at `oldContainerInfo`. Keep Flux's existing identity checks and bounded verification rather than weakening them (`menu-bar-interface.md` line 90).
- Right-align items in the lane. Ice and Barbee both mirror the menu bar; Ice keeps items trailing with a horizontal autohiding scroller.
- Show actual glyphs with optional Screen Recording access. Keep an owning-app-icon fallback and item names in help and accessibility labels.
- Give a specific message for immovable and unresponsive items. Ice raises a distinct modal for each, and draws a warning badge. A silent no-op is worse.
- Keep an explicit Move menu and keyboard reorder actions. The inspected Ice code has no explicit keyboard reorder handler; Barbee behaviour is unknown.
- Preserve macOS 27 grouped app hiding. The retained manual notes that one app can hide several items together and system icons stay visible (`menu-bar-interface.md` lines 59, 130). Two items from one app must not read as independently hideable when the engine moves both. Neither reference shows how it handles this, so it stays a Flux rule, not a copied behaviour.

## Visual references

- `docs/research/menu-bar-references/ice-layout.png`: Ice three-lane layout, real glyphs. Source `https://icemenubar.app/gallery/menu-bar-layout.png`, sha256 `4437e61c...af59b`, still current.
- `docs/research/menu-bar-references/barbee-screen2.webp`: Barbee four-lane layout. Source `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/64/5a/81/645a8160-7465-c981-2205-732bf49e2616/2.png/1286x804bb.webp`, sha256 `18afe633...4bb6`, screenshot 2 of 3 in the current v5.0 listing.

## Evidence limits

No competitor app was installed or run. Ice facts come from the pinned `main` source and are [source]. Barbee facts come only from the current listing screenshot and text and are [observed screenshot]. Where the source does not state a behaviour, this file marks it [unknown]. No glyph-rendering mechanism is claimed for Barbee.

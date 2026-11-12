# Menu-bar drag research

Research date: 2026-11-13. Scope: source and API research only. No Flux implementation, install, app launch, publication, or native gesture test was performed by this researcher.

Outcome: give the owner a source-backed way to isolate the actual editor gesture failure. Proof: pinned competitor source, Apple API contracts, and a native acceptance matrix. Constraints: the owner controls source and reproduction; this researcher owns this note and ignored `build/drag-research/` only. No child agents.

## Findings that matter first

1. Keep the saved mouse-down event until a native trace shows a reason to change it. Apple explicitly specifies the mouse-down event for `beginDraggingSession(with:event:source:)`. Flux follows that contract. Ice instead passes the current mouse-drag event. That difference is an observation, not proof that Flux is wrong. [Apple API](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:)), [Ice source](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarItemView.swift#L152).
2. Test inventory updates during a held drag before changing the physical mover. Flux has no explicit editor drag lifetime. Its destination rejects when the editor becomes busy or the source leaves its window. Ice explicitly blocks inventory-driven replacement in the source container during a drag. This is the closest source-backed lead, but the owner's native reproduction must establish whether either Flux guard actually fires. See the Flux trace and Ice lifecycle below.
3. A successful context-menu move does not prove an editor drag. Both can reach the mover, but the context menu bypasses mouse routing, threshold detection, AppKit session startup, drag type routing, and destination validation. It can also use a group move rather than the drag's exact neighbour slot.
4. Keep editor acceptance and physical placement as separate results. AppKit accepting `.move` says nothing about the real status item's final position. Flux already checks fresh physical layout after posting. Keep that check.
5. Alcove is not a verified menu-bar arrangement reference. Its official site describes a Dynamic Island/notch app. The official FAQ explains how to hide Alcove's own menu-bar icon through macOS. The published changelog calls a tray update upcoming. No inspected official material establishes arrangement of other apps' status items. [Site](https://tryalcove.com/), [FAQ](https://tryalcove.com/faqs/), [official changelog data](https://api.tryalcove.com/changelog).

## Evidence limits and revisions

| Evidence | Revision or date | What was actually inspected |
| --- | --- | --- |
| Flux | `d81218c7c86fa921ae52437a3d53787553c448fd`, clean initial status | Editor view/model, preferences controller, service move/scan paths, move engine, planner, physical drag poster. Read-only. Actual directory is `Sources/`, not `Source/`. |
| Ice | `11edd39115f3f43a83ae114b5348df6a0e1741cf`, commit date 2025-09-20 | GitHub commit/tree API and raw source for layout views and item manager. This is the fetched upstream `main`, not evidence of macOS 27 runtime support. |
| Dimble, formerly Pelmet | `b75839628fca722e26e45b04367f8a37e3b45b4d`, commit date 2026-11-07 | `fif7y/pelmet` redirects to `fif7y/dimble`. Read editor drag session, editor wiring, engine snapshot contract, physical mover, Apply pass, and README. No app run. |
| Bartender | Official 6.6.2 and 7.1.0 release-note pages fetched on research date | Product claims and described fixes only. No proprietary source, binary, imports, or runtime inspection. |
| Alcove | Official site reports 1.7; FAQ updated June 2026; API's newest listed release is 1.7.9, 2026-06-30 | Fetched public HTML, page assets, and the public `/changelog` API used by its own page. The endpoint may lag the installed product. No trial binary or app run. |
| Apple | Current documentation fetched on research date | AppKit source/destination/session/registration/event contracts, macOS status-menu gesture, and Virtualization sample. |

Web search and fetch were used. The web tool could not read Alcove due to robots/access restrictions. Bounded HTTPS requests read the official root and trailing-slash FAQ/changelog pages. The changelog page's own JavaScript points to `https://api.tryalcove.com/changelog`; that public JSON was fetched. This was public site inspection, with no login or access bypass. No screenshots, demo frames, or live competitor gestures were viewed. An image caption in a README is text evidence only.

Ignored evidence lives in `build/drag-research/`. It includes commit/tree responses and small raw source/page snapshots. There is no installed app, cloned worktree, server, watcher, or background process to clean up.

## Apple contracts and the three different drag paths

### Editor drag and drop

`NSView.beginDraggingSession` takes items whose frames use the source view's coordinates. Its `event` parameter is the originating mouse-down event, used to set the image offset. The source controls allowed operations. Session startup returns immediately; actual dragging starts on the next run-loop turn. Source callbacks mark beginning, movement, and completion or cancellation. Do not assume return from startup means the gesture completed. [Start API](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:)), [session](https://developer.apple.com/documentation/appkit/nsdraggingsession), [source callbacks](https://developer.apple.com/documentation/appkit/nsdraggingsource).

A destination registers accepted pasteboard types. AppKit routes entering/updating/exiting messages for matching data. The destination must choose an operation the source also permits. `prepareForDragOperation` gates `performDragOperation`; `perform` imports or commits the drop and returns acceptance. `conclude` is successful-drop cleanup. Use the source's completion callback for session-wide cleanup, including outside drops and cancellation. [Registration](https://developer.apple.com/documentation/appkit/nsview/registerfordraggedtypes(_:)), [destination](https://developer.apple.com/documentation/appkit/nsdraggingdestination), [prepare](https://developer.apple.com/documentation/appkit/nsdraggingdestination/preparefordragoperation(_:)), [perform](https://developer.apple.com/documentation/appkit/nsdraggingdestination/performdragoperation(_:)), [source end](https://developer.apple.com/documentation/appkit/nsdraggingsource/draggingsession(_:endedat:operation:)).

`draggingSource` is an in-process source object; Apple says it is nil for a source in another app. A local object cast is thus a valid way to limit an internal editor. The source mask and destination return still need agreement. Modifiers can narrow the mask unless the source ignores them. Apple's table maps Option to copy, Command to move, and Option+Command to link. This mask negotiation is not a system status-item reorder API. [Source identity](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingsource), [operation mask](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingsourceoperationmask).

Mouse-down routing and drag routing are different checks. `hitTest` finds the deepest visible descendant for mouse-down dispatch. A registered parent destination handles drag messages; it need not be the same object that took the initial mouse-down. Inspect both paths. A local event monitor can return nil and stop normal event dispatch, but Apple says it does not see events consumed by nested tracking loops. Missing monitor output alone does not prove that a drag stopped. [Hit testing](https://developer.apple.com/documentation/appkit/nsview/hittest(_:)), [local monitors](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)).

### Human status-menu reorder

Apple documents Command-drag to rearrange status menus. Control-drag is not the documented reorder gesture. Command-dragging out of the bar can remove a status menu, so an editor test must not accidentally test physical removal. [Apple macOS 27 user guide](https://support.apple.com/en-ie/guide/mac-help/mchlp1446/27/mac/27).

### Programmatic physical movement and private hiding

An editor drop may request a later synthetic Command-drag against the real status bar. That operation uses Quartz coordinates, event posting, user-input checks, and physical inventory validation. It is separate from the local editor's pasteboard session. Private framework hiding is a third mechanism. A source that uses private APIs to hide items does not establish that it uses those APIs to reorder them.

## Flux's actual path and failure gates

Local citations below refer to the inspected Flux revision. The owner may change these lines during reproduction.

| Stage | Source owner | Verified behavior and diagnostic consequence |
| --- | --- | --- |
| State arrives | [Preferences controller:69](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBarPreferencesController.swift:69), [render:96](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBarPreferencesController.swift:96) | Every page update renders the editor. Busy includes moving **or inventory refresh**. A refresh can disable a drag without a physical move being active. |
| Inventory replaces editor state | [Editor:39](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:39), [flow:169](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:169) | The model and tile map refresh. Each flow reuses views by item ID within that flow, then removes leftover views. Source identity is usually stable within one strip, but disappearance, changed identity, or transfer to another strip can detach the original source view. There is no explicit active-session freeze here. |
| Initial gesture | [Tile:335](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:335) | Saves mouse-down. Needs movable, not busy, and at least 3 points of motion. Clears `down`, creates the custom typed item with `id.token`, snapshots the tile, starts a session with the saved mouse-down, and enables cancel animation. No source begin/end callbacks record lifetime. |
| Allowed operation | [Tile:373](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:373) | `.move` within the app; none outside. Ignores modifiers. This matches the intended local move path. There is no source-mask mismatch proved by this source read. |
| Destination routing | [Flow:159](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:159), [validation:244](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:244) | Flow registers the custom type. Validation requires not busy, a `MenuBarTileView` source, the same source/destination window, a decodable token, and token/source-ID equality. Detaching the source makes `source.window` nil and can fail this check even if AppKit still has the source object. This is an inference about the failing runtime, not a captured event. |
| Hover and drop | [Flow:264](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorView.swift:264) | Enter delegates to update. Valid hover shows a marker and returns move. Prepare rechecks identity. Perform recomputes insertion and requests a model move, then returns true. It also returns true when model movement is nil. That can mean a valid no-op; distinguish it from a requested move that never reached the service. |
| Slot identity | [Model:33](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxUI/MenuBar/MenuBarLayoutEditorModel.swift:33) | Drag computes neighbours excluding the dragged item. Same-slot and forbidden moves return nil. Group context-menu moves use a different intent and let the service choose fresh anchors. |
| Service entry | [Service:444](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxApplication/MenuBar/PositionMenuBarService.swift:444) | Silently returns unless started, editor visible, and no scan or move task exists. A drop can reach `onMove` yet fail this service gate. Trace it explicitly. |
| Refresh race | [Service:809](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxApplication/MenuBar/PositionMenuBarService.swift:809) | Scan sets `isRefreshing` before its async inventory read and publishes state during the scan. The controller propagates this to editor busy state. Whether a scan overlaps the owner's gesture remains unproved. |
| Physical move | [Engine:18](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxApplication/MenuBar/MenuBarMoveEngine.swift:18), [poster:27](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxPlatform/MenuBar/MenuBarItemDrag.swift:27) | Fresh read and plan; up to three attempts; waits for quiet input; posts off-main-thread; polls six times at 250 ms per attempt. Poster has five stepped Command-drag events and restores cursor/modifier state. This path cannot repair a gesture that never reaches it. |
| Success check | [Planner:174](/var/lib/t3code/dev/flux-toggle-repair/Sources/FluxCore/MenuBar/MenuBarLayout.swift:174) | Checks the requested group, physical side where needed, and named strip neighbours for slot moves. Existing correctness checks are stronger than treating any frame change as success. |

### Recommended next trace, before a fix

Use one short-lived diagnostic run on the owner's actual macOS app. Give each session an ID and log monotonic time, view object identity, item ID, window number, source/destination frames, busy state, and inventory generation. Record these edges:

`mouseDown -> mouseDragged threshold -> begin request -> source willBegin -> source operation mask -> destination entered/updated -> prepare -> perform -> model move or nil reason -> onMove -> service accepted or guard reason -> physical plan/post -> fresh placement verdict -> source ended operation`.

Log each failed destination guard separately. Record view removal/reparenting and `update(tiles:)` during the session. Do not log only the final Bool. Use native source callbacks as the authoritative session boundary; a general local monitor is supporting evidence only.

Interpret the first missing edge:

- No tile mouse-down: inspect hit test, covering views, clipping, inactive-window routing, and event consumers.
- Mouse-down but no threshold/session: inspect `movable`, `busy`, saved event, pointer deltas, and source view replacement.
- Session but no destination: inspect registered type, actual destination bounds, hit hierarchy, and window geometry.
- Destination entered then refuses: inspect busy, source window, token, and source identity changes at that time.
- Perform but no move: inspect same-slot/permission model result and service scan/move gates.
- Physical post but wrong order: inspect fresh anchors, real input, screen coordinates, settling, and item identity. Only this branch justifies changing the physical poster.

If updates do invalidate the drag, my pick is a small editor-owned session state. Hold the source identity, originating editor/window, model generation, and insertion anchors through completion. Defer structural tile replacement while dragging, then reconcile once at the end. Continue cheap image updates only if they cannot change hit/drop geometry. Revalidate fresh source and neighbour identities before physical work. A disappeared app must fail or cancel cleanly; freezing the UI must not authorize a stale move. This is a proposed independent design, not an implementation or a proved fix.

## What Ice actually does

All Ice links pin the 2025 revision above. They do not prove macOS 27 behavior.

- [LayoutBarItemView:152](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarItemView.swift#L152) starts from `mouseDragged`, checks enabled state and owning-process responsiveness, writes an empty custom pasteboard payload, and uses the current drag event. The payload is a type marker. Identity comes from the local source object and its immutable `item`.
- [Source lifetime:186](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarItemView.swift#L186) blocks source-container arranged-view replacement, disables snap-back animation, and marks a placeholder on the next main-queue turn. It retains origin container/index in `oldContainerInfo`. Source completion restores a view dropped outside a container and clears origin info.
- [Container:185](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarContainer.swift#L185) refuses inventory-driven view replacement when its gate is closed. Drag updates move the source view itself among containers. It saves origin state, handles an empty destination, and avoids swapping through an animated destination. This differs from Flux's insertion-marker-only UI. No need to copy that UI to adopt a valid session lifetime.
- [Padding destination:61](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/LayoutBar/LayoutBarPaddingView.swift#L61) owns type registration and forwards callbacks. Perform picks a left/right live item or section control as anchor. A task waits 25 ms before physical movement. Its successful drop path asynchronously reopens the receiving container's replacement gate. Do not assume the inspected code proves every original-container gate reopens on every cancellation path.

[MenuBarItemManager:985](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L985) moves physical items through targeted synthetic down/up events, a fallback release, PID/session event routing, and frame observations. It is not just Flux's coordinate-based stepped HID drag. Its event factory sets PID/window fields, including a raw field `0x33`, and Command on move-down. [Event fields:1531](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L1531), [factory:1638](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L1638).

The manager waits for modifiers and mouse activity, stops/restarts its app event manager around a move, and restores the cursor with deferred cleanup. It retries movement up to five times. `move` checks a changed frame; the editor calls `slowMove`, which additionally waits for exact edge adjacency to the target with a one-second limit. Event reception also has short timeouts. Cache refresh waits for movement and skips unchanged item window lists. These are separate protections for physical movement and inventory churn. [Move and slowMove:1075](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L1075), [position check:638](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L638), [cache:315](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L315).

Useful idea: own and end the editor session explicitly. Do not transplant its raw event fields, exact frame equality, or old-OS mover into Flux as a presumed macOS 27 fix. Event delivery acknowledgment proves receipt, not final placement.

## Current macOS 27 reference: Dimble

The public Pelmet URL now redirects to Dimble. Its pinned source offers a more current comparison, with two mechanisms kept apart.

[EditorDragSession:17](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Pelmet/Settings/EditorDragSession.swift#L17) owns item ID, home section/index, and target slot outside the tile view. A strip has one drop target. The source creates a text provider, while local session state supplies identity. Drop clears the session before calling the move handler. An end watcher detects button-up for outside drops; deinit cancels it. The code's active-session check also requires a held button, avoiding a stale flag. This is a SwiftUI workaround; Flux can use AppKit's native completion callback. [Tile wiring:762](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Pelmet/Settings/MenuBarTab.swift#L762), [drop handler:373](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Pelmet/Settings/MenuBarTab.swift#L373).

[ItemMover:37](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Packages/PelmetEngine/Sources/PelmetEngine/ItemMover.swift#L37) performs coordinate-based HID Command-drag off the main actor. It tags synthetic input, waits for a quiet gap, hides/restores the pointer, and uses a temporary active event tap to block competing physical mouse input. Its step count scales with distance. There is also a jump-mode retry. The source reports local runtime trials, but those comments are the project's evidence, not trials reproduced here. It releases Command using a synthetic key-up. Flux instead tracks real modifier changes and restores flags with a mouse event; do not replace that policy without checking held-key cases.

[ApplyPass:329](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Pelmet/App/ApplyPass.swift#L329) waits for repeated stable frame observations within a cap. [Placement:688](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Pelmet/App/ApplyPass.swift#L688) reads fresh frames, checks a neighbour slot, moves, waits, checks again, and can re-aim once. Failed and skipped items remain distinct. [Snapshot:32](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Packages/PelmetEngine/Sources/PelmetEngine/MenuBarEngine.swift#L32) marks whether inventory was read at rest. An inventory taken during reflow is not order proof.

Its private `MenuBarClientCore` path handles hiding. It does not eliminate synthetic dragging for physical order. [Engine order hint:453](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Packages/PelmetEngine/Sources/PelmetEngine/AgentBarEngine.swift#L453) writes an order hint, while comments explicitly warn that this does not reorder already-live registrations. The actual mover also resolves private CGS symbols for background cursor hiding. Thus the README's broad public-API claim for everything except hiding is too broad for the inspected cursor path. [Cursor SPI:242](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/Packages/PelmetEngine/Sources/PelmetEngine/ItemMover.swift#L242), [README disclosure](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/README.md#L173).

Useful ideas: retain drag intent independently of tile rebuilding, judge physical order only from settled data, and expose pending/failed placement. Active input suppression is a larger product and permission tradeoff than Flux needs for an editor-session repair. It temporarily blocks the user and adds tap/run-loop cleanup. Do not add it unless the actual failure occurs during physical posting.

## Bartender and Alcove: supported claims only

Bartender's current official notes establish layout and physical movement support. Bartender 6.6.2 reports fixes for disappearing editor items and reduced work while settling the bar. Version 6.5.1 says unresolved item identity delays live arrangement and describes an on-demand mode with organization status. These support stable identity and bounded work as design goals. They reveal no implementation of drag retention. [Bartender 6 notes](https://www.macbartender.com/Bartender6/release_notes/).

Bartender 7.1.0 supports Tahoe as well as Golden Gate. Earlier 7 notes describe movement without borrowing the pointer, optional Screen Recording with app-icon fallbacks, and limits on app-wide hiding. Version 7.0.4 describes stuck movers, duplicate-looking items, and recovery guidance. Version 7.0.5 avoids repeated failing image captures. The exact reorder API, editor payload, and drag freeze policy remain unknown. Do not infer private framework symbols from these claims or equate 6 and 7 mechanics. [Bartender 7 notes](https://www.macbartender.com/Bartender7/release_notes/). No Bartender 3 FAQ was used.

Alcove's official materials establish notch interactions, media/HUD controls, notifications, and gestures. The FAQ discloses private API use but does not name a reorder API. The official changelog mentions a notch press-and-drag visual fix, slider drag fixes, and a planned tray. It does not establish a shipped file-drop shelf or other-app menu-bar arrangement. Compare only relevant lifecycle concerns: notch hover/expand/collapse, hit areas, slider press-versus-drag, cancellation, and UI state after a gesture. Its actual payload, source retention, file promises, and drop completion are unknown. There is no evidence here to recommend Alcove's internal drag mechanics. [FAQ](https://tryalcove.com/faqs/), [changelog page](https://tryalcove.com/changelog/), [first-party JSON](https://api.tryalcove.com/changelog).

## Evidence verdicts

| Status | Claim | Evidence or missing proof |
| --- | --- | --- |
| Verified | Flux passes the event Apple documents. | Apple start API and Flux tile line 347. |
| Verified | Flux can reject a drop when busy or source-window identity changes. | Destination guard at line 245; controller busy mapping at line 96. |
| Inferred | An inventory scan may be the user's drag failure. | Code permits the overlap; no native trace in this research proves it occurred. |
| Verified | Ice freezes arranged-view replacement in the drag's source container. | Pinned source callback and container gate. This is not a claim that all Ice views/images freeze. |
| Verified | Dimble separates editor intent, private hiding, and physical Command-drag. | Pinned editor, engine, and mover source. |
| Verified | Flux already validates requested physical slot/group after posting. | Move engine and planner. Context-menu success covers only a subset of the drag route. |
| Unknown | Which Flux stage first fails on the owner's hardware. | Need one real pointer drag with callback/guard trace and physical before/after inventory. |
| Unknown | Bartender's private mechanics and freeze policy. | Closed source; current release notes describe outcomes only. |
| Not established | Alcove arranges other apps' menu-bar items or ships a file shelf. | Inspected official site/FAQ/changelog do not document it; current API still labels tray work as forthcoming. This is bounded absence of evidence, not proof about all binaries. |
| Unknown | VM and hardware results match under notch, display, and real input conditions. | Need separate owner-hardware acceptance. |

## Native gesture acceptance matrix

Run on the exact Flux build under test. Save OS/build, Flux SHA/build identity, display layout and scale, input device, permissions, item IDs, session trace, and fresh physical order. A context-menu invocation or direct model call is a control, not the gesture test. Use a pointer press, held-button motion across the threshold, hover, and release.

| Case | Gesture and setup | Required result and evidence |
| --- | --- | --- |
| Basic startup | Idle editor, movable tile, active window, drag at least 10 points. Repeat with mouse and trackpad. | One session begins, image tracks, destination sees the typed payload, one completion fires. |
| Inactive window | Start the same drag while another app is active. | Tile receives the first gesture or the product has a clear activation rule. No window move. |
| Same strip | Move left, right, first, and last. Include wrapped rows and gaps. | Marker and requested neighbours match the final physical slot. One move request. |
| Cross strip | Shown to Hidden, Hidden to Shown, and each allowed Always Hidden direction. | Correct item identity, intended group, fresh physical side and slot. Account for per-app hiding. |
| Empty strip | Drop into a completely empty enabled lane. | Slot zero, valid group anchor, visible result. No dependence on a peer tile. |
| No-op and locked item | Drop back in the same slot; try a system-pinned tile. | No physical post for no-op or forbidden move. No false moved status. |
| Inventory overlap | Hold a drag across a real refresh, icon image update, app launch/quit, or item rehost. | Source session remains valid or cancels with a stated reason. No silent rejection, wrong-item move, or stale anchor use. |
| Busy at start | Begin while the page is refreshing or a move is running. | No session if intentionally disabled. Busy state is visible and clears. No partial source state. |
| Cancel/outside | Escape; release outside all lanes; leave/re-enter; close Settings during drag. | No physical move. All session references, marker, cursor, and gates clear. Next drag works. |
| Modifier keys | Plain drag, Command, Option, Control, then change keys mid-drag. | Internal editor remains move-only per Flux policy. No sticky key or accidental OS removal. |
| Identity and security | External app supplies the same pasteboard type; source item disappears or relaunches. | Reject external/stale identity. Keep same-editor/window boundary or a stronger explicit session boundary. |
| Permission states | Accessibility revoked before start and between drop/post; Screen Recording denied. | Specific failure for unreadable/unmovable physical items. App-icon editor still works where supported. No screenshot permission required merely to drag a tile. |
| Own and third-party items | Drag Flux's own item and another app's item. Include an app with multiple items. | Main thread stays responsive; correct per-item order; app-wide hiding semantics remain clear. |
| Display and overflow | Notched owner display, external display, scaled display, overflow, menu-bar auto-hide. | Correct source/target screen coordinates and actual slot. No claim based only on an editor animation. |
| Physical rejection | Use an item that refuses a posted move or a disappearing neighbour. | Bounded retries, fresh plan, clear not-placed state. Saved group alone is not movement proof. |
| User input and recovery | Move/click/type during physical posting; cancel a pending move. | No stray click, stuck modifier, hidden cursor, duplicate task, or unintended later move. |
| Repeat/performance | Ten real drags, then close the editor. | One session per drag, no retained source/gate, no scan storm, capture retry loop, or continued editor-only work. Record CPU/latency without inventing thresholds. |

Before changing physical timing, collect the first failing callback and the corresponding frame/order read. A repeatable idle success plus refresh-overlap failure is much stronger evidence for a session freeze than a context-menu test.

## macOS host and VM test plan

The closest proof is the owner's actual Mac and physical pointer. A second macOS host can supply AppKit/WindowServer testing for the exact build, but still needs its own permissions and representative status items. Linux cannot execute this native path. An iOS Simulator runs neither the macOS AppKit editor nor MenuBarAgent and cannot validate this gesture.

For a macOS guest, use Apple's Virtualization sample on Apple silicon. Its `InstallationTool` installs an eligible macOS restore image into a VM bundle. `macOSVirtualMachineSampleApp` runs that bundle with a graphical `VZVirtualMachineView` that accepts mouse and keyboard input. Configure signing/Virtualization entitlement as the sample directs. [Apple sample](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon).

A follow-up operator can run the test this way:

1. On an authorized Apple-silicon Mac, check for an existing VM and installed toolchain first. Select a guest OS build that matches the target. Confirm host support for that restore image before allocating disk or downloading it.
2. Build the Apple sample with signing, install the guest, and boot it to a desktop. Use bounded install/build/readiness steps with exact process handles and logs. Do not leave an unattended install prompt or start a guest on this Linux researcher host.
3. Copy the pinned Flux build and a few known status-item apps into the guest. Grant Accessibility inside the guest. Test without Screen Recording first, then enable it only for captured-icon cases. Host permission does not establish guest permission.
4. Drive a real held-button gesture through the VM's graphical view. Confirm modifiers reach the guest rather than a host shortcut. Record guest callbacks and physical guest status-item frames before/after. Re-run basic, cross-lane, empty-lane, refresh, and cancellation cases.
5. Shut down the guest and quit the sample after the run. Keep only explicitly retained VM evidence/images; delete disposable copies under the task's cleanup plan.

This is a test plan, not a test result or authorization to install a VM now. A VM can isolate OS versions and inventory churn. It does not reproduce the owner's notch, multiple displays, refresh rate, physical input path, third-party inventory, or hardware permission history. Passing it never replaces the owner-hardware matrix. The Apple sample source supports VM setup, not the claim that a guest reproduces every status-bar behavior.

## Cost, permissions, and reuse

A short session freeze adds a small deferred-update queue and delays structural inventory display until release. It should not require a new system permission. Keep fresh physical validation after the freeze so the visual snapshot cannot become authority for a stale item. Polling for settled geometry adds reads and latency; cap it and stop after success. Flux already has a bounded placement loop, so measure a defect before adding another.

Screen Recording supports real item images, not local pasteboard routing. Accessibility supports physical inventory and control. Active HID taps and private framework calls add different failure and permission paths. Bartender's optional capture and Dimble's capture-free fallback show why the editor should keep working with app icons. Proprietary permission requirements must not be inferred from an old FAQ or marketing slogan.

Ice and Dimble both publish under GPL-3.0. [Ice license](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/LICENSE), [Dimble license](https://github.com/fif7y/dimble/blob/b75839628fca722e26e45b04367f8a37e3b45b4d/LICENSE). No competitor code was copied into Flux. Treat these sources as observations of API use and architecture. Implement any accepted Flux change independently from the Apple contract, Flux's own model, and a proved native failure. Do not port GPL code or assume a renamed translation avoids its license. Private API observations are not Apple support guarantees.

## Handoff

The next action belongs to the source owner: reproduce one actual pointer drag and locate its first failed edge. My first candidate to test is refresh-driven busy/source-window invalidation. Keep the documented mouse-down argument, type/identity checks, and fresh physical order verification unless native evidence points elsewhere. No production fix was made in this research.

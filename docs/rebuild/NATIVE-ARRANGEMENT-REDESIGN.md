# Menu-bar ordering without cursor movement

2026-11-14. The owner requires ordering by dragging tiles inside Settings. A native Command-drag guide does not satisfy that request. Group changes must remain usable and must never borrow the pointer.

## Mechanism

On this Mac, MenuBarAgent observes TrailingItemPreferredPositions in its com.apple.MenuBar group-container preference domain. A targeted preferred-position write changes live order without posting mouse events. Values are distances from the right, so larger weights sort to the left.

The first disposable tests wrote the wrong keys. The actual keys were status:probe::FluxOrderA and status:probe::FluxOrderB, using the executable name rather than the test bundle identifier or display name. Those earlier negative tests did not establish an API limitation.

A corrected test placed A at x=1296 and B at x=1252, then reversed them to A=1252 and B=1296. The pointer stayed at the same coordinates and the passive input tap remained enabled. A second test with no visibility assertion also reversed the live frames. No hide/reveal cycle, native allowance change, input suppression or cursor operation is required.

These are Mac-local fixture results. They establish the backend operation, not acceptance of the installed Settings gesture.

## Design

The existing UI to MenuBarPageActions to SettingsEffects to ApplicationHost to MenuBarService path carries a named slot request. Same-group tile drops now reach that service, rather than starting the native guide. Move Left and Move Right use the same request.

The service saves per-app group changes through the existing policy. Every editor move also requests native placement, including an empty-lane drop and a group-menu reapply. It validates current signing evidence, fresh inventory, the saved group revision and each source or peer. Order checks run without setting the editor's global moving state, so group controls remain usable.

MenuBarPositionIdentity resolves a key from the bundle namespace first. Executable and display-name namespaces require unique ownership. Multiple icons require an exact stable AX identifier. The code refuses ambiguous sibling keys; it does not guess from the item's current array index. Clock and the unique Control Center module can be anchors, while system-owned source items remain locked.

Older AppKit items can have no entry in the central table. Their existing NSStatusItem Preferred Position keys supply the real autosave name. Rocket uses rocket_status_item, not Item-0. A Mac-local probe using that name moved Rocket between Tailscale and TG Pro without mouse events. Guessed Item-0 names did not move it. The resolver now accepts an unambiguous legacy name, including a native preference in a sandbox container, and refuses ambiguous siblings. A new central entry has an absent-before edit token so failed moves can remove only their own new entry.

Settings reads native preferred weights, with legacy autosave values as the fallback. Offscreen placeholder frames do not determine the displayed order. Permission-grant retries refresh inventory and identities before resuming the named request.

A native preference save is verified by rereading the exact source and named peer weights. The UI says "Saved order", rather than claiming physical visibility. An icon can be concealed by macOS independently of Flux. Private905/906 owner drags and a separate probe reproduced owner AX frames only two points apart even after a temporary reveal. Those frames cannot establish current physical placement. The temporary Control Center visibility lease was removed. Ordering no longer changes native allowance flags or needs access to the Control Center file.

MenuBarPositionOrder chooses one weight between the named peers. At a strip end it also accounts for unlisted native keys. It refuses exhausted numeric space instead of renumbering other icons.

MenuBarPositionStore serializes writes on an actor. It synchronizes and reads current values, merges only the requested item's weight and preserves unknown entries. The application checks fresh signing and stable source/peer identities before and after the save. It verifies the persisted relative order before reporting a saved order. A failed or canceled move restores only its own value, and only while that value still equals the value Flux wrote. Failed restoration is reported.

Ordering reads only the source and named neighbour owners. On the owner Mac, the broad snapshot saw 138 running owners and was incomplete, while a fresh two-owner snapshot completed in 0.244 seconds. A complete broad desktop scan is not a precondition for a targeted preference write. The scoped read still requires complete source and neighbour identity inventory, stable siblings and fresh signing checks. Successful order publication replaces only those owners in the existing Settings inventory.

There is no event-posting, pointer warp, cursor hiding or input-blocking fallback in this path.

## File access

The tool session can read the protected position domain. A separately launched test app could not. That distinction must not be hidden by fixture success.

If the installed app lacks access, the drop reports that ordering needs file access and shows Allow Ordering. The user's action opens an NSOpenPanel limited to the one expected file:

~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist

Flux keeps a security-scoped bookmark for that file. It requests no Full Disk Access, resets no permission and does not accept its own access prompt. After the owner selects the file, the original request is checked again against fresh state. Canceling the panel preserves group editing.

## Proof and limits

The editor dispatch regression failed on the prior implementation, which started the native guide and sent no slot request. Corrected fixture tests proved live preferred-position ordering with no generated mouse input. Core tests cover native weight direction, unlisted peers, legacy names, ambiguous aliases and sibling identity. Isolated native preference tests cover unknown data preservation, removing a newly created key, conditional removal and restore of the requested source key. Service checks cover verified native order and keeping group controls available when ordering access is missing.

Installed Settings gesture, signing identity and permission behavior are separate checks. Private906 passed the exact-file Shottr grant and queued native reorder. Private907 must qualify the final native-save path and owner experience. No public release follows from unit tests or the old build900 gesture report.

## Source and API evidence

Apple's public status-item API does not establish arbitrary external item placement:
https://developer.apple.com/documentation/appkit/nsstatusitem

The implementation uses CoreFoundation's runtime-resolved container preference entry points already present on this Mac. They are private and may change. Unavailable access or unresolved identities fail without mouse fallback.

Current Thaw source supplied a research lead about preferred-position writes, not implementation code:
https://github.com/thaw-app/Thaw/blob/f4bc831e821264fe2b52e4ea432ad8f2c5551606/Thaw/Items/Manager/MenuBarItemManager+Moving.swift

Bartender 7.1.0 was inspected only for shipped imports and strings, without running or installing it. Its imports do not establish which operation it uses for ordering. No competitor implementation was copied.


Protected legacy names use an exact-file scope for the named app. Shottr stores its AppKit autosave name in its sandbox preferences. Flux reads only NSStatusItem Preferred Position keys and does not write the app's file. The grant is retained across relaunch. Source identity checks precede any native order save.


Private907 passed concealed Rocket order/inverse, Wispr order, Shottr's three-group cycle and a TG Pro physical move ahead of Tailscale. One TG Pro inverse reported an identity failure, while a fresh repeat and the native store probe both succeeded. The precise rejection stage was not captured. Scoped inventory now allows two bounded100ms rereads when a requested owner is temporarily absent. Existing but changed or ambiguous identities still fail immediately. A regression drops a peer from the first post-save snapshot, then restores its original identity, and requires one native save only. Private908 still needs the real inverse path repeated.


### Owner correction: Visible must be right of the chevron

The owner accepted908's normal in-app dragging as almost perfect, then reported that a move to Visible could leave the icon left of the chevron. A real908 drop of TG Pro into an empty Visible lane reproduced it. The group changed, but its native weight stayed272 while the chevron was174. The owner AX origins stayed1336 and1483 respectively. No native ordering request ran because the slot had no neighbours.

All editor requests now enter the native ordering path. The store uses the same autosave name as the owned chevron control, with a shared key factory. Visible weights must be smaller than the chevron's current weight; Hidden and Always Hidden weights must be larger. Named peers on the wrong side cannot pull a source across the chevron. A group-only reapply preserves the weight when it is already on the right side. Missing or invalid chevron identity refuses writes. Neither the chevron nor any peer is written.

Production verification now rereads the native chevron and the normalized placement bounds. It does not accept the group label alone. Existing signing, sibling, inventory revision and conditional restore checks remain. No cursor or native allowance operation was added. Tests exercise empty Visible drops, menu reapply, all three group sides, invalid-side peers and a chevron moved before verification. Private909 live results and the empty-lane coverage limit follow below.


Private909 (0.22.19, source61edd9a) passed eight actual Settings operations on this Mac: Hidden, Visible, Visible reapply, Always Hidden, neighbour-free Visible from the menu, Visible order/inverse, and Hidden restoration. Each saved native weight was on the requested side of the unchanged174 chevron boundary. TG Pro moved from124 to the right of the chevron in the owner AX frames (1471 versus1400, chevron width28). The neighbour-free menu path also passed (1434 versus1400). Reverse Hidden and Always Hidden frame checks passed. These are owner AX frames and saved native order, not readable desktop pixels. The original empty-lane red case has a unit regression; the green live desktop had Passwords in Visible, so it used a blank-area drop and the same neighbour-free menu intent instead of moving unrelated icons to empty that lane.

All289 tests passed with serial scheduling (29UI,56Platform,110Core,94Application). Parallel scheduling retained unrelated widget/update timeout failures; ordering tests passed. Release build and strict signature/leaf-pin checks passed. A result-harness assertion initially expected identical midpoint weights after an inverse; it was corrected to check relative order around the unchanged peer. Native midpoint values need not return to the old number. The60-second passive listener remained enabled and saw no Flux-posted mouse events; app-targeted CUA events are not full global-input coverage. No input posting was added to the native store.

The trial restored only TG Pro's requested native key to272 after restoring its Hidden group. Fresh full native positions and group policy matched this trial's owner baseline; no other position value changed. Installed private909 remains unpublished. Owner acceptance of the chevron correction remains a separate natural-gesture check. Local evidence is in build/chevron-boundary-909; private preferences and screenshots stay local.

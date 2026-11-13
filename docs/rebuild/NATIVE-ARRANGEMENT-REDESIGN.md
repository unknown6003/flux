# Menu-bar ordering without cursor movement

2026-11-13. The owner requires ordering by dragging tiles inside Settings. A native Command-drag guide does not satisfy that request. Group changes must remain usable and must never borrow the pointer.

## Mechanism

On this Mac, MenuBarAgent observes TrailingItemPreferredPositions in its com.apple.MenuBar group-container preference domain. A targeted preferred-position write changes live order without posting mouse events. Values are distances from the right, so larger weights sort to the left.

The first disposable tests wrote the wrong keys. The actual keys were status:probe::FluxOrderA and status:probe::FluxOrderB, using the executable name rather than the test bundle identifier or display name. Those earlier negative tests did not establish an API limitation.

A corrected test placed A at x=1296 and B at x=1252, then reversed them to A=1252 and B=1296. The pointer stayed at the same coordinates and the passive input tap remained enabled. A second test with no visibility assertion also reversed the live frames. No hide/reveal cycle, native allowance change, input suppression or cursor operation is required.

These are Mac-local fixture results. They establish the backend operation, not acceptance of the installed Settings gesture.

## Design

The existing UI to MenuBarPageActions to SettingsEffects to ApplicationHost to MenuBarService path carries a named slot request. Same-group tile drops now reach that service, rather than starting the native guide. Move Left and Move Right use the same request.

The service saves per-app group changes through the existing policy. A slot with named peers also requests ordering. It validates current signing evidence, fresh inventory, the saved group revision and each source or peer. Order checks run without setting the editor's global moving state, so group controls remain usable.

MenuBarPositionIdentity resolves a key from the bundle namespace first. Executable and display-name namespaces require unique ownership. Multiple icons require an exact stable AX identifier. The code refuses ambiguous sibling keys; it does not guess from the item's current array index. Clock and the unique Control Center module can be anchors, while system-owned source items remain locked.

MenuBarPositionOrder chooses one weight between the named peers. At a strip end it also accounts for unlisted native keys. It refuses exhausted numeric space instead of renumbering other icons.

MenuBarPositionStore serializes writes on an actor. It synchronizes and reads current values, merges only the requested item's weight and preserves unknown entries. The application checks fresh, non-overlapping, on-screen source and peer frames before reporting success. It stops verification after its bounded budget. A failed or canceled move restores only its own value, and only while that value still equals the value Flux wrote. Failed restoration is reported.

Ordering reads only the source and named neighbour owners. On the owner Mac, the broad snapshot saw 138 running owners and was incomplete, while a fresh two-owner snapshot completed in 0.244 seconds. A complete broad desktop scan is not a precondition for a targeted preference write. The scoped read still requires complete source and neighbour geometry, stable sibling identity and fresh signing checks. Successful order publication replaces only those owners in the existing Settings inventory.

There is no event-posting, pointer warp, cursor hiding or input-blocking fallback in this path.

## File access

The tool session can read the protected position domain. A separately launched test app could not. That distinction must not be hidden by fixture success.

If the installed app lacks access, the drop reports that ordering needs file access and shows Allow Ordering. The user's action opens an NSOpenPanel limited to the one expected file:

~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist

Flux keeps a security-scoped bookmark for that file. It requests no Full Disk Access, resets no permission and does not accept its own access prompt. After the owner selects the file, the original request is checked again against fresh state. Canceling the panel preserves group editing.

## Proof and limits

The editor dispatch regression failed on the prior implementation, which started the native guide and sent no slot request. Corrected fixture tests proved live preferred-position ordering with no generated mouse input. Core tests cover native weight direction, unlisted peers, ambiguous aliases and sibling identity. An isolated native preferences test covers unknown data preservation and conditional restoration. Service checks cover fresh placement and keeping group controls available when ordering access is missing.

Installed Settings gesture, signing identity and permission behavior are separate checks. They remain required before owner acceptance. No public release follows from unit tests or the old build900 gesture report.

## Source and API evidence

Apple's public status-item API does not establish arbitrary external item placement:
https://developer.apple.com/documentation/appkit/nsstatusitem

The implementation uses CoreFoundation's runtime-resolved container preference entry points already present on this Mac. They are private and may change. Unavailable access or unresolved identities fail without mouse fallback.

Current Thaw source supplied a research lead about preferred-position writes, not implementation code:
https://github.com/thaw-app/Thaw/blob/f4bc831e821264fe2b52e4ea432ad8f2c5551606/Thaw/Items/Manager/MenuBarItemManager+Moving.swift

Bartender 7.1.0 was inspected only for shipped imports and strings, without running or installing it. Its imports do not establish which operation it uses for ordering. No competitor implementation was copied.

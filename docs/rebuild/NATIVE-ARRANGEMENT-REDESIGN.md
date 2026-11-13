# Native arrangement on the owner Mac

2026-11-13. The owner's correction overrides prior drag acceptance reports.

Settings tiles previously requested slot moves through MenuBarItemMove, the application move engine and MenuBarItemDrag. The latter posts global Command-drag events, hides the cursor and warps it back. This is the cursor borrowing the owner rejects. An AppKit dragging session inside Settings does not become a native status-item dragging session.

Apple documents direct human Command-drag for status menus:
https://support.apple.com/en-mn/guide/mac-help/-mchlp1446/mac
The public NSStatusItem and NSStatusBar contracts do not establish a supported arbitrary-position setter for other applications' items:
https://developer.apple.com/documentation/appkit/nsstatusitem
https://developer.apple.com/documentation/appkit/nsstatusbar
This is a limit of the inspected public contracts, not proof that no private technique exists. The pinned Ice source in MENU-BAR-DRAG-RESEARCH.md uses synthetic events and cursor restoration too. No cursor-free programmatic reorder is claimed.

## Decision

Use direct native arrangement for order. Settings has Arrange in Menu Bar and Done Arranging. Arrange reveals all icons and keeps them revealed while the user holds Command and drags actual status icons. Flux does not post a reorder or reposition the pointer. The Flux checkmark also finishes the guide. Closing Settings ends the mode.

A same-group tile order request opens the guide. Its menu offers the same action instead of Move Left/Right. Cross-group drops and explicit group commands now use the per-app hiding policy alone on macOS 27. The Settings service no longer has a physical move task, retry loop or synthetic mouse driver. Position-based systems start the explicit native guide instead of posting input.

On macOS 27, Done reads fresh inventory but does not infer saved groups from geometry. Groups are per-app choices. Physical boundary labels stay absent in that mode. Older position-based systems retain their native group-boundary behavior.

## Owner correction after build 901

The owner rejects the native guide as a solution for ordering inside Settings. That requirement remains unresolved. This follow-up removes cursor borrowing and the moving-state delay from group assignment; it must not be reported as completion of in-app icon ordering.

The old service fixture confirmed that an empty-group assignment posted one physical drag. The new service contract checks immediate policy/tile updates, no moving state, no extra inventory read and zero drag calls across Hidden, Always Hidden and Visible. Per-app group controls also stay usable during inventory refresh; the service queues a choice until fresh identity checks finish. A controller-level regression reproduced the former global disable rule before that rule changed. Live installed checks must observe the actual group gestures and input stream.

## Proof and limits

The real editor request seam was tested before the fix. A same-group slot request emitted one physical move and no guide request, so the new assertion failed. After the fix, it emits one guide request and zero moves. This proves dispatch, not the owner's natural gesture.

The initial pointer capture missed the live gesture. CUA later returned windowNotFoundAtPosition for fresh tile attempts despite reading Settings. Neither result is physical reorder proof. Owner desktop pixels and direct Command-drag acceptance must be reported separately from local tests and signing.

No public release is authorized by this note.

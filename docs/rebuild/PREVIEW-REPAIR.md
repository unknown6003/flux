# Menu bar preview repair

Outcome: Menu Bar Layout keeps recognizable app icons after loading and Refresh.
First icons do not wait for signing checks. Real screen photos remain available
from the explicit Show Real Icons action.

Proof: native application tests exercise scan and capture demand, a suspended
identity read, refresh and editor teardown. Platform tests cover alpha-only
black photos and capture storage changing after delivery. A signed app must
also pass the owner's Refresh path at opening, five seconds and fifteen seconds.

Constraints: no changes to icon order, saved groups, grants, telemetry or update
identity. Captures retain exact crop bounds, cancellation and geometry checks.
No idle timer or capture is added.

## Observed failure

On 12 November 2026, the installed 0.22.3 showed recognizable icons immediately
after Refresh, then black tiles at approximately five and fifteen seconds.
The observer had not pressed Show Real Icons. Exact transition time and saved
image evidence were not recorded, so these are approximate observations.

The scan completion path started screenshots whenever Screen Recording was
already allowed. It replaced the initial app icons without an explicit preview
request. The capture adapter classified a copied bitmap but delivered the
original capture image. Its flat-content check also treated alpha changes as
visible glyph content.

## Change

- Inventory scans publish app icons before signing checks finish, while editing
  stays disabled until those checks complete.
- Screen photos require the user's explicit button action. A permission grant
  alone starts no capture, including after Refresh.
- A delivered photo owns the same bitmap used for its content check. Later
  changes to the source provider cannot change the delivered pixels.
- Blank-content detection compares RGB content. Alpha variation alone does not
  qualify a black photo as an icon.

The source-provider test is a storage-lifetime control. It does not establish
that ScreenCaptureKit reused storage during the owner's failure. The observed
unrequested capture is the demonstrated replacement path.

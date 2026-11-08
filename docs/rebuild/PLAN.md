# Flux native rebuild

Outcome: replace the whole app with a small native implementation that preserves the user’s features and saved choices, works through the real Mac interface, and ships as a signed update.
Proof: source and migration tests, paired physical Mac measurements, real actions with recorded outcomes, inspected screenshots and recordings, and a signed upgrade from0.21.35 through its own updater.
Constraints: keep Flux, its bundle identity and signing identity. Preserve explicit preferences, shelf files and saved clipboard data. No reset of user grants or global preferences. Do not ship an unproved OS integration.

## Scope

The baseline has84 Swift files and27,310 physical lines, including3,676 lines of in-app self-tests. The preservation map has34 user task groups,34 preference keys, five widgets, eight activity kinds and the updater receipt protocol. See BASELINE.md. These are source counts, not an effort estimate.

The old module repair is stopped. Branch fix/notion-move preserves its commits. Its148MiB evidence is at /var/lib/t3code/artifacts/flux-module-attempt-20261108. Its candidates must not be released as this rebuild.

## Design and architecture choices

Opus owns interface research and experience design. The first concepts are a searchable app list with separate group choices, and a guided native arrange mode. They are proposals, not verified macOS behavior. Read the actual inventory before using old README claims.

Compare two native designs before choosing the final stack:

1. Swift6 with AppKit views and Core Animation for the notch. It gives explicit window, view and service lifetimes. It requires more custom accessibility and layout work.
2. Swift6 with an AppKit shell and SwiftUI content that exists only while visible. It may simplify the interface, but its memory and update work must be measured on the same workload.

The language alone cannot fix a broken OS assumption. First prove the menu-bar backend. Research a native macOS27 per-app allow-list preference path as an alternative to assessment assertions. It is not approved for production until its schema, ownership, notification and physical behavior are proved. Keep physical icon order separate from app visibility. Do not add another timed synthetic-drag workaround.

## Checked sequence

1. Capture the existing app’s real resource costs without changing its settings. Keep all helper processes in the totals. Capture the useful reference interfaces and demos. Complete the flow design against the preservation map.
2. Build a small performance harness for equivalent native shells. Record idle, visible panel, repeated open/close and disabled-feature work. Measure physical footprint, RSS, CPU, wakeups and retained work after close. Choose from results, not a framework slogan.
3. Prove the riskiest menu-bar operations in a small reversible native experiment. Back up only the affected settings, detect concurrent edits, record exact capture coordinates, and restore. Test fresh launch, Spaces, wide dynamic items, sibling icons, permission loss, crash recovery and user input. A UI or system acknowledgement alone is not a physical result.
4. Define pure state and typed persistence. Test literal old preferences and saved-file fixtures before replacing the app shell. Keep startup receipt compatibility and pin the update signer.
5. Implement the native shell and feature lifetimes. Build Menu Bar, notch and widgets behind the same small state interfaces. Create views and expensive services on demand. Preserve all34 task groups or document and resolve a deliberate replacement before release.
6. Integrate Opus’s design, keyboard use, accessibility, reduced motion and permission recovery. Remove old product paths when their replacement works. Do not keep both implementations as the final app.
7. Run the full signed app through real Mac flows, migration and rollback tests, resource comparisons and stress checks. Inspect delivered visual evidence and review source and risks independently.
8. Publish the reviewed source only after all gates pass. Verify the public DMG and the installed app. Clean the isolated space after landing.

## Reliability and performance gates

- Unknown apps stay visible. A failed private interface leaves a usable visible menu bar. The app never reports an unproved move as saved.
- Visibility and reorder tests inspect real pixels or native owner state through a suitable independent check. Record the screen region and active Space. Do not open diagnostic menus while a move is still pending.
- The new app must preserve all explicit stored values and content. New-profile privacy defaults are a separate choice. Existing clipboard persistence or lock-screen choices must not be silently changed.
- No widget animation, camera or display tick runs while its view is hidden. Off features construct no hardware session or helper process. A background clipboard feature may require a bounded low-duty pasteboard check; do not claim zero polling if that feature is enabled.
- Compare the complete process tree with the same signed baseline on the same Mac and workload. Set numeric budgets from those measurements. A missing feature or a stopped helper cannot be counted as a performance win.
- A local compile, a static mockup or one successful gesture is not full acceptance. Treat evidence as verified, not verified or inconclusive.

## Working ownership

Parent: app architecture, OS experiments, code, integration and release. Opus field study: reference evidence only. Opus experience design: flows and visual artifacts only. Inventory/capabilities agent: read-only evidence. Terra: real Mac probes and media, each with a bounded task. Keep at most three repository spaces and serialize integration.

## PostHog

The user added PostHog to the whole-app scope. Implement all applicable native macOS capabilities behind a strict data contract. Do not claim parity with web or iOS-only replay, surveys or interaction autocapture. Do not add a web runtime to emulate them.

Only fixed event names, enum values and a resettable random ID may enter usage records. Never collect clipboard, calendar, media or screen content, file names, app inventory, raw error descriptions, user names, emails or OS device identifiers. Random IDs still link events. Explain that limit. IP and GeoIP suppression need project settings and transport verification, not only an event callback.

Analytics off constructs no client and sends nothing. Turning it off cancels sends and drops unsent data. No analytics code runs during drawing, hover, clipboard checks or icon-control transactions. Network requests, flag fetches and experiments must never delay startup or a user action. Use bounded memory and action-triggered batching, with no idle polling.

The official SDK audit found periodic queues and data added outside its event callback. Compare an audited narrow native API client with a patched SDK before choosing. No PostHog dependency or live project is configured yet. The first core module only encodes typed records. It does not send them and is not wired into the old app.

Zero cost is not a testable promise. Measure analytics on and off on the same signed app. Include total process footprint, CPU, wakeups, networking, startup and menu-bar latency. Set release limits before acceptance and reject a change that exceeds them. Test all outgoing requests with private-content canaries and test opt-out and ID reset during an in-flight send.

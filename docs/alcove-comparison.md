# Flux vs Alcove

Decision record and product roadmap, reviewed 2026-08-09.

## Scope and evidence

This is a product and interaction comparison, not a claim about Alcove's
private implementation. Flux was inspected on `origin/notch-m13`
(`c414d41`) and the public Alcove release notes, FAQ, issue tracker, and
settings reference were reviewed:

- [Alcove release notes](https://github.com/henrikruscon/alcove-releases)
- [Alcove FAQ](https://www.tryalcove.com/faqs)
- [Alcove settings reference](https://appstacks.club/alcove)
- [Alcove issue tracker](https://github.com/henrikruscon/alcove-releases/issues)

The useful comparison is at the level of user experience: what should appear,
when it should appear, how much it should move, and how much control the user
has. We should copy those principles only where they fit Flux's privacy,
performance, and documented-API goals.

## Shared philosophy, reduced to first principles

Both products are strongest when the notch is treated as a small, physical
surface rather than a normal application window:

1. **Glanceable:** the collapsed state communicates a small amount of current
   information without demanding a task switch.
2. **Progressive disclosure:** a wing/activity gives a little context; the
   expanded panel gives controls; a settings page holds configuration.
3. **Physical anchoring:** the panel should feel attached to the camera housing.
   Its footprint, corners, and motion must be predictable.
4. **Ambient by default:** motion and sound should be brief, quiet, and
   reversible. Persistent UI belongs in the expanded state.
5. **Capability honesty:** a control should only be shown when the underlying
   source can perform it. A dead button is worse than a missing feature.
6. **Native preference ergonomics:** navigation stays visible, pages keep a
   stable frame, and dense content scrolls inside the detail pane.
7. **Low cost and low trust:** idle work should be near-zero, permissions
   should be explicit, and private APIs should not be a dependency for Flux's
   core menu-bar product.

Alcove explicitly simulates its waveform to avoid the cost of real-time audio
   analysis, and its FAQ documents both private-API risk and a no-data-collection
   position. Those are good outcomes, but Flux should reach them with its own
   documented MediaRemote adapter and permission model rather than copying the
   private-API dependency. See the [FAQ](https://www.tryalcove.com/faqs).

## Capability comparison

| Area | Flux today | Alcove pattern observed in public releases | Decision for Flux |
| --- | --- | --- | --- |
| Core surface | Menu-bar manager plus notch panel; collapsed, activity, expanded, and experimental lock-screen states | Notch and notchless/simulated-notch pill; expanded media and live-activity surfaces | Keep Flux's menu-bar product distinct; adopt the same progressive-disclosure vocabulary |
| Panel sizing | M13 has one stable expanded footprint; widgets adapt inside it | Release notes repeatedly fix clipping, sizing, simulated-notch, and external-display cases | Keep one stable footprint; add geometry tests for every display and widget state |
| Motion | Spring open/close, blur/opacity morph, hover/click trigger, swipe cycling | Natural movement, progressive blur, tuned overshoot, haptics, hover duration, swipe actions | Adopt natural movement/haptics as opt-in polish after geometry is proven; respect Reduce Motion |
| Now Playing | Generic MediaRemote source, artwork, title/artist, simulated waveform, elapsed/remaining time, scrubber, previous/play-next/output control | Broader source/output handling, seeker, podcast/live-stream cases, audio-format awareness, AirPods/Max support, copy-link and other source actions | Add capability-based source/output actions and copy-link first; do not render unsupported controls |
| Calendar | EventKit agenda with Today/Tomorrow, color/location/time, permission state, Duo view, event alert activity | Onboarding, calendar selection/colors, display options, declined/split-day events, third-party calendar integrations, restore/dismiss behavior | Add a simple onboarding and display preferences; evaluate integrations only after EventKit behavior is solid |
| Live activities | Battery, Bluetooth, calendar-event, and timer wings; queue/cycle/dismiss/restore | Multiple activity handling, restore dismissed events, focus/HUD/lock-screen related surfaces | Keep Flux's smaller activity set; make queue priority, dismissal, and restore explicit and testable |
| Utility widgets | File Shelf, Mirror, Timers, Clipboard, plus lock-screen experimental content | Battery time-to-empty, connectivity, focus, display/audio/HUD behavior, lock-screen/screen-saver handling | Preserve Flux's differentiated widgets; selectively add battery/connectivity detail where it improves glanceability |
| Display behavior | Built around the built-in notch; fullscreen setting; no broad display-target UI yet | Preferred display, external displays, notchless pill, simulated notch, Mission Control/fullscreen fixes | High-value roadmap item: display target and notchless behavior; avoid global overlays by default |
| Settings | Now a fixed sidebar/detail surface with one 860×620 content canvas and scrolling detail pane | Native preferences-style sidebar, grouped pages, display and behavior sections, onboarding, license/about | Adopt the information architecture; keep Flux's smaller, capability-based page set |
| Privacy/platform | Documented `NSStatusItem` core, no Screen Recording/Accessibility for menu-bar MVP; Calendar/Camera are opt-in; clipboard is in-memory/opt-in | FAQ says no personal data collection, but also documents private API reliance and macOS breakage risk | Keep Flux's privacy and documented-API boundary; explain every permission and degrade locally |
| Performance | Event-driven menu bar and services; no real-time waveform analysis | Release notes emphasize low CPU/power and simulated waveform | Make idle work and panel presentation measurable; no polling or high-frequency visualizer loop |

## What we are implementing now

This pass deliberately fixes the foundations that make every feature easier to
use:

- **Settings:** replace the variable custom tab strip with a persistent
  sidebar, grouped sections, a detail header, a standard macOS titlebar, and a
  fixed content frame. Switching pages no longer resizes or moves the window;
  tall pages scroll in place.
- **Player:** reserve actual vertical budget for the transport row. Shared
  notch chrome now owns the bottom corner clearance, and the player uses a
  tighter internal stack so that clearance is not silently clipped.
- **Consistency:** centralize expanded-panel padding/radius/spacing tokens and
  remove stale documentation that described per-widget window sizes.
- **Verification:** use the real off-screen AppKit/SwiftUI renderer for all
  settings pages and notch states, plus the existing functional self-test.

## Prioritized roadmap

### P0 — reliability and ergonomics

1. Add a settings smoke test that asserts the window's content size and that a
   tab switch does not change it.
2. Add geometry assertions for Now Playing, Duo, calendar, timers, clipboard,
   and lock-screen snapshots: no transport/button or last-row clipping inside
   the visible shape.
3. Add a clear `Reduced Motion` path for panel springs, marquee movement, and
   artwork flips.
4. Add a display-target model: built-in display by default, explicit preferred
   display when multiple screens exist, and safe fallback when a display is
   disconnected.

### P1 — high-value Now Playing improvements

1. Add a source/output row that reports the active app and only exposes actions
   supported by the MediaRemote adapter.
2. Add copy-link when the source reports a URL; show a disabled explanation or
   omit the action when it does not.
3. Add shuffle/repeat/favorite only after the adapter exposes tested commands;
   never add decorative controls with no command path.
4. Improve artwork fallback, padding, and podcast/live-stream metadata without
   increasing the panel height.
5. Add an optional haptic-feedback setting for presentation and transport
   actions, with system capability checks.

### P2 — calendar and activity quality

1. Add first-use calendar onboarding and a compact calendar selection/display
   preference rather than making the agenda a fixed dump of every source.
2. Make activity priority, dismissal, cycling, and restore visible in tests and
   document the rule users should expect when several events arrive together.
3. Add configurable event details (location, declined events, all-day events)
   only where the information fits the glanceable surface.
4. Add a more informative battery activity, including time-to-empty only when
   the system reports a reliable estimate.

### P3 — optional surface expansion

1. Notchless-display pill and external-display support.
2. Settings import/export/reset and, only if there is a real multi-device need,
   settings sync.
3. More robust lock-screen/screen-saver behavior, treated as experimental and
   isolated from the core panel.
4. Audio/HUD/display integrations only when they can be permission-minimal and
   opt-in.

## Alcove quality-of-life backlog

These are useful ideas found in the public release history or settings/issues,
separated from the core plan so they can be consciously accepted or rejected.

| QoL idea | Value to Flux | Priority |
| --- | --- | --- |
| Stable sidebar preferences with grouped detail pages | Makes configuration discoverable and prevents window jumps | Done in this pass |
| Haptic feedback toggle | Gives confirmation to hover/swipe/transport actions without adding visual noise | P1 |
| Natural movement / tuned spring controls | Makes the panel feel physically attached to the notch | P1, after geometry tests |
| Hover, notification, and auto-dismiss duration controls | Prevents both accidental expansion and activity overstaying | P1 |
| Preferred display / external-display handling | Important for docks and multi-monitor users | P0/P1 |
| Notchless or simulated-notch pill | Extends the product to Macs and displays without a physical housing | P3 |
| Source chooser, output device, copy-link, podcast controls | Reduces the need to reopen the source app | P1, capability-gated |
| Shuffle/repeat/favorite/playback-speed controls | Useful media actions, but only with real adapter commands | P1/P2 |
| Calendar onboarding, calendar filters/colors, richer event options | Keeps the agenda useful instead of noisy | P2 |
| Restore dismissed event/activity | Prevents a glanceable notification from becoming irreversible | P0/P2 |
| Focus-mode and fullscreen/Mission-Control behavior | Avoids surprising overlays during focused work | P2 |
| Battery time-to-empty and connectivity details | Better glance value than a bare percentage | P2 |
| Settings sync, import/export, and reset | Makes experimentation recoverable | P3 |
| Accessibility onboarding and explicit permission explanations | Lowers the cost of first use and failure recovery | P1 |
| Release/update state that is clear and recoverable | Avoids stale “up to date” or half-installed states | P1 |

## Deliberately not copying

- **Private APIs as a foundation:** Alcove documents that this can break with
  macOS. Flux should keep private or experimental surfaces isolated and never
  let them compromise the menu-bar manager.
- **A full operating-system control center:** every new live activity must earn
  its space, have a clear trigger, and remain dismissible.
- **Real-time waveform analysis:** the simulated waveform is cheaper and more
  stable; Flux should keep its deterministic visualizer.
- **Controls without capability evidence:** no favorite, shuffle, speed, or
  output button until the adapter can execute and test it.
- **Global overlays by default:** fullscreen, HUD, lock-screen, and external
  display behavior must be opt-in and scoped to the surface the user enabled.

## Acceptance bar for future work

Every new panel or settings feature should answer four questions before it is
considered complete:

1. What is the collapsed/glanceable state?
2. What is the expanded action and its dismissal path?
3. What happens when the capability, permission, display, or source is absent?
4. What snapshot, self-test, or live-route evidence proves it does not resize,
   clip, poll, or silently fail?


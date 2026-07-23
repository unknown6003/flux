<div align="center">

# Flux

**A calmer menu bar.** A fast, stable, near-zero-resource menu bar manager for macOS — a Bartender alternative built for performance and stability first.

</div>

| Light | Dark |
| --- | --- |
| ![Flux settings, light](docs/screenshots/settings-light.png) | ![Flux settings, dark](docs/screenshots/settings-dark.png) |

---

## Why Flux

Most menu-bar managers feel buggy because they continuously **capture and redraw the
menu bar** with ScreenCaptureKit. That approach burns CPU/GPU, needs Screen Recording
permission, and breaks on every macOS update.

Flux takes the opposite approach. It plants its own invisible, expandable status
items as **section dividers** and collapses them to push other apps' icons off the
visible bar. The result:

- **~0% CPU at idle** — it only reacts to clicks, nothing polls or redraws.
- **No special permissions** — no Screen Recording, no Accessibility for the core MVP.
- **Stable across releases** — relies on documented `NSStatusItem` behaviour, not
  private or capture APIs. Targets **Sonoma (14), Sequoia (15), Tahoe (26)** and is
  forward-compatible with the upcoming **Golden Gate (27)**.

## The three zones (just like Bartender)

```
[ Always-Hidden ]  ‹‹  [ Hidden ]  ‹  ⌄  [ Shown ]  🕓
                    │              │    │
            always-hidden       hidden  Flux chevron
              divider           divider
```

| Zone | Behaviour |
| --- | --- |
| **Shown** | Always visible. Anything to the **right of the chevron** — it never hides. |
| **Hidden** | Revealed when you click the Flux chevron (the "drawer"). |
| **Always-Hidden** | Revealed only with **⌥ (option)** — kept fully out of the way. |

**Nothing is hidden until you say so.** On a fresh install Flux seeds its chevron and
dividers to the *left* of every icon you already have, so all of them start in **Shown**
and the bar looks exactly as it did before. You then drag icons *leftward*, past the
chevron, to tuck them away.

You assign an icon to a zone by **⌘-dragging** it to one side of a Flux divider — the
native macOS gesture. To make the (normally invisible) zone boundaries visible while
you do this, open **Arrange Menu Bar** — from Settings or the chevron's right-click
menu. Flux reveals every icon and drops a labeled marker at each boundary, so you can
see exactly where to drop each icon:

- Left of the **Hidden** marker → Hidden
- Left of the **Always Hidden** marker → Always-Hidden
- Right of the **Hidden** marker → Shown

Click **Done** (or the ✓ that replaces the chevron) to apply. Flux remembers the
arrangement across launches.

## Features (MVP)

- Click the chevron (or press the global hotkey, **⌃⌥⌘F** by default and fully
  rebindable in Settings) to reveal. Clicking a revealed icon **keeps it open** so you
  can use it; clicking down in a window re-hides.
- **Arrange Mode** — a guided editor that reveals labeled zone markers in the live
  menu bar so assigning icons to Shown / Hidden / Always-Hidden is clear and visible.
- Optional **Always-Hidden** zone.
- **Notch panel — Alcove-inspired compact redesign (M7)** — a pure-black,
  seamless panel sized to each widget's own content (no more one-size-fits-all
  box), with overshoot springs on open and a snappy, no-bounce close, plus a
  blur/opacity content morph as it expands. Hover (or click) the camera
  housing to expand a **Now Playing** widget: artwork, title/artist, a
  scrubber, and transport controls for whatever's playing (any app, via a
  vendored MediaRemote adapter; falls back to AppleScript for Music/Spotify —
  macOS may show an Automation permission prompt the first time that fallback
  controls either app). Open gesture, hover delays, and which widgets are
  enabled are all configurable in Settings → Notch.
- **Duo view (M7)** — an opt-in toggle in Settings → Notch shows Now Playing
  and Calendar side by side when Now Playing is expanded (needs Calendar
  enabled and its permission granted too); expanding Calendar on its own still
  shows it alone.
- **Activity cycling & restore (M7)** — while a live-activity wing is
  showing, swipe left/right to cycle through every other queued activity,
  swipe up to dismiss the one showing (restorable — the last 5 dismissed
  activities can be brought back), and swipe down to open the widget panel.
- **Focus activity (M7, best-effort)** — a brief wing peeks the active Focus's
  name/icon whenever it changes, with an optional persistent icon-only
  indicator while one stays on. This rides on undocumented on-disk state (no
  public Focus API exists) and silently does nothing if it can't read it —
  see Settings → Notch → Live Activities.
- **File Shelf** — drag files straight onto the notch to hold them: hovering a
  drag over the (collapsed) camera housing expands the shelf automatically,
  and dropping copies the files in (they survive the source being moved,
  ejected, or deleted). From the shelf: click a tile to open it, drag it back
  out to Finder/Mail/Slack/etc., or use the tile's context menu for AirDrop,
  "Show in Finder", or "Copy". An optional auto-clear (never / 1 / 3 / 7 days)
  in Settings → Notch tidies the shelf on its own.
- **Calendar** — your upcoming events (Today/Tomorrow), with a colored dot
  per calendar, time range, and location, right in the notch. Needs Calendar
  access; Settings → Notch shows the live grant/denied status and a button
  to request access or jump straight to System Settings if it's off. A wing
  appears automatically when an event is starting within 10 minutes — no
  repeating timer, just a single scheduled check for the next event's own
  threshold.
- **Live Activities** — brief wings around the notch for battery, Bluetooth,
  and calendar events: a wing when you plug in, unplug, or cross below 20%
  battery unplugged (tinted to read as urgent, re-arming once you're back
  above 25% or plugged in), a wing when AirPods or another Bluetooth
  audio/HID accessory connects or disconnects, with a best-effort battery
  reading when the OS reports one, and a wing when a calendar event is about
  to start. Each is independently toggled in Settings → Notch.
- **Volume & brightness HUD** — flashes a wing in the notch when either
  changes. Works permission-free out of the box (**observe mode**: CoreAudio
  reports volume/mute changes, alongside whatever bezel macOS still shows).
  Opt in to **intercept mode** in Settings → Notch to take the system's
  volume/brightness keys over entirely, so only the notch HUD ever appears —
  this needs Accessibility, since swallowing a key system-wide requires it.
  Brightness is intercept-mode only: macOS has no change notification for
  display brightness to observe, so there's nothing to show without the
  keys themselves being captured.
- **Mirror** — a live camera preview right in the notch, for a quick
  "how do I look" check. The camera only ever runs while the widget is
  actually open; needs Camera access, with the same live grant/denied status
  and re-request button as every other permission-gated feature.
- **Timers** — quick-start (1/5/10/25 min) or custom countdown timers in the
  notch, with pause/resume/cancel. A wing (with a sound) announces a finished
  timer; an ambient countdown wing shows the nearest remaining time while
  one's running, or a paused indicator when every timer is paused. Both wings
  share the single **Timer alerts** toggle in Settings → Notch.
- **Clipboard** — an in-memory-only history of what you copy, with
  click-to-copy-back, per-item removal, and Clear All. Off by default —
  history collection is opt-in, since clipboard contents routinely include
  passwords and other sensitive one-time text; nothing is ever written to
  disk, and password-manager-marked copies (the `nspasteboard.org`
  concealed/transient convention) are never captured at all.
- **Lock screen (experimental)** — optionally keeps a minimal, non-interactive
  notch silhouette visible on the macOS lock screen, with up to three
  stacked, fading pills beneath it: a live Now Playing media pill (artwork +
  title/artist), the notch's current live activity as a caption pill
  (battery, Bluetooth, calendar, timer, ...), and an optional black
  "Press any key to unlock" pill with a padlock glyph — plus an optional
  sound the moment you unlock. Each of the three sub-features has its own
  toggle, all nested under the master switch. Off by default: it rides on
  undocumented macOS lock-screen notifications and window-level behavior, so
  it may stop working or misbehave after any macOS update — see Settings →
  Notch → Experimental.
- **Auto re-hide** after an adjustable delay.
- **Launch at login** (via `SMAppService` — the modern, sanctioned API).
- Three menu-bar icon styles: Chevron / Dot / Line.
- Light & dark, adapts to your system accent color.
- Runs as a true agent: no Dock icon, no app switcher entry.

## Privacy — zero permissions by default

Flux's core (menu-bar hiding, the notch panel, widget cycling) runs with
**no TCC access of any kind** — nothing prompts on a fresh install, and
nothing runs that could prompt later without you turning it on first:

- **Calendar, Camera, and the HUD's Accessibility intercept** are each
  behind their own explicit **Grant Access** button in Settings → Notch —
  the permission-gated widget/feature shows its own "access needed" state
  until you ask for it.
- **Bluetooth device wings need no permission at all.** Flux detects
  accessory connect/disconnect through the system's own device registry (the
  IOKit `AppleDeviceManagementHIDEventService` that already reports accessory
  battery, permission-free) plus CoreAudio's device list — it never requests
  Bluetooth access, so nothing prompts, and the wings are on by default like
  the rest of the notch suite.
- **Focus wings are OFF by default.** This reads a system Focus-status file
  that macOS may protect depending on your setup; it's opt-in, and silently
  shows nothing if macOS won't let it read the file at all.
- **The AppleScript Now Playing fallback is OFF by default.** The
  MediaRemote adapter is the only thing driving Now Playing until you
  explicitly enable the fallback in Settings → Notch — only then does Flux
  ever script Music or Spotify, which is what prompts macOS's Automation
  permission the first time each app is scripted.
- **Clipboard history is opt-in and in-memory only** — nothing is captured
  until you turn it on, and nothing it captures is ever written to disk.

Every grant above is revocable at any time in System Settings, and every
gated feature degrades gracefully (its own empty/permission state) rather
than breaking the rest of the app when access isn't there.

## Install

Grab the latest **`Flux.dmg`** from the [Releases](../../releases) page, open it, and
drag **Flux** into **Applications**. On first launch, right-click the app → **Open**
(it's ad-hoc signed, not notarized). A **‹** chevron appears near your clock.

**A note on permissions:** Flux is ad-hoc signed rather than notarized with a paid
Developer ID, which means macOS can — and sometimes does — treat an update as a new,
untrusted binary and quietly drop a previously granted TCC permission (Calendar,
Accessibility, and Camera). If a permission-gated widget suddenly shows its
"access needed" state after updating Flux, that's why — Settings → Notch shows the
live grant/denied status for each permission and a button to re-request it or jump
straight to the right System Settings pane.

## Build & run

Requires Xcode 15+ (built and tested on Xcode 26 / Swift 6.3, macOS 26).

```bash
# Build the signed .app bundle → build/Flux.app
./Scripts/build_app.sh release

# Package a distributable disk image → build/Flux.dmg
./Scripts/build_dmg.sh

# Launch it
open build/Flux.app
```

Or for quick iteration:

```bash
swift build && swift run
```

### Developer / CI helpers

The executable understands a few headless flags used for testing:

```bash
Flux --selftest                     # functional test of the collapse engine
Flux --snapshot out.png [light|dark] # render the real settings UI to a PNG
Flux --snapshot-notch out.png [dark] [collapsed|activity|expanded|lockscreen] # render the notch panel to a PNG
```

## Architecture

```
Sources/Flux/
  main.swift                 # agent entry point (.accessory activation)
  App/AppDelegate.swift      # wires settings ↔ engine ↔ login ↔ hotkey
  MenuBar/
    MenuBarManager.swift     # reveal/collapse state machine, auto-rehide, menu, arrange
    ControlItem.swift        # one NSStatusItem as chevron or expandable divider
    MenuBarArranger.swift    # observable toggle for Arrange Mode (Settings ↔ engine)
    MenuBarSection.swift     # the three-zone model
    MenuBarIconStyle.swift   # chevron / dot / line
  Settings/
    SettingsStore.swift      # UserDefaults-backed, observable
    SettingsView.swift       # tab host (General / Menu Bar / Notch / About)
    SettingsRows.swift       # shared row primitives
    Tabs/                    # one file per settings tab
    SettingsWindowController.swift
  Notch/
    NotchWindowController.swift # owns the notch panel's lifecycle
    NotchViewModel.swift     # collapsed/activity/expanded state machine
    NotchWidget.swift        # widget protocol + registry
    LiveActivity.swift       # priority-queued "wings" content
    LiveActivitySources.swift  # NotchActivityRouter — single home for every activity producer
    Widgets/NowPlayingWidget.swift
    Widgets/ShelfWidget.swift  # tiles, drag in/out, AirDrop/Finder/Copy
    Widgets/CalendarWidget.swift # agenda, permission states
    Widgets/MirrorWidget.swift # live camera preview; owns CameraService start/stop itself
    Widgets/TimersWidget.swift # presets/custom countdowns, pause/resume/cancel
    Widgets/ClipboardWidget.swift # history list, click-to-copy-back, Clear All
    LockScreenPresenter.swift  # EXPERIMENTAL: fade in/out, lock/unlock, unlock sound
    LockScreenContentView.swift # EXPERIMENTAL: live media/activity/unlock pills on the lock screen
  Services/NowPlaying/       # MediaRemote adapter + AppleScript fallback, failover facade
  Services/Shelf/            # ShelfStore (copy-in, manifest, QuickLook thumbs, expiry)
  Services/CalendarService.swift # EventKit, refresh on EKEventStoreChanged (no polling)
  Services/PowerMonitor.swift    # IOKit battery/AC events (plug/unplug, low battery)
  Services/DeviceMonitor.swift     # permission-free BT connect/disconnect: IOKit matching notifications + CoreAudio device list + IORegistry battery
  Services/FocusMonitor.swift      # M7: best-effort Focus status from undocumented on-disk state, no polling
  Services/CameraService.swift    # AVCaptureSession behind Mirror, started/stopped by the widget itself
  Services/ClipboardMonitor.swift # NSPasteboard.changeCount poll, settings-driven start/stop
  Services/TimerService.swift     # countdown timers, single boundary Task, completions publisher
  Services/HUD/VolumeMonitor.swift        # CoreAudio volume/mute listener + setter (observe + intercept)
  Services/HUD/BrightnessMonitor.swift    # dlopen'd DisplayServices brightness get/set (intercept-only)
  Services/HUD/MediaKeyInterceptor.swift  # CGEventTap swallowing volume/brightness keys (Accessibility)
  Login/LoginItemManager.swift   # SMAppService launch-at-login
  Hotkey/HotkeyManager.swift     # Carbon global hotkeys (menu-bar toggle + notch toggle)
  Hotkey/HotkeyShortcut.swift    # the chord model + ⌃⌥⌘F / ⌃⌥⌘N defaults
  Hotkey/HotkeyRecorderView.swift # click-to-record shortcut field
  Support/PermissionCenter.swift  # unified TCC status/request for Calendar/Camera/Accessibility
  Support/                       # logging, app info, render/snapshot/selftest
```

## Roadmap (post-MVP)

- **Per-app list control** and a searchable **drawer** popover (needs Accessibility +
  ScreenCaptureKit — deliberately deferred to keep the MVP resource-light).
- Custom hotkey recording, profiles, triggers (show on update/active).
- Graduating the lock-screen silhouette out of "experimental," if it proves
  durable across macOS updates.

## License

[MIT](LICENSE) © 2026 Ammar Badawy.

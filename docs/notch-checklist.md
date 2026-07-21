# Notch Suite Manual QA Checklist

`Flux --selftest` covers the state machine, stores, and other pure logic
headlessly — no window server, no real drag session, no physical notch.
Everything below needs a real notched Mac, a real trackpad/mouse, and a
human: run through it before shipping a notch-suite change that touches
drag-and-drop, hover, or click/mouse pass-through.

## M2 — File Shelf drag & drop

- [ ] **Collapsed-drop auto-expand**: drag a file over the collapsed notch
      (don't hover/click to open it first) and confirm it auto-expands to
      the File Shelf widget, and the drop actually lands — the item appears
      on the shelf once released.
- [ ] **Drop feedback toast**: after a successful drop, confirm the brief
      "Added N" live-activity toast appears — including when the shelf
      collapses again immediately afterward (cursor moves off right after
      the drop, so the auto-expanded panel closes on its own).
- [ ] **Shelf-disabled drag shows no + cursor**: disable the File Shelf
      widget in Settings, then drag a file over the collapsed notch.
      Confirm the cursor shows the "no drop" (circle-slash) indicator, not
      the green "+" — the notch must neither auto-expand nor accept the
      drop while the widget is off.
- [ ] **Drag-out to Finder**: drag a tile off the open shelf onto the Finder
      desktop (or another app) and confirm the file actually copies/moves,
      matching an ordinary Finder drag.
- [ ] **AirDrop**: from a shelf tile's context menu, choose AirDrop and send
      to a nearby device; confirm the transfer actually completes.
- [ ] **Drop-onto-windows-beneath-the-strip regression check**: position
      another app's window so part of it sits directly under the notch
      panel's full (expanded-size) transparent strip — not under the tiny
      physical notch itself. With the notch collapsed (so it isn't
      auto-expanding for this test), try dropping a file directly onto that
      sliver of the other app's window. Confirm the drop reaches the app
      underneath instead of being silently swallowed by the notch panel's
      own declined `NSDraggingDestination`. This is the open hardware
      question flagged in `NotchPanel`'s drag-and-drop doc comment — if this
      regresses, the accept region (`interactiveRect` +
      `NotchWindowController.dragSlop`) needs to shrink further.

## M5 — Volume/brightness HUD

- [ ] **Observe mode, no permission granted**: with Accessibility NOT
      granted, press a volume key. Confirm the notch shows a `.hudVolume`
      wing AND the system's own volume bezel still appears (observe mode
      never suppresses it — see `VolumeMonitor`'s doc comment). Repeat for
      mute.
- [ ] **Intercept mode swallows the system bezel**: grant Accessibility,
      turn on "Replace the system overlay" in Settings → Notch, then press
      volume/mute/brightness keys. Confirm ONLY the notch HUD appears —
      no system bezel at all — and that the actual volume/mute/brightness
      state genuinely changes (not just the wing's displayed number).
- [ ] **Held-key repeat**: hold a volume or brightness key down in intercept
      mode and confirm the notch HUD updates continuously/smoothly as the
      level ramps, matching the system bezel's own held-key cadence.
- [ ] **Shift+Option fine step**: in intercept mode, hold Shift+Option while
      pressing a volume or brightness key and confirm the level moves in
      much smaller increments than a plain key press.
- [ ] **No double-post**: in intercept mode, press a volume key once and
      confirm exactly ONE `.hudVolume` wing appears — not two overlapping/
      back-to-back posts (the CoreAudio listener firing for the same
      programmatic change this app just made is the dedupe this checks —
      see `NotchActivityRouter.isVolumeMonitorEventSuppressed`).
- [ ] **Control Center slider still works in intercept mode**: with intercept
      mode on, drag the volume slider in Control Center (not a keyboard key)
      and confirm the notch HUD still reflects it — this path is NOT
      swallowed by the event tap (only hardware keys are), so it must still
      flow through observe mode's CoreAudio listener.
- [ ] **Accessibility revoked mid-session**: with intercept mode on, revoke
      Accessibility for Flux in System Settings, then press a volume key.
      Confirm Flux falls back to observe mode (system bezel returns) rather
      than silently doing nothing, and that the Settings toggle's row
      reflects the revoked permission.
- [ ] **Non-notched external display + brightness**: on a setup with only an
      external monitor active (built-in lid closed or no notch), confirm
      brightness intercept simply does nothing harmful (no crash, no
      dangling tap) — there is no built-in notched screen for
      `BrightnessMonitor` to target.
- [ ] **A device with no settable volume**: switch the default output device
      to one that exposes no software volume control (some digital/HDMI
      outputs) and confirm Flux doesn't misbehave — no wing showing a
      nonsensical level, no crash from `VolumeMonitor`'s per-channel
      fallback path.

## M6 — Mirror, Clipboard, Timers, Lock Screen

- [ ] **Mirror start/stop + permission**: with Camera access NOT yet granted,
      open the Mirror widget and confirm the permission explainer shows (no
      camera indicator light, no preview). Grant access from that same panel
      (or while it's open, from System Settings) and confirm the preview
      starts within the same presentation — no need to close and reopen. Then
      collapse the notch (or swipe to another widget) and confirm the camera
      indicator light turns off immediately.
- [ ] **Camera session torn down on collapse**: with Mirror open and the
      preview running, collapse the notch several different ways (mouse-out,
      click, swipe up, disabling the notch panel in Settings) and confirm the
      camera indicator light goes off every single time — never left lit
      after the panel is no longer visible.
- [ ] **Clipboard capture**: turn on the Clipboard toggle in Settings → Notch,
      copy a few different things (plain text, a URL, a file in Finder, an
      image), open the Clipboard widget, and confirm each shows up with the
      right icon/preview, newest first.
- [ ] **Clipboard concealed/transient skip**: copy a password out of a real
      password manager (1Password, Bitwarden, or Safari's own password
      autofill) and confirm it does NOT appear in the clipboard history at
      all — not even as a redacted entry.
- [ ] **Clipboard copy-back**: click a history entry and confirm it's written
      back to the pasteboard (paste it somewhere to verify) with a brief
      checkmark confirmation, and that the very next poll tick does NOT
      re-capture it as a duplicate new entry.
- [ ] **Clipboard collection follows both toggles**: turn the Clipboard
      setting off and confirm no new copies are captured even with the
      widget itself still enabled in the cycle order; also confirm disabling
      the notch panel entirely (master switch) stops capture even with the
      Clipboard toggle left on.
- [ ] **Timer run/pause/complete + activity**: start a short (under a
      minute) custom timer, confirm the ambient countdown wing appears with
      the remaining time, pause it from the expanded widget and confirm the
      wing's countdown freezes, resume it, then let it run out and confirm a
      "<label> done" wing appears along with a sound, replacing the ambient
      wing, and that the ambient wing reappears afterward if another timer is
      still running.
- [ ] **Timer alerts toggle**: turn off "Timer alerts" in Settings → Notch,
      start a timer, and confirm neither the ambient countdown wing nor the
      completion wing/sound appears — the Timers widget itself still works
      for starting/pausing/cancelling.
- [ ] **Lock-screen show/hide**: turn on "Show on the lock screen" in
      Settings → Notch → Experimental, lock the screen, and confirm a small
      notch silhouette appears (captioned with a running timer's remaining
      time, if one is running) without interfering with actually typing your
      password to unlock. Unlock and confirm the silhouette disappears.
      Turning the toggle off (or disabling the notch panel entirely) while
      locked should also make it disappear.

## M7 — Shell redesign (Alcove scale/feel)

The CI "Render notch snapshots" step gives the orchestrator/PR-bot a static
look at collapsed/activity/expanded-nowPlaying, but a still PNG can't show
motion, real-Mac shadow rendering, or per-widget height differences across
every widget — the items below need a real notched Mac.

- [ ] **Overshoot feel on open**: hover (or click, per your trigger setting)
      to open the notch from collapsed and confirm the panel visibly bounces
      slightly past its final size before settling — the Alcove-style
      overshoot spring (`NotchRootView.expandSpring`), not a plain ease-in.
      Repeat swiping between widgets (a `.expanded` → `.expanded` move) —
      that should overshoot too, since it's a "growing" direction from the
      spring's perspective.
- [ ] **Snappy, no-overshoot close**: collapse the notch (hover-out, click,
      swipe up) from every state (activity and each widget) and confirm it
      settles quickly with no bounce — visibly a different, crisper feel than
      the open animation, not just a faster version of the same curve.
- [ ] **Seams invisible while idle/collapsed**: with the notch collapsed and
      the cursor away from it, look closely at the edges against the physical
      camera housing in both light and dark desktop wallpaper. Confirm there
      is no visible shadow, halo, or seam — collapsed must look like the bare
      hardware notch, not a panel sitting on top of it.
- [ ] **Shadow only while open**: open the notch (activity or any widget) and
      confirm a soft, dark drop shadow appears under the panel; collapse it
      and confirm the shadow disappears immediately (not lingering, not
      fading oddly) as the shape shrinks back to the collapsed hug.
- [ ] **Per-widget expanded height**: open each widget in turn (Now Playing,
      Shelf, Calendar, Mirror, Timers, Clipboard) and confirm the panel's
      height visibly differs to match each widget's content — Shelf and Now
      Playing noticeably shorter than Calendar/Clipboard — rather than every
      widget reserving the same tall, mostly-empty box.
- [ ] **Content blur-morph**: watch the widget content itself (not just the
      black shape) as you open/close — confirm it fades and sharpens in
      (blurred → crisp, transparent → opaque) rather than popping in/out
      instantly, and that rapidly swiping through several widgets in a row
      never leaves content stuck half-blurred.
- [ ] **Monochrome wings**: trigger a non-warning live activity (e.g. a file
      shelf drop or Now Playing) and confirm the wing icons/text/gauge render
      in white/white-opacity tones with no amber anywhere; trigger a warning
      activity (e.g. low battery, if wired up) and confirm only that one
      still shows the warning color.
- [ ] **Subtler hover breathing cue**: in click-trigger mode, hover the
      collapsed notch without clicking and confirm the breathing scale cue is
      present but subtle (a small pulse, not an obvious "wiggle").

## M7 — Alcove parity: activity cycling, Duo view, Focus

- [ ] **Cycle through queued activities**: get two or more sticky live
      activities queued at once (e.g. a low-battery warning and an upcoming
      calendar event) and, while a wing is showing, swipe left/right and
      confirm it rotates to the other queued activity rather than only ever
      showing the highest-priority one.
- [ ] **Dismiss + restore**: with an activity wing showing, swipe up and
      confirm it's dismissed (collapses, or shows the next-highest queued
      one). Trigger the restore path (however it's wired up — hotkey/menu)
      and confirm the just-dismissed activity comes back.
- [ ] **Swipe down expands from an activity**: with a wing showing, swipe
      down and confirm it expands to the widget panel (last-used/first
      enabled widget), same as swiping down from fully collapsed.
- [ ] **Expanded widget cycling unchanged**: confirm left/right while a
      widget panel is open still cycles WIDGETS (not activities) exactly as
      before M7, and up still collapses.
- [ ] **Duo view renders side by side**: turn on "Duo view" in Settings →
      Notch, with Calendar enabled and its permission granted, then expand
      Now Playing. Confirm the panel widens and shows Now Playing on the
      left and a Calendar agenda pane on the right, split by a thin divider.
- [ ] **Duo view falls back gracefully**: with Duo view on but Calendar
      disabled (or its permission not granted), expand Now Playing and
      confirm it renders alone, at the normal (non-widened) size — no dead
      blank space, no crash.
- [ ] **Calendar solo is untouched**: with Duo view on, expand Calendar
      directly (not via Now Playing) and confirm it still renders as its own
      normal solo panel, not squeezed into the Duo layout.
- [ ] **Focus peek**: turn on "Focus" in Settings → Notch → Live Activities,
      change your Focus (or turn one on/off from Control Center) and confirm
      a brief wing shows the Focus's name/icon (or "Focus off"). If nothing
      appears at all, check Settings for whether Focus reads as available —
      this is best-effort and may not work on every macOS version/security
      posture (see `FocusMonitor`'s own doc comment).
- [ ] **Focus sticky indicator**: with "Keep a persistent indicator" also
      on, confirm a small icon-only wing stays up for as long as a Focus
      stays active (after the initial peek fades), and disappears the moment
      the Focus turns off.
- [ ] **Option-click restores the last-dismissed activity**: swipe up on a
      showing live-activity wing to dismiss it (or otherwise let one get
      dismissed), then option-click the notch — in ANY state (collapsed,
      another activity showing, or a widget panel expanded) — and confirm the
      just-dismissed activity comes back as current (`LiveActivityCenter.
      restoreLastDismissed()`, wired to `NotchViewModel.clicked(optionDown:)`).
      Confirm a *plain* click (no option key) right after still does the
      ordinary open/close toggle, unaffected.

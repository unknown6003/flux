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

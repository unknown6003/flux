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

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

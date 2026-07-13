# Flux — Handoff & Testing Guide

This is the honest status of the MVP: what I verified automatically, and the short
hands-on pass only you can do (because the core behaviour depends on macOS
permissions that **only a human can grant** — apps cannot grant them to themselves).

---

## ✅ What I verified automatically

| Check | How | Result |
| --- | --- | --- |
| Compiles cleanly (release) | `swift build -c release` | ✅ no errors |
| Builds a signed `.app` | `Scripts/build_app.sh` | ✅ `codesign --verify` passes |
| Launches as a true agent | `open build/Flux.app` + `pgrep` | ✅ running, **no Dock icon** (`background only = true`) |
| Status items created on launch | os_log `com.flux.menubar` | ✅ "MenuBarManager initialised" + hotkey registered each launch |
| **Full state machine** | `Flux --selftest` (39 checks) | ✅ **default-layout seeding** → launch-collapsed → reveal-Hidden → reveal-all → collapse → **Arrange Mode enter/exit** → section-toggle → **OTA version compare**, all asserting real state |
| Idle resource use | `ps` cputime over 3s | ✅ **~0% CPU** (cputime unchanged), ~31 MB, 3 threads |
| Settings UI (real controls) | `Flux --snapshot` → PNG | ✅ see `docs/screenshots/` |

> **Why the chevron was invisible (root-caused & fixed):** a status item's saved
> "Preferred Position" is a distance-from-the-right-edge in points. When macOS persists
> that value while a divider is at its 10 000pt collapsed width, the divider *and its
> neighbours (the chevron)* inherit an absurd position. On the next launch the chevron
> was restored at ~10 462pt-from-the-right → **x ≈ −8677, thousands of points off the
> left of the screen** (confirmed via the Accessibility API). Fix:
> `ControlItem.sanitizePersistedPositions()` runs before the items are created and
> drops any position beyond a plausible ceiling. `assignDefaultPositionsIfUnset()`
> then seeds a clean layout so the chevron lands **rightmost — right next to the
> clock** (x ≈ 1531, verified via the Accessibility API), with the dividers stacked to
> its left where they actually capture the user's icons. Clicking the chevron was
> verified live to collapse the hidden divider 5002 → 3pt (icons return) while the
> always-hidden zone stays hidden.

> **Why the chevron revealed *nothing* (v0.1.2 fix):** the seeded layout put **both**
> dividers near the clock (Hidden at 8, Always-Hidden at 16 points-from-the-right). But
> every real menu-bar icon sits much further left, so all of them fell *left* of the
> Always-Hidden divider — trapping the whole bar in **Always-Hidden** and leaving the
> **Hidden** zone empty. A plain chevron click (which only reveals Hidden) therefore
> showed nothing, and Hidden behaved identically to Always-Hidden. Fix: the
> Always-Hidden divider now seeds to the **far left** (the widest screen's width in
> points, past every icon) so its zone starts **empty** and the user's icons default
> into the chevron-toggled **Hidden** zone — right → left the bar now reads
> `[clock] [chevron] Shown · ◀Hidden · Hidden · ◀Always-Hidden · (empty)`. A one-time
> `layoutVersion` migration clears the old saved positions on upgrade so existing
> installs pick up the corrected seed once (a manual arrangement made afterwards
> persists normally).

Re-run the functional test yourself anytime:

```bash
swift run Flux --selftest
```

## 🖐️ What needs your 2-minute hands-on pass

I **could not screenshot the live menu bar** during the build because your foreground
app was in **fullscreen**, which hides the macOS menu bar (and every status item)
entirely. That's a screenshot limitation on my side — not a Flux issue. The hide/reveal
logic itself is proven by `--selftest`. Please confirm it visually:

### 1. Launch
```bash
open build/Flux.app
```
A small **‹** chevron appears near your clock. (If a fullscreen app is covering the
menu bar, move the mouse to the top edge to reveal it, or leave fullscreen.)

### 2. Hide / reveal
- **⌘-drag** a couple of menu bar icons to the **left** of Flux's chevron.
- They vanish (collapsed into the Hidden zone).
- **Click the chevron** (or press the hotkey — **⌃⌥⌘F** by default, rebindable in
  Settings → Behavior → Shortcut) → they reappear.
- **Click one of the revealed icons** → it stays open so you can use it (it no longer
  re-hides out from under your click — *fixed*). Click down in a window → they re-hide.
  Or just wait ~8s.
- **Right-click the chevron** → menu (Reveal/Hide, **Arrange Menu Bar Items…**, Settings, Quit).

### 2b. Arrange Mode (assign zones visibly)
- Right-click the chevron → **Arrange Menu Bar Items…** (or open Settings → **Menu Bar
  Layout** → **Arrange Menu Bar…**).
- Every icon reappears and each divider shows a **solid coloured marker naming the zone
  to its left** — burnt-orange **◀ Hidden**, deep-rust **◀ Always Hidden** — so the
  right-to-left order reads straight off the bar: `[✓] Shown  ◀Hidden  ◀Always Hidden`.
  The left arrow points the way to drag an icon in. The chevron becomes a **✓**.
- A **floating hint banner** drops under the bar with a **prominent ⌘ callout** (*Hold
  ⌘ Command while you drag*) plus a right→left zone legend whose chips mirror the live
  markers. It carries its own **Done** button. Settings shows the identical panel.
- **⌘-drag** icons across the markers: left of *◀ Hidden* → Hidden, left of *◀ Always
  Hidden* → Always-Hidden, everything right of *◀ Hidden* (nearest the clock) → Shown.
- Click the **✓**, the banner's **Done**, or **Done** in Settings → markers and banner
  vanish and the new arrangement applies. It persists across launches.

### 3. Settings
- Right-click the chevron → **Flux Settings…**.
- Toggle options; they persist immediately.

### 3b. Software Update (OTA)
- Settings → **Software Update** → **Check for Updates**. Flux polls its GitHub
  Releases (`unknown6003/flux`), compares the tag against the running build, and — if
  newer — shows an amber banner with **Download & Install** (downloads the DMG to
  ~/Downloads and opens it) plus **View release on GitHub**.
- **Automatically check for updates** (on by default) does a quiet check ~4s after
  launch and every 6 h; it never installs anything without a click. Zero permissions —
  a plain HTTPS GET, no Sparkle, no privileged helper, no auto-replace.
- Running 0.1.2 against the 0.1.2 release correctly reports **up to date**.

### 4. Launch at login (needs your approval)
- Turn on **Launch at login** in Settings.
- macOS may show it in **System Settings › General › Login Items** — confirm it there.
- `SMAppService` registration only sticks for the signed bundle (`build/Flux.app`),
  not the bare `swift run` binary.

---

## Permissions summary

| Feature | Permission | Who grants it |
| --- | --- | --- |
| Hide/reveal (core MVP) | **none** | — |
| Global hotkey (⌃⌥⌘F, rebindable) | none (Carbon) | — |
| Launch at login | Login Items | you, on first toggle |
| *(future)* per-app drawer / search | Accessibility + Screen Recording | you, post-MVP |

The MVP deliberately needs **zero** privacy permissions for its core job — that's the
whole point of the divider approach and the source of its stability and low cost.

---

## Known MVP boundaries (by design)

- **Zone assignment is by ⌘-drag**, made visible and guided by **Arrange Mode** (see
  §2b) rather than a per-app checklist. Arbitrary per-app selection *without dragging*
  would require repositioning *other* apps' items, which needs Accessibility +
  ScreenCaptureKit — that's the post-MVP "drawer" milestone. The three contiguous
  zones already match Bartender's core Show / Hide / Always-Hide model.
- **No separate floating drawer popover yet** — reveal happens inline in the bar
  (lighter and more reliable). The floating/notch drawer is roadmapped.
- Flux's chevron sits at the **left end of your icon run**, not against the clock —
  that's what makes a **Shown** zone possible: everything to the *right* of the chevron
  is Shown and never hides. The v3 layout seeds it (and both dividers) left of every
  existing icon, so a fresh install hides nothing until you drag something leftward.

## If something's off

```bash
# See Flux's own logs
log show --last 5m --info --predicate 'subsystem == "com.flux.menubar"'

# Rebuild from clean
rm -rf .build build && ./Scripts/build_app.sh release
```

## Landing page (`docs/`, served by GitHub Pages)

`docs/index.html` links a single committed stylesheet, `docs/styles.css`, compiled
from `docs/tailwind.src.css` with the **Tailwind v4 standalone CLI** (no Node):

```bash
# one-off download of the standalone binary, then:
tailwindcss -i docs/tailwind.src.css -o docs/styles.css --minify
```

Edit `tailwind.src.css` (tokens + components), never `styles.css` (generated). The
palette — Matte Black `#0A0A0A` · Obsidian `#1C1C1E` · Industrial Amber `#FFB000` —
and the zone ramp mirror the app's `Theme.swift`. Both files are committed so Pages
has no build step. Screenshots come from `Flux --snapshot out.png [light|dark]`.

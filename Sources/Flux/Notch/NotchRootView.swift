import SwiftUI
import AppKit

/// The SwiftUI content hosted inside `NotchPanel`.
///
/// The panel itself is one fixed-size, transparent NSPanel sized to the
/// max-expanded bounds (see `NotchWindowController`) — it never animates its
/// own frame (that tears and isn't interruptible at high refresh rates).
/// Instead this view draws a single `NotchShape` whose size and corner radii
/// change with `NotchViewModel.state`, wrapped in one `.animation(_:value:)`
/// that picks a *different* spring depending on the transition's direction
/// (see `springFor(_:)`) — growing overshoots, Alcove-style; collapsing
/// settles snappily — so macOS 14's Core Animation-backed SwiftUI renderer
/// morphs it the way the OS's own Dynamic Island does. Widget/activity
/// content is a separate overlay layered on top, so it can cross-fade
/// independently of the shape morph.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    /// The physical camera-housing notch's own size — the exact collapsed
    /// footprint, and the width reserved (blank) in the middle of the wider
    /// activity/expanded shapes so nothing is drawn where the camera sits.
    let notchSize: CGSize

    /// The physical notch's exact frame in this view's panel coordinate space.
    /// It is supplied after AppKit has laid out the panel, so the collapsed
    /// shell covers the hardware notch without relying on a second centering
    /// calculation. Snapshot callers can omit it and use the centered fallback.
    var collapsedFrame: CGRect? = nil

    /// Supplies now-playing artwork for `LiveActivity.Content.artwork`.
    /// Optional and set by the wiring agent; `nil` (or a `nil` return) falls
    /// back to a generic note glyph.
    var artworkProvider: (() -> NSImage?)?

    /// Lets the wiring agent intercept a tap while a live activity's wings are
    /// showing — e.g. routing a `.menuBarOverflow` tap into Arrange Mode
    /// instead of the notch's own open/close toggle. Return `true` to mark
    /// the tap handled (skip `viewModel.clicked()`); returning `false`, or a
    /// `nil` closure, falls through to the normal click behavior. Threaded in
    /// the same optional-closure style as `artworkProvider`; `LiveActivity`
    /// itself stays data-only, so this closure is the one place a tap gets
    /// app-specific meaning.
    var onActivityTap: ((LiveActivity.Kind) -> Bool)?

    /// Growing (collapsed → activity/expanded, or activity → expanded)
    /// springs with visible overshoot — the shape bounces slightly past its
    /// final size before settling, the same "alive" feel Alcove-style Dynamic
    /// Island panels use for their open gesture. A higher `response` (slower)
    /// paired with a lower `dampingFraction` (less damping) than the collapse
    /// spring below is what produces that overshoot.
    private static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.68)

    /// Shrinking (anything → collapsed) springs snappier and without
    /// overshoot — closing should read as a crisp, immediate dismissal, not
    /// another bounce. A lower `response` (faster) and higher
    /// `dampingFraction` (more damping) than `expandSpring` is what keeps
    /// this one critically-damped-ish rather than bouncy.
    private static let collapseSpring = Animation.spring(response: 0.32, dampingFraction: 0.78)

    /// Picks the spring by transition *direction*, not a single fixed curve
    /// for every state change: `.animation(_:value:)` re-evaluates its
    /// animation argument using the view's freshly re-rendered body (i.e.
    /// the *new* value of `state`), so returning a different `Animation`
    /// depending on the incoming state is enough to make the collapse
    /// direction settle snappily while every growing direction overshoots —
    /// without needing two separate `.animation` modifiers or manual
    /// transaction plumbing.
    private func springFor(_ state: NotchState) -> Animation {
        // Keyed on the transition DIRECTION (recorded by the view model just
        // before publishing the new state), not on the target state alone:
        // `.expanded → .activity` targets a non-collapsed state but is still
        // a shrink, and should settle snappily rather than overshoot.
        viewModel.lastTransitionWasShrink ? Self.collapseSpring : Self.expandSpring
    }

    /// How long the springs above take to settle — used to delay narrowing
    /// `interactiveRect` back down to the final rect (see
    /// `updateInteractiveRect`). Chosen per *direction*, alongside
    /// `springFor(_:)`, rather than one shared value for both: a single 0.5s
    /// delay applied to a collapse — which `collapseSpring` (response 0.32,
    /// so it visually settles around ~0.32-0.35s) actually finishes well
    /// before — left the stale, still-widened hit-rect alive for an extra
    /// ~0.15-0.18s after the shape had already visually shrunk. In that gap a
    /// click landing in the now-invisible sliver was silently swallowed (it
    /// hit-tested "inside the notch" against geometry nothing was drawn at),
    /// and a lingering hover-in could even re-trigger a hover-open right after
    /// the user had just closed it. `expandSettleDelay` stays a hair past
    /// `expandSpring`'s slower response (kept for the overshoot path, which
    /// settles later than a plain critically-damped curve would suggest);
    /// `collapseSettleDelay` is trimmed down to match `collapseSpring`'s own,
    /// snappier settle time instead of inheriting the growing direction's
    /// number.
    private static let expandSettleDelay: TimeInterval = 0.5
    private static let collapseSettleDelay: TimeInterval = 0.35

    /// Cancelled/replaced on every state change so only the most recent
    /// transition's narrowing actually lands — see `updateInteractiveRect`.
    @State private var interactiveRectSettleTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                shapeLayer(panelWidth: proxy.size.width)
            }
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: .topLeading)
                // A plain tap toggles collapse/expand (unless `onActivityTap`
                // claims it first — see `handleTap`). This sits on the
                // *container*, underneath whatever a widget's expanded view
                // draws; SwiftUI hit-tests descendant controls (a widget's own
                // buttons) before an ancestor's `onTapGesture`, so this never
                // steals taps meant for the widget's own UI.
                .onTapGesture { handleTap() }
                .onAppear {
                    updateInteractiveRect(panelWidth: proxy.size.width)
                }
                .onChange(of: viewModel.state) { oldState, newState in
                    updateInteractiveRect(panelWidth: proxy.size.width, from: oldState, to: newState)
                }
                // M7: toggling Duo view while Now Playing is ALREADY the
                // expanded widget changes this view's size without `state`
                // itself changing — the widen/narrow/spring dance above only
                // reacts to `state`, so this just re-snaps `interactiveRect`
                // to the new footprint immediately (correct hit-testing) and
                // otherwise lets the size pop rather than spring; toggling
                // the Duo setting mid-session is rare enough that this small
                // scope cut is worth not doubling `updateInteractiveRect`'s
                // already-subtle transition bookkeeping for it.
                .onChange(of: viewModel.duoActive) { _, _ in
                    updateInteractiveRect(panelWidth: proxy.size.width)
                }
        }
        .animation(springFor(viewModel.state), value: viewModel.state)
        .ignoresSafeArea()
    }

    // MARK: - Tap routing

    /// A plain tap normally toggles collapse/expand. While a live activity's
    /// wings are showing, though, some activity kinds want the tap to mean
    /// something else entirely (`.menuBarOverflow` opening Arrange Mode
    /// rather than expanding a notch widget for it) — `onActivityTap` is the
    /// hook that lets the wiring agent claim that tap; only when it declines
    /// (or isn't set) does this fall through to the ordinary toggle.
    ///
    /// An option-click, in ANY state, instead restores the most recently
    /// dismissed live activity (`NotchViewModel.clicked(optionDown:)` →
    /// `LiveActivityCenter.restoreLastDismissed()`) — checked, and handled,
    /// before `onActivityTap` even gets a look, since it's an entirely
    /// different action from whatever a plain tap on the current wing means.
    /// `onTapGesture` hands back no event/modifier info of its own, so the
    /// simplest correct read is `NSEvent.modifierFlags` at the moment the tap
    /// actually lands — that's live global keyboard-modifier state, not
    /// anything cached, so it reflects whatever's held down for exactly this
    /// click.
    private func handleTap() {
        guard !NSEvent.modifierFlags.contains(.option) else {
            viewModel.clicked(optionDown: true)
            return
        }
        if case .activity = viewModel.state,
           let kind = viewModel.activities.current?.kind,
           onActivityTap?(kind) == true {
            return
        }
        viewModel.clicked()
    }

    // MARK: - Geometry

    /// The footprint for an arbitrary state — not just the current one — so
    /// `updateInteractiveRect` can compute the outgoing shape's rect during a
    /// transition, not only the incoming one. `notchSize` is fixed for the
    /// panel's lifetime (a screen change tears down and rebuilds the whole
    /// panel via `NotchWindowController`).
    private func size(for state: NotchState) -> CGSize {
        switch state {
        case .collapsed:
            return validCollapsedFrame?.size ?? notchSize
        case .activity:
            return CGSize(width: notchSize.width + NotchMetrics.wingWidth * 2,
                          height: max(notchSize.height, 32))
        case .expanded(let widgetID):
            if isDuoLayout(for: widgetID) {
                return CGSize(width: NotchMetrics.duoWidth(for: notchSize.width),
                              height: NotchMetrics.duoHeight(for: notchSize.width))
            }
            return CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width),
                          height: NotchMetrics.expandedHeight(for: notchSize.width))
        }
    }

    /// Whether `widgetID`'s expanded panel should render as Duo view (Now
    /// Playing + Calendar side by side) rather than alone. `viewModel.
    /// duoActive` alone isn't quite enough to trust here — it can be one
    /// Combine tick stale relative to the registry (e.g. the instant Calendar
    /// is disabled) — so this re-checks that Calendar is actually a currently
    /// enabled widget too, which both `size(for:)` and `expandedContent(for:)`
    /// call THIS shared function for, so the visible shape's size and its
    /// content can never disagree about whether Duo is active this frame.
    /// Expanding Calendar directly is untouched: Duo only ever applies to
    /// `.nowPlaying`.
    private func isDuoLayout(for widgetID: WidgetID) -> Bool {
        guard widgetID == .nowPlaying, viewModel.duoActive else { return false }
        return viewModel.registry.enabledWidgets.contains { $0.id == .calendar }
    }

    /// The exact collapsed frame when the real panel supplied one. Snapshot
    /// fixtures use the centered fallback because they have no screen frame.
    private var validCollapsedFrame: CGRect? {
        guard let collapsedFrame,
              collapsedFrame.width > 0,
              collapsedFrame.height > 0 else { return nil }
        return collapsedFrame
    }

    /// The shape's current footprint in the fixed-size panel.
    private var containerSize: CGSize { size(for: viewModel.state) }

    /// The rect `state`'s shape occupies in this view's own coordinate space
    /// (top-anchored, horizontally centered for open states, and exact for
    /// the collapsed physical-notch state).
    private func rect(for state: NotchState, panelWidth: CGFloat) -> CGRect {
        if case .collapsed = state, let validCollapsedFrame {
            return validCollapsedFrame
        }
        let size = size(for: state)
        let origin = CGPoint(x: (panelWidth - size.width) / 2, y: 0)
        return CGRect(origin: origin, size: size)
    }

    /// Publishes the shape's current bounds, in this view's own coordinate
    /// space, back to the view model. `NotchHostingView.hitTest` and hover
    /// containment both hit-test against exactly this rect, so clicks and
    /// hover outside the visible shape fall through to whatever's
    /// behind the (otherwise fully transparent) panel instead of being
    /// swallowed by it.
    ///
    /// A state *change* is where this gets subtle: `shapeLayer`'s footprint
    /// spends `expandSpring`/`collapseSpring`'s ~0.3-0.4s morphing between the
    /// outgoing and incoming sizes, but `viewModel.state` itself (and hence this rect,
    /// if it jumped straight to the final size) changes instantly. Setting
    /// `interactiveRect` to only the final rect for that whole window would
    /// make part of the still-visible outgoing shape (while it's shrinking)
    /// or part of the newly-growing incoming shape fail to hit-test as
    /// "inside the notch" for the animation's duration. So a transition
    /// first *widens* `interactiveRect` to the union of both rects — always
    /// a superset of whatever's actually on screen mid-morph — then narrows
    /// it back down to just the settled, final rect once the spring's had
    /// time to finish (`expandSettleDelay`/`collapseSettleDelay`, picked by
    /// the same incoming-state direction `springFor(_:)` uses), cancelling
    /// any still-pending narrowing from a previous, since-superseded
    /// transition.
    private func updateInteractiveRect(panelWidth: CGFloat, from oldState: NotchState? = nil, to newState: NotchState? = nil) {
        let state = newState ?? viewModel.state
        let finalRect = rect(for: state, panelWidth: panelWidth)

        interactiveRectSettleTask?.cancel()

        guard let oldState, oldState != state else {
            viewModel.interactiveRect = finalRect
            return
        }

        viewModel.interactiveRect = rect(for: oldState, panelWidth: panelWidth).union(finalRect)
        // Same direction rule as `springFor(_:)`: any shrink (not just
        // landing on .collapsed) settles on the collapse spring's timetable.
        let isShrink = NotchViewModel.isShrink(from: oldState, to: state)
        let delay = isShrink ? Self.collapseSettleDelay : Self.expandSettleDelay
        interactiveRectSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            viewModel.interactiveRect = finalRect
        }
    }

    // MARK: - Shape layer

    private var shape: NotchShape {
        switch viewModel.state {
        case .collapsed: return .collapsed
        case .activity: return .activity
        case .expanded: return .expanded
        }
    }

    /// The collapsed shell covers the physical camera housing. Open states use
    /// the selected Flux surface color below the physical notch.
    private var isCollapsed: Bool { viewModel.state == .collapsed }

    /// A soft drop shadow is what actually sells the "lifted" panel now that
    /// there's no fill/stroke change to do it — but only while there's
    /// something to lift off of: while collapsed the shape must stay
    /// perfectly seamless/invisible against the physical notch, so the
    /// shadow is skipped entirely (not just faded to zero opacity) rather
    /// than risk a hairline halo around the idle notch.
    ///
    /// M8 audit fix: `.compositingGroup()` sits between the filled shape and
    /// `.shadow(...)` so the shadow is computed off the shape's flattened
    /// alpha (a single rasterized layer), not re-derived from the shape's
    /// live vector geometry on every one of the ~60-120 frames `NotchShape`'s
    /// `animatableData` ticks through during a spring — that per-frame
    /// re-rasterization of the whole shadow (rather than an offset+blur of an
    /// already-flattened layer) was a measurable chunk of the expand/collapse
    /// morph's frame cost. Deliberately `.compositingGroup()`, NOT
    /// `.drawingGroup()`: the latter forces a Metal-backed off-screen render,
    /// which the `cacheDisplay(in:to:)`-based snapshot path in
    /// `OffscreenRender` (used by both `--snapshot`/`--snapshot-notch`) can't
    /// reliably capture from its own off-screen, never-on-a-real-display
    /// window — `.compositingGroup()` only flattens compositing (opacity/
    /// blend mode/shadow), which `cacheDisplay` handles the same as any other
    /// layered SwiftUI content. Shadow radius trimmed 16 → 12 alongside this
    /// — softer/tighter blur is both cheaper to composite and reads closer to
    /// the Alcove reference now that it's rendered off one flattened layer
    /// instead of the shape's raw silhouette.
    private func shapeLayer(panelWidth: CGFloat) -> some View {
        let frame = rect(for: viewModel.state, panelWidth: panelWidth)
        return shape.fill(isCollapsed ? NotchDesign.physicalNotchFill : NotchDesign.panelFill)
            .frame(width: frame.width, height: frame.height)
            .compositingGroup()
            .shadow(color: isCollapsed ? .clear : Theme.notchShadowColor,
                    radius: isCollapsed ? 0 : 12,
                    y: isCollapsed ? 0 : 4)
            .overlay(contentLayer)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - Content layer

    @ViewBuilder
    private var contentLayer: some View {
        switch viewModel.state {
        case .collapsed:
            EmptyView()
        case .activity:
            activityContent
        case .expanded(let widgetID):
            expandedContent(for: widgetID)
        }
    }

    /// The chrome every expanded panel's content shares — regardless of
    /// whether it's a single widget or Duo view: horizontal breathing room,
    /// top clearance for the physical notch cutout, and bottom clearance for
    /// the shape's own bottom corner radius. Extracted out of
    /// `expandedContent(for:)`/`duoContent` (which used to each apply this
    /// exact same chain of modifiers independently) so there's exactly one
    /// place this chrome is defined; both call sites just apply it once via
    /// `.modifier(ExpandedChrome(...))`.
    ///
    /// M8 audit fix: this used to also own the expanded body's fade-in/out
    /// morph via two `@State` values (`contentBlur`/`contentOpacity`) an
    /// explicit `updateContentMorph(for:)` drove with its own
    /// `withAnimation(.easeOut(duration: 0.25))` — entirely separate from,
    /// and un-synced with, the spring `.animation(springFor(state), value:
    /// state)` (see `body`) actually driving the shape morph and this
    /// content's own frame size. That mismatch was the primary hitch: a
    /// full-content Gaussian `.blur(radius:)`, RE-RASTERIZED on every one of
    /// the ~60-120 animated frames a spring ticks through, is expensive
    /// enough on its own to visibly stutter the whole expand/collapse morph
    /// — and it bought nothing a plain cross-fade doesn't already sell just
    /// as well here. The morph now lives entirely in `ExpandedContentTransition`
    /// below, applied via a plain `.transition(...)` on the content-layer
    /// branches (`activityContent`/`expandedContent(for:)` — see
    /// `contentLayer`), which rides that SAME `.animation(springFor(state),
    /// value: state)` transaction instead of a second, independent curve —
    /// one mechanism, one timeline, no blur.
    private struct ExpandedChrome: ViewModifier {
        /// `notchSize.height` at both call sites — clears the physical notch
        /// cutout at the top of the expanded shape without adding a second
        /// arbitrary gap above the content.
        let topInset: CGFloat

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                // The smaller Alcove shell has less unused depth than the
                // previous 190pt drawer. Fourteen points clear the continuous
                // bottom curve while leaving the media transport row room to
                // settle without clipping.
                .padding(.bottom, 14)
        }
    }

    /// The expanded body's fade+scale morph (M8 audit FIX 1 + FIX 3):
    /// opacity `0 → 1` paired with a slight scale-up `0.96 → 1.0` (anchored
    /// at `.top`, matching how the content itself is top-aligned), applied
    /// as a `ViewModifier`-backed `AnyTransition` rather than a `@State`-
    /// driven blur. Conforming to `Animatable` (via `progress`) is what makes
    /// this continuously interpolated across the whole transition — SwiftUI
    /// drives `progress` from `0` (this modifier's "active"/removed end) to
    /// `1` ("identity"/fully shown) using whatever animation is in the
    /// current transaction, exactly like `NotchShape.animatableData` drives
    /// the shape morph — rather than a two-keyframe snap.
    ///
    /// Attaching this via `.transition(...)` (see `activityContent`/
    /// `expandedContent(for:)`) rather than a plain modifier is what fixes
    /// the collapse-side "content pop": `contentLayer`'s switch tears the
    /// `.expanded`/`.activity` branch's view out of the tree the same frame
    /// `state` leaves it, so a hand-rolled `@State` fade (which needs a
    /// *living* view to keep re-rendering while it animates) had nothing left
    /// to animate — the fade-out simply never rendered, popping the content
    /// away instantly even while the shape itself kept shrinking. A
    /// `.transition` is exactly the primitive SwiftUI has for animating a
    /// view's removal (not just its insertion): it keeps that subtree alive,
    /// interpolating this modifier, for the whole animation before actually
    /// discarding it.
    private struct ExpandedContentTransition: ViewModifier, Animatable {
        var progress: Double

        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            content
                .opacity(progress)
                .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
        }
    }

    private static let expandedContentMorph = AnyTransition.modifier(
        active: ExpandedContentTransition(progress: 0),
        identity: ExpandedContentTransition(progress: 1))

    /// The two wings either side of the (blank, reserved) physical notch
    /// area, showing the current live activity's leading/trailing content.
    ///
    /// `.transition(.opacity)` (M8 audit FIX 6) is the same "content pop"
    /// fix as `expandedContentMorph` above, applied here too: without it, the
    /// wings would pop in/out instantly on the collapsed↔activity boundary
    /// the same way the expanded panel used to, since this branch is torn
    /// down/built by the exact same `contentLayer` switch. A plain opacity
    /// fade (rather than the fuller fade+scale morph) is enough here — the
    /// wings are thin strips flanking the physical notch, not a whole panel
    /// growing out of it, so a scale cue reads as unnecessary motion.
    private var activityContent: some View {
        let tint = viewModel.activities.current?.tint ?? .normal
        return HStack(spacing: 0) {
            content(for: viewModel.activities.current?.leading ?? .none, tint: tint)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
            Spacer(minLength: notchSize.width)
            content(for: viewModel.activities.current?.trailing ?? .none, tint: tint)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .transition(.opacity)
    }

    /// The expanded panel: pure widget content, no chrome. Alcove's panel
    /// doesn't reserve a separate compact strip at the top the way the old
    /// design did — the physical notch cutout itself is the "top area", so
    /// content only needs to clear it via top padding (`notchSize.height`), not
    /// a whole extra row. Resolved through `enabledWidgets` (not the
    /// plain, unfiltered `registry.widget(for:)`) so a widget that was
    /// disabled out from under an in-flight state transition can never
    /// render here even for a single frame — belt-and-suspenders alongside
    /// `NotchViewModel` re-routing `state` away from it (see
    /// `observeRegistry()`).
    ///
    /// The single-widget and Duo branches used to each repeat the same
    /// paddings + blur + opacity chain verbatim (see `ExpandedChrome` above)
    /// — applying it once here, to the `Group` wrapping both branches,
    /// removes that duplication and guarantees the two branches can never
    /// drift out of sync on their chrome again.
    ///
    /// M8 audit FIX 5: the widget content used to sit directly inside the
    /// single frame this function's whole result gets sized to
    /// (`containerSize`, whose width/height are themselves an interpolated
    /// spring value while `state` is mid-transition — see `body`'s
    /// `.animation(springFor(state), value: state)`). A widget's own
    /// `MarqueeText`/`ScrubberTrack`/layout `HStack`s measure their available
    /// width via `GeometryReader` and react to every change (e.g.
    /// `MarqueeText`'s `onChange(of: containerWidth)` restarting its scroll
    /// loop) — so with the frame *itself* animating, that content was
    /// re-measuring and re-laying-out on every single one of the spring's
    /// ~60-120 interpolated frames, restarting marquee loops mid-scroll and
    /// generally doing real layout work far more often than the eye can even
    /// register, which is real, measurable frame cost stacked on top of the
    /// shape morph. The fix: give the widget content a frame FIXED at this
    /// state's own settled, final size (`finalSize` below — never animated,
    /// since it depends only on discrete `state`, not a continuously
    /// interpolated value) so it lays out exactly once per widget/Duo target;
    /// the *animated* `containerSize`-sized frame wraps that fixed content
    /// from the outside instead, with `.clipped()` turning it into a growing/
    /// shrinking viewport over already-laid-out content rather than a
    /// resize that content has to keep reacting to.
    private func expandedContent(for widgetID: WidgetID) -> some View {
        let widget = viewModel.registry.enabledWidgets.first { $0.id == widgetID }
        let finalSize = size(for: .expanded(widgetID))
        return Group {
            if isDuoLayout(for: widgetID),
               let calendarWidget = viewModel.registry.enabledWidgets.first(where: { $0.id == .calendar }) {
                duoContent(nowPlaying: widget, calendar: calendarWidget)
            } else if let widget {
                widget.makeExpandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(ExpandedChrome(topInset: notchSize.height))
        // Fixed, settled-size inner frame — laid out once per widget/Duo
        // target, never interpolated (see doc comment above). `.animation
        // (nil, value:)` is a belt-and-suspenders guard: `finalSize` only
        // ever changes in lockstep with discrete `state`/`duoActive` changes
        // anyway, but this makes the "this frame never springs" invariant
        // explicit and immune to some ancestor's `.animation(_:value:)`
        // reaching in and animating it regardless.
        .frame(width: finalSize.width, height: finalSize.height, alignment: .top)
        .animation(nil, value: finalSize)
        // The animated viewport: `containerSize` is the same interpolated-
        // during-spring value `shapeLayer` sizes the visible shell to, so
        // this clips the fixed-size content above to exactly what the
        // morphing shape is showing at each instant.
        .frame(width: containerSize.width, height: containerSize.height, alignment: .top)
        .clipped()
        .transition(Self.expandedContentMorph)
    }

    /// Alcove's Duo view (M7 v1.7 parity): Now Playing's expanded content
    /// beside a Calendar pane, split by a hairline divider. Both panes share
    /// this container's single fade+scale content morph
    /// (`expandedContentMorph`, applied via `.transition(...)` in
    /// `expandedContent(for:)`, its only caller), so entering/leaving Duo
    /// fades exactly like any other expanded-content change rather than
    /// needing a second, separate morph.
    ///
    /// The Calendar pane is a *proportion* of the available width rather than
    /// a fixed 200pt. `GeometryReader` keeps the split correct inside the
    /// stable shell's inner padding.
    private func duoContent(nowPlaying: NotchWidget?, calendar: NotchWidget) -> some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let calendarWidth = (availableWidth * NotchMetrics.duoCalendarPaneFraction).rounded()
            let dividerWidth: CGFloat = 1
            let nowPlayingWidth = max(0, availableWidth - calendarWidth - dividerWidth)
            HStack(spacing: 0) {
                Group {
                    if let nowPlaying { nowPlaying.makeExpandedView() }
                    else { Color.clear }
                }
                // Duo's Now Playing pane is narrow too. The shared player
                // uses this environment to drop decorative waveform chrome
                // and give its metadata the width back; without it, long
                // titles were clipped even after Calendar became compact.
                .environment(\.isNarrowPane, true)
                .padding(.trailing, NotchDesign.paneInsets)
                .frame(width: nowPlayingWidth, height: proxy.size.height, alignment: .topLeading)
                .clipped()

                Rectangle()
                    .fill(NotchDesign.hairlineColor)
                    .frame(width: dividerWidth)
                    .padding(.vertical, 12)

                calendar.makeExpandedView()
                    // Tells the agenda it's in a narrow pane so it can drop
                    // to start-times-only rather than wrapping onto three
                    // lines — see `EnvironmentValues.isNarrowPane`.
                    .environment(\.isNarrowPane, true)
                    .frame(width: calendarWidth, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: availableWidth, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .clipped()
    }

    /// Renders one `LiveActivity.Content` value with Theme tokens. The single
    /// place that turns the data-only activity model into pixels. `tint`
    /// (from the owning `LiveActivity`, forwarded by `activityContent`) only
    /// affects the cases actually shown in the collapsed wings (`icon` /
    /// `iconText`/ `text`) — `gauge` and `artwork` are HUD/Now-Playing-only
    /// content that never carries a warning tint in practice, so they keep
    /// their fixed monochrome color unconditionally.
    ///
    /// M7: wing content is monochrome — `Theme.accentColor` no longer
    /// appears here at all. `tint == .warning` is the one exception that
    /// still gets a color (`Theme.warningColor`, for genuinely urgent wings
    /// like low battery); everything else renders plain white.
    @ViewBuilder
    private func content(for value: LiveActivity.Content, tint: LiveActivity.ActivityTint = .normal) -> some View {
        let tintColor = tint == .warning ? Theme.warningColor : NotchDesign.primaryColor
        switch value {
        case .none:
            EmptyView()
        case .icon(let systemName):
            Image(systemName: systemName)
                .foregroundStyle(tintColor)
        case .text(let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
                .lineLimit(1)
        case .iconText(let systemName, let text):
            HStack(spacing: 4) {
                Image(systemName: systemName)
                Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tintColor)
        case .gauge(let value, let systemName):
            let clamped = min(max(value, 0), 1)
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 11))
                    .frame(width: 12)
                // A hand-drawn thin capsule rather than `ProgressView` — the
                // default macOS bar style reads as a chunky, inset control at
                // this width; a flush 3pt-tall capsule track/fill matches the
                // rest of the wing content (icons/text) at a glance. The fill
                // width (not the whole gauge) is what's animated, and only on
                // value changes — no continuous/repeating animation, matching
                // this app's 0%-idle-CPU contract.
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchDesign.primaryColor.opacity(0.22))
                    GeometryReader { geometry in
                        Capsule()
                            .fill(NotchDesign.primaryColor.opacity(0.9))
                            .frame(width: geometry.size.width * clamped)
                    }
                }
                .frame(width: 28, height: 3)
                .animation(.easeOut(duration: 0.15), value: clamped)
            }
            .foregroundStyle(NotchDesign.primaryColor)
        case .artwork:
            if let image = artworkProvider?() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(NotchDesign.primaryColor.opacity(0.9))
            }
        }
    }
}

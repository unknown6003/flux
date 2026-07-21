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
        state == .collapsed ? Self.collapseSpring : Self.expandSpring
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

    /// Drives the expanded body's blur-morph-in/out (see `expandedContent`
    /// and `updateContentMorph`). Start hidden (heavily blurred, transparent)
    /// so a fresh `.expanded` case — which SwiftUI only actually constructs
    /// the moment `contentLayer`'s switch first lands on it — always animates
    /// *in* from this state rather than popping in already-sharp.
    @State private var contentBlur: CGFloat = 8
    @State private var contentOpacity: Double = 0

    var body: some View {
        GeometryReader { proxy in
            shapeLayer
                .overlay(contentLayer)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                // A plain tap toggles collapse/expand (unless `onActivityTap`
                // claims it first — see `handleTap`). This sits on the
                // *container*, underneath whatever a widget's expanded view
                // draws; SwiftUI hit-tests descendant controls (a widget's own
                // buttons) before an ancestor's `onTapGesture`, so this never
                // steals taps meant for the widget's own UI.
                .onTapGesture { handleTap() }
                .onAppear {
                    updateInteractiveRect(panelWidth: proxy.size.width)
                    updateContentMorph(for: viewModel.state)
                }
                .onChange(of: viewModel.state) { oldState, newState in
                    updateInteractiveRect(panelWidth: proxy.size.width, from: oldState, to: newState)
                    updateContentMorph(for: newState)
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
        // Kept at this stable, always-present position (rather than nested
        // inside `contentLayer`'s per-state switch) so it reliably observes
        // every transition of `shouldBreathe` — including the one back to
        // `false` when a state change tears down the branch the modifier
        // would otherwise have been attached to, which could otherwise leave
        // the `repeatForever` animation started below running indefinitely.
        .onChange(of: shouldBreathe) { _, breathe in updateBreathing(breathe) }
        .animation(springFor(viewModel.state), value: viewModel.state)
        .ignoresSafeArea()
    }

    /// Animates the expanded body's blur/opacity morph: sharp and opaque
    /// (`0`/`1`) the instant `state` becomes `.expanded`, blurred and
    /// invisible (`8`/`0`) for every other state. `withAnimation` here is
    /// what makes this cancellation-safe "for free" — SwiftUI interrupts an
    /// in-flight implicit animation cleanly when a new one is issued for the
    /// same properties, so rapid re-toggling (e.g. a fast swipe through
    /// several widgets) never leaves stale, half-finished blur state behind
    /// the way a hand-rolled `Task`-based sequence could.
    private func updateContentMorph(for state: NotchState) {
        let expanding = { if case .expanded = state { return true }; return false }()
        withAnimation(.easeOut(duration: 0.25)) {
            contentBlur = expanding ? 0 : 8
            contentOpacity = expanding ? 1 : 0
        }
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
            return notchSize
        case .activity:
            return CGSize(width: notchSize.width + NotchMetrics.wingWidth * 2,
                          height: max(notchSize.height, 32))
        case .expanded(let widgetID):
            guard isDuoLayout(for: widgetID) else {
                return CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width),
                              height: NotchMetrics.expandedHeight(for: widgetID))
            }
            return CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width) + NotchMetrics.duoExtraWidth,
                          height: max(NotchMetrics.expandedHeight(for: .nowPlaying), NotchMetrics.expandedHeight(for: .calendar)))
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

    /// The shape's current footprint — `viewModel.state`'s size, centered in
    /// the fixed-size panel.
    private var containerSize: CGSize { size(for: viewModel.state) }

    /// The rect `state`'s shape occupies in this view's own coordinate space
    /// (top-anchored, horizontally centered — matching how `shapeLayer` and
    /// `NotchWindowController.position` both lay the panel out).
    private func rect(for state: NotchState, panelWidth: CGFloat) -> CGRect {
        let size = size(for: state)
        let origin = CGPoint(x: (panelWidth - size.width) / 2, y: 0)
        return CGRect(origin: origin, size: size)
    }

    /// Publishes the shape's current bounds, in this view's own coordinate
    /// space, back to the view model. `NotchHostingView.hitTest` and hover
    /// containment both hit-test against exactly this rect, so clicks and
    /// hover outside the visible black shape fall through to whatever's
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
        let delay = state == .collapsed ? Self.collapseSettleDelay : Self.expandSettleDelay
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

    /// Pure black in *every* state (collapsed, activity, expanded alike) —
    /// the M7 Alcove redesign drops the old expanded-only opacity dip and
    /// amber glow stroke entirely, so the panel always reads as one seamless
    /// surface fused to the physical notch, never a visibly "lifted" or
    /// tinted card.
    private var isCollapsed: Bool { viewModel.state == .collapsed }

    /// A soft drop shadow is what actually sells the "lifted" panel now that
    /// there's no fill/stroke change to do it — but only while there's
    /// something to lift off of: while collapsed the shape must stay
    /// perfectly seamless/invisible against the physical notch, so the
    /// shadow is skipped entirely (not just faded to zero opacity) rather
    /// than risk a hairline halo around the idle notch.
    private var shapeLayer: some View {
        shape
            .fill(Color.black)
            .frame(width: containerSize.width, height: containerSize.height)
            .scaleEffect(breathingScale)
            .shadow(color: isCollapsed ? .clear : .black.opacity(0.55),
                    radius: isCollapsed ? 0 : 16,
                    y: isCollapsed ? 0 : 4)
    }

    // MARK: - Breathing hover cue (click mode only)

    @State private var breathePhase = false

    /// Click mode gives hover no functional effect, so without *some* signal
    /// a user hovering the bare notch has no reason to believe clicking does
    /// anything. This gentle, looping scale — armed only while collapsed,
    /// click-triggered, and actually hovered — is that affordance. It only
    /// runs while a cursor is actively over the notch, so it never costs
    /// anything at idle.
    private var shouldBreathe: Bool {
        viewModel.expansionTrigger == .click && viewModel.hoverHint && viewModel.state == .collapsed
    }

    private var breathingScale: CGFloat {
        shouldBreathe && breathePhase ? 1.02 : 1.0
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

    private func updateBreathing(_ breathe: Bool) {
        if breathe {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                breathePhase = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { breathePhase = false }
        }
    }

    /// The chrome every expanded panel's content shares — regardless of
    /// whether it's a single widget or Duo view: horizontal breathing room,
    /// top clearance for the physical notch cutout, bottom clearance for the
    /// shape's own bottom corner radius, and the blur/opacity content morph.
    /// Extracted out of `expandedContent(for:)`/`duoContent` (which used to
    /// each apply this exact same chain of modifiers independently) so
    /// there's exactly one place this chrome is defined; both call sites just
    /// apply it once via `.modifier(ExpandedChrome(...))`.
    private struct ExpandedChrome: ViewModifier {
        /// `notchSize.height + 6` at both call sites — clears the physical
        /// notch cutout at the top of the expanded shape.
        let topInset: CGFloat
        let blur: CGFloat
        let opacity: Double

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                // The M7 Alcove redesign grew the expanded shape's bottom
                // corner radius from 24pt to 32pt (see `NotchShape.expanded`)
                // without growing this padding to match — content (notably
                // the transport row, the bottom-most thing any widget draws)
                // kept clearing the *old*, tighter corner but now visually
                // crowds/overhangs the more generous curve underneath it.
                // 18pt restores that clearance.
                .padding(.bottom, 18)
                .blur(radius: blur)
                .opacity(opacity)
        }
    }

    /// The two wings either side of the (blank, reserved) physical notch
    /// area, showing the current live activity's leading/trailing content.
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
    }

    /// The expanded panel: pure widget content, no chrome. Alcove's panel
    /// doesn't reserve a separate compact strip at the top the way the old
    /// design did — the physical notch cutout itself is the "top area", so
    /// content only needs to clear it via top padding (`notchSize.height +
    /// 6`), not a whole extra row. Resolved through `enabledWidgets` (not the
    /// plain, unfiltered `registry.widget(for:)`) so a widget that was
    /// disabled out from under an in-flight state transition can never
    /// render here even for a single frame — belt-and-suspenders alongside
    /// `NotchViewModel` re-routing `state` away from it (see
    /// `observeRegistry()`).
    ///
    /// `.blur(radius: contentBlur)` + `.opacity(contentOpacity)` is the
    /// content "morph" — SwiftUI has no built-in blur transition primitive,
    /// so `updateContentMorph` drives these two plain `@State` values with an
    /// explicit `withAnimation` instead of a `.transition(...)` modifier.
    ///
    /// The single-widget and Duo branches used to each repeat the same
    /// paddings + blur + opacity chain verbatim (see `ExpandedChrome` below)
    /// — applying it once here, to the `Group` wrapping both branches,
    /// removes that duplication and guarantees the two branches can never
    /// drift out of sync on their chrome again.
    private func expandedContent(for widgetID: WidgetID) -> some View {
        let widget = viewModel.registry.enabledWidgets.first { $0.id == widgetID }
        return Group {
            if isDuoLayout(for: widgetID),
               let calendarWidget = viewModel.registry.enabledWidgets.first(where: { $0.id == .calendar }) {
                duoContent(nowPlaying: widget, calendar: calendarWidget)
            } else if let widget {
                widget.makeExpandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(ExpandedChrome(topInset: notchSize.height + 6, blur: contentBlur, opacity: contentOpacity))
        .frame(width: containerSize.width, height: containerSize.height, alignment: .top)
    }

    /// Alcove's Duo view (M7 v1.7 parity): Now Playing's expanded content at
    /// flexible width beside a fixed-width Calendar pane, split by a hairline
    /// divider. Both panes share this container's single blur/opacity content
    /// morph (`contentBlur`/`contentOpacity`, applied via `ExpandedChrome` in
    /// `expandedContent(for:)`, its only caller), so entering/leaving Duo
    /// fades exactly like any other expanded-content change rather than
    /// needing a second, separate morph.
    private static let duoCalendarPaneWidth: CGFloat = 200

    private func duoContent(nowPlaying: NotchWidget?, calendar: NotchWidget) -> some View {
        HStack(spacing: 0) {
            Group {
                if let nowPlaying { nowPlaying.makeExpandedView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 12)

            calendar.makeExpandedView()
                .frame(width: Self.duoCalendarPaneWidth)
                .frame(maxHeight: .infinity)
        }
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
        let tintColor = tint == .warning ? Theme.warningColor : Color.white
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
                    Capsule().fill(Color.white.opacity(0.22))
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: geometry.size.width * clamped)
                    }
                }
                .frame(width: 28, height: 3)
                .animation(.easeOut(duration: 0.15), value: clamped)
            }
            .foregroundStyle(.white)
        case .artwork:
            if let image = artworkProvider?() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }
}

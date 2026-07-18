import SwiftUI
import AppKit

/// The SwiftUI content hosted inside `NotchPanel`.
///
/// The panel itself is one fixed-size, transparent NSPanel sized to the
/// max-expanded bounds (see `NotchWindowController`) — it never animates its
/// own frame (that tears and isn't interruptible at high refresh rates).
/// Instead this view draws a single `NotchShape` whose size and corner radii
/// change with `NotchViewModel.state`, wrapped in one `.animation(_:value:)`
/// spring, so macOS 14's Core Animation-backed SwiftUI renderer morphs it
/// smoothly the way the OS's own Dynamic Island does. Widget/activity content
/// is a separate overlay layered on top, so it can cross-fade independently
/// of the shape morph.
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

    private static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)

    /// How long the spring in `springAnimation` takes to settle — used to
    /// delay narrowing `interactiveRect` back down to the final rect (see
    /// `updateInteractiveRect`). Kept close to, but a hair past, the spring's
    /// own `response` so the widened hit region outlives the visible morph
    /// rather than snapping in early.
    private static let interactiveRectSettleDelay: TimeInterval = 0.4

    /// Cancelled/replaced on every state change so only the most recent
    /// transition's narrowing actually lands — see `updateInteractiveRect`.
    @State private var interactiveRectSettleTask: Task<Void, Never>?

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
                .onAppear { updateInteractiveRect(panelWidth: proxy.size.width) }
                .onChange(of: viewModel.state) { oldState, newState in
                    updateInteractiveRect(panelWidth: proxy.size.width, from: oldState, to: newState)
                }
        }
        // Kept at this stable, always-present position (rather than nested
        // inside `contentLayer`'s per-state switch) so it reliably observes
        // every transition of `shouldBreathe` — including the one back to
        // `false` when a state change tears down the branch the modifier
        // would otherwise have been attached to, which could otherwise leave
        // the `repeatForever` animation started below running indefinitely.
        .onChange(of: shouldBreathe) { _, breathe in updateBreathing(breathe) }
        .animation(Self.springAnimation, value: viewModel.state)
        .ignoresSafeArea()
    }

    // MARK: - Tap routing

    /// A plain tap normally toggles collapse/expand. While a live activity's
    /// wings are showing, though, some activity kinds want the tap to mean
    /// something else entirely (`.menuBarOverflow` opening Arrange Mode
    /// rather than expanding a notch widget for it) — `onActivityTap` is the
    /// hook that lets the wiring agent claim that tap; only when it declines
    /// (or isn't set) does this fall through to the ordinary toggle.
    private func handleTap() {
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
        case .expanded:
            return CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width),
                          height: NotchMetrics.expandedHeight)
        }
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
    /// spends `springAnimation`'s ~0.35s morphing between the outgoing and
    /// incoming sizes, but `viewModel.state` itself (and hence this rect,
    /// if it jumped straight to the final size) changes instantly. Setting
    /// `interactiveRect` to only the final rect for that whole window would
    /// make part of the still-visible outgoing shape (while it's shrinking)
    /// or part of the newly-growing incoming shape fail to hit-test as
    /// "inside the notch" for the animation's duration. So a transition
    /// first *widens* `interactiveRect` to the union of both rects — always
    /// a superset of whatever's actually on screen mid-morph — then narrows
    /// it back down to just the settled, final rect once the spring's had
    /// time to finish (`interactiveRectSettleDelay`), cancelling any
    /// still-pending narrowing from a previous, since-superseded transition.
    private func updateInteractiveRect(panelWidth: CGFloat, from oldState: NotchState? = nil, to newState: NotchState? = nil) {
        let state = newState ?? viewModel.state
        let finalRect = rect(for: state, panelWidth: panelWidth)

        interactiveRectSettleTask?.cancel()

        guard let oldState, oldState != state else {
            viewModel.interactiveRect = finalRect
            return
        }

        viewModel.interactiveRect = rect(for: oldState, panelWidth: panelWidth).union(finalRect)
        interactiveRectSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.interactiveRectSettleDelay))
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

    /// Solid black while collapsed/activity so it reads as one surface with
    /// the physical notch; a hair short of opaque plus a faint accent glow
    /// once expanded, so the panel still looks native next to the hardware
    /// notch but visibly "lifts" as its own surface.
    private var isExpanded: Bool {
        if case .expanded = viewModel.state { return true }
        return false
    }

    private var shapeLayer: some View {
        shape
            .fill(isExpanded ? Color.black.opacity(0.98) : Color.black)
            .overlay {
                if isExpanded {
                    shape.stroke(Theme.accentColor.opacity(0.18), lineWidth: 1).blur(radius: 6)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .scaleEffect(breathingScale)
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
        shouldBreathe && breathePhase ? 1.05 : 1.0
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

    /// The two wings either side of the (blank, reserved) physical notch
    /// area, showing the current live activity's leading/trailing content.
    private var activityContent: some View {
        HStack(spacing: 0) {
            content(for: viewModel.activities.current?.leading ?? .none)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
            Spacer(minLength: notchSize.width)
            content(for: viewModel.activities.current?.trailing ?? .none)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    /// The expanded panel: a compact strip exactly the notch's own height at
    /// the top (so nothing is drawn under the physical camera), showing the
    /// active widget's `makeCompactView()` if it has one, then the widget's
    /// full `makeExpandedView()` filling the rest of the panel below it.
    /// Resolved through `enabledWidgets` (not the plain, unfiltered
    /// `registry.widget(for:)`) so a widget that was disabled out from under
    /// an in-flight state transition can never render here even for a single
    /// frame — belt-and-suspenders alongside `NotchViewModel` re-routing
    /// `state` away from it (see `observeRegistry()`).
    private func expandedContent(for widgetID: WidgetID) -> some View {
        let widget = viewModel.registry.enabledWidgets.first { $0.id == widgetID }
        return VStack(spacing: 0) {
            HStack {
                if let compact = widget?.makeCompactView() {
                    compact
                }
            }
            .frame(width: containerSize.width, height: notchSize.height)

            if let widget {
                widget.makeExpandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .top)
    }

    /// Renders one `LiveActivity.Content` value with Theme tokens. The single
    /// place that turns the data-only activity model into pixels.
    @ViewBuilder
    private func content(for value: LiveActivity.Content) -> some View {
        switch value {
        case .none:
            EmptyView()
        case .icon(let systemName):
            Image(systemName: systemName)
                .foregroundStyle(Theme.accentColor)
        case .text(let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        case .iconText(let systemName, let text):
            HStack(spacing: 4) {
                Image(systemName: systemName)
                Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
        case .gauge(let value, let systemName):
            HStack(spacing: 4) {
                Image(systemName: systemName)
                ProgressView(value: min(max(value, 0), 1))
                    .frame(width: 28)
            }
            .foregroundStyle(.white)
            .tint(Theme.accentColor)
        case .artwork:
            if let image = artworkProvider?() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(Theme.accentColor)
            }
        }
    }
}

import AppKit
import FluxCore
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchRootView.swift.
// Springs, settle delays, sizes, paddings, transitions and wing content are
// unchanged. Widget content comes from `NotchViewModel.widgetContent`.

/// The SwiftUI content of the fixed, transparent notch panel. One
/// `NotchShape` morphs between states with a direction-picked spring; the
/// widget or activity content cross-fades on top of it.
public struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    let notchSize: CGSize
    var collapsedFrame: CGRect?

    public init(viewModel: NotchViewModel, notchSize: CGSize, collapsedFrame: CGRect? = nil) {
        self.viewModel = viewModel
        self.notchSize = notchSize
        self.collapsedFrame = collapsedFrame
    }

    public static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.68)
    public static let collapseSpring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    public static let expandSettleDelay: TimeInterval = 0.5
    public static let collapseSettleDelay: TimeInterval = 0.35

    private func springFor(_ state: NotchState) -> Animation {
        viewModel.lastTransitionWasShrink ? Self.collapseSpring : Self.expandSpring
    }

    @State private var interactiveRectSettleTask: Task<Void, Never>?

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                shapeLayer(panelWidth: proxy.size.width)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onTapGesture { viewModel.handleTap(optionDown: NSEvent.modifierFlags.contains(.option)) }
            .onAppear { updateInteractiveRect(panelWidth: proxy.size.width) }
            .onChange(of: viewModel.state) { oldState, newState in
                updateInteractiveRect(panelWidth: proxy.size.width, from: oldState, to: newState)
            }
            .onChange(of: viewModel.duoActive) { _, _ in
                updateInteractiveRect(panelWidth: proxy.size.width)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(springFor(viewModel.state), value: viewModel.state)
        .ignoresSafeArea()
    }

    // MARK: Geometry

    private func size(for state: NotchState) -> CGSize {
        NotchLayout.size(for: state, notchSize: notchSize, collapsedFrame: collapsedFrame,
                         duo: viewModel.duoActive && viewModel.widgets.contains(.calendar))
    }

    private func isDuoLayout(for widget: FluxCore.Widget) -> Bool {
        guard widget == .nowPlaying, viewModel.duoActive else { return false }
        return viewModel.widgets.contains(.calendar)
    }


    private var containerSize: CGSize { size(for: viewModel.state) }

    private func rect(for state: NotchState, panelWidth: CGFloat) -> CGRect {
        NotchLayout.rect(for: state, panelWidth: panelWidth, notchSize: notchSize, collapsedFrame: collapsedFrame,
                         duo: viewModel.duoActive && viewModel.widgets.contains(.calendar))
    }

    /// Widens the hit rect to the union of both shapes during a morph, then
    /// narrows it once the spring has settled.
    private func updateInteractiveRect(panelWidth: CGFloat, from oldState: NotchState? = nil, to newState: NotchState? = nil) {
        let state = newState ?? viewModel.state
        let finalRect = rect(for: state, panelWidth: panelWidth)
        interactiveRectSettleTask?.cancel()
        guard let oldState, oldState != state else {
            viewModel.interactiveRect = finalRect
            return
        }
        viewModel.interactiveRect = rect(for: oldState, panelWidth: panelWidth).union(finalRect)
        let isShrink = NotchViewModel.isShrink(from: oldState, to: state)
        let delay = isShrink ? Self.collapseSettleDelay : Self.expandSettleDelay
        let model = viewModel
        interactiveRectSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            model.interactiveRect = finalRect
        }
    }

    // MARK: Shape layer

    private var shape: NotchShape {
        switch viewModel.state {
        case .collapsed: return .collapsed
        case .activity: return .activity
        case .expanded: return .expanded
        }
    }

    private var isCollapsed: Bool { viewModel.state == .collapsed }

    private func shapeLayer(panelWidth: CGFloat) -> some View {
        let frame = rect(for: viewModel.state, panelWidth: panelWidth)
        return shape.fill(isCollapsed ? NotchDesign.physicalNotchFill : NotchDesign.panelFill)
            .frame(width: frame.width, height: frame.height)
            .compositingGroup()
            .shadow(color: isCollapsed ? .clear : NotchTheme.notchShadowColor,
                    radius: isCollapsed ? 0 : 12,
                    y: isCollapsed ? 0 : 4)
            .overlay(contentLayer)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: Content layer

    @ViewBuilder
    private var contentLayer: some View {
        switch viewModel.state {
        case .collapsed:
            EmptyView()
        case .activity:
            activityContent
        case .expanded(let widget):
            expandedContent(for: widget)
        }
    }

    private struct ExpandedChrome: ViewModifier {
        let topInset: CGFloat

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                .padding(.bottom, 14)
        }
    }

    private struct ExpandedContentTransition: ViewModifier, Animatable {
        var progress: Double

        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            content
                .opacity(progress)
                .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
        }
    }

    private static var expandedContentMorph: AnyTransition {
        AnyTransition.modifier(active: ExpandedContentTransition(progress: 0),
                               identity: ExpandedContentTransition(progress: 1))
    }

    private var activityContent: some View {
        let tint = viewModel.activity?.tint ?? .normal
        return HStack(spacing: 0) {
            wing(viewModel.activity?.leading ?? .none, tint: tint)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
            Spacer(minLength: notchSize.width)
            wing(viewModel.activity?.trailing ?? .none, tint: tint)
                .frame(width: NotchMetrics.wingWidth, height: notchSize.height)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .transition(.opacity)
    }

    private func expandedContent(for widget: FluxCore.Widget) -> some View {
        let finalSize = size(for: .expanded(widget))
        return Group {
            if isDuoLayout(for: widget), viewModel.widgets.contains(.calendar) {
                duoContent(nowPlaying: viewModel.widgetContent?(widget),
                           calendar: viewModel.widgetContent?(.calendar))
            } else if let content = viewModel.widgetContent?(widget) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(ExpandedChrome(topInset: notchSize.height))
        .frame(width: finalSize.width, height: finalSize.height, alignment: .top)
        .animation(nil, value: finalSize)
        .frame(width: containerSize.width, height: containerSize.height, alignment: .top)
        .clipped()
        .transition(Self.expandedContentMorph)
    }

    private func duoContent(nowPlaying: AnyView?, calendar: AnyView?) -> some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let calendarWidth = (availableWidth * NotchMetrics.duoCalendarPaneFraction).rounded()
            let dividerWidth: CGFloat = 1
            let nowPlayingWidth = max(0, availableWidth - calendarWidth - dividerWidth)
            HStack(spacing: 0) {
                Group {
                    if let nowPlaying { nowPlaying } else { Color.clear }
                }
                .environment(\.isNarrowPane, true)
                .padding(.trailing, NotchDesign.paneInsets)
                .frame(width: nowPlayingWidth, height: proxy.size.height, alignment: .topLeading)
                .clipped()

                Rectangle()
                    .fill(NotchDesign.hairlineColor)
                    .frame(width: dividerWidth)
                    .padding(.vertical, 12)

                Group {
                    if let calendar { calendar } else { Color.clear }
                }
                .environment(\.isNarrowPane, true)
                .frame(width: calendarWidth, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            }
            .frame(width: availableWidth, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .clipped()
    }

    /// One activity wing. Monochrome, except the warning tint.
    @ViewBuilder
    private func wing(_ value: ActivityWing, tint: ActivityTint) -> some View {
        let tintColor = tint == .warning ? NotchTheme.warningColor : NotchDesign.primaryColor
        switch value {
        case .none:
            EmptyView()
        case .symbol(let systemName):
            Image(systemName: systemName)
                .foregroundStyle(tintColor)
        case .text(let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
                .lineLimit(1)
        case .symbolText(let systemName, let text):
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
        case .soundGauge(let value, let systemName):
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
                SoundVisualizer(level: value)
            }
            .foregroundStyle(NotchDesign.primaryColor)
        case .artwork:
            if let image = viewModel.activityArtwork {
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

private struct SoundVisualizer: View {
    let level: Double

    var body: some View {
        let clamped = CGFloat(min(max(level, 0), 1))
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let amplitude = max(CGFloat(0.2), min(CGFloat(1), clamped * 1.35 - CGFloat(index) * 0.12))
                Capsule()
                    .fill(NotchDesign.primaryColor.opacity(0.35 + amplitude * 0.65))
                    .frame(width: 2.5, height: 3 + amplitude * 10)
                    .animation(.spring(response: 0.22, dampingFraction: 0.8)
                        .delay(Double(index) * 0.012), value: clamped)
            }
        }
        .frame(width: 25, height: 15)
        .accessibilityHidden(true)
    }
}

/// The shape's footprint for each state, in the panel's top-left space.
/// Top-anchored and centered, except the exact physical notch when closed.
public enum NotchLayout {
    public static func size(for state: NotchState, notchSize: CGSize, collapsedFrame: CGRect?, duo: Bool) -> CGSize {
        switch state {
        case .collapsed:
            if let collapsedFrame, collapsedFrame.width > 0, collapsedFrame.height > 0 { return collapsedFrame.size }
            return notchSize
        case .activity:
            return CGSize(width: notchSize.width + NotchMetrics.wingWidth * 2, height: max(notchSize.height, 32))
        case .expanded(let widget):
            if widget == .nowPlaying, duo {
                return CGSize(width: NotchMetrics.duoWidth(for: notchSize.width),
                              height: NotchMetrics.duoHeight(for: notchSize.width))
            }
            return CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width),
                          height: NotchMetrics.expandedHeight(for: notchSize.width))
        }
    }

    public static func rect(for state: NotchState, panelWidth: CGFloat, notchSize: CGSize,
                            collapsedFrame: CGRect?, duo: Bool) -> CGRect {
        if case .collapsed = state, let collapsedFrame, collapsedFrame.width > 0, collapsedFrame.height > 0 {
            return collapsedFrame
        }
        let size = size(for: state, notchSize: notchSize, collapsedFrame: collapsedFrame, duo: duo)
        return CGRect(origin: CGPoint(x: (panelWidth - size.width) / 2, y: 0), size: size)
    }
}

/// Supplies a widget's SwiftUI content to the notch root view.
@MainActor
public protocol NotchContentProviding: AnyObject {
    func notchContent() -> AnyView
}

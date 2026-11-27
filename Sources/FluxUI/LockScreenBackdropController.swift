import AppKit
import SwiftUI

/// Parent-driven controller for the mouse-transparent full-screen lock-screen
/// backdrop, Liquid Glass clock, and Vision depth-effect foreground layer.
@MainActor
public final class LockScreenBackdropController: NSViewController {
    public static let identifier = "flux.lockScreen.backdrop"

    public private(set) var state: LockScreenBackdropState
    let model: LockScreenBackdropModel

    public init(state: LockScreenBackdropState = .empty) {
        self.state = state
        self.model = LockScreenBackdropModel(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let host = LockScreenBackdropHostingView(model: model)
        host.setAccessibilityIdentifier(Self.identifier)
        view = host
    }

    public func update(_ newState: LockScreenBackdropState) {
        guard newState != state else { return }
        state = newState
        model.update(newState)
    }

    public var isFixtureRender: Bool {
        get { model.isFixtureRender }
        set { model.isFixtureRender = newValue }
    }

    /// Pre-renders the Metal Liquid Glass clock texture for the current time into
    /// `LiquidGlassRenderer.shared` so the first lock or wake frame never stalls.
    public static func prewarmClock(for state: LockScreenBackdropState, screenSize: CGSize) {
        guard let backdrop = state.backdrop, screenSize.width > 0, screenSize.height > 0 else { return }
        let layout = LockScreenBackdropView.ClockLayout(screenSize: screenSize)
        let timeText = LockScreenBackdropView.formatTime(state.fixedDate ?? Date())
        _ = LiquidGlassRenderer.shared.renderClockGlass(
            sourceKey: state.sourceKey,
            backdrop: backdrop,
            canvasSizePt: screenSize,
            clockRectTopLeftPt: layout.clockRect,
            timeText: timeText,
            fontSize: layout.clockFontSize
        )
    }
}

@MainActor
final class LockScreenBackdropModel: ObservableObject {
    @Published private(set) var state: LockScreenBackdropState
    @Published var isFixtureRender = false

    init(state: LockScreenBackdropState) {
        self.state = state
    }

    func update(_ newState: LockScreenBackdropState) {
        state = newState
    }
}

/// Strictly non-interactive backdrop view so clicks, password entry, and Touch
/// ID always belong to macOS.
@MainActor
final class LockScreenBackdropHostingView: NSHostingView<AnyView> {
    init(model: LockScreenBackdropModel) {
        super.init(rootView: AnyView(LockScreenBackdropView(model: model)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(*, unavailable)
    required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

import AppKit
import FluxCore
import QuartzCore
import SwiftUI

// Lock-screen content views. Pure AppKit, parent driven.
//
// The parent owns both windows, the private presentation bridge, lock and
// unlock events, media reads, the playback clock and every command. These
// views own no window, timer, monitor, camera, network or permission code.
// The saved `flux.notch.lockScreen.nowPlaying` and `.activities` switches
// decide what the parent puts in `LockScreenContentState`. Nothing here claims
// that a private lock-screen presentation works on a given macOS release.

/// Sizes kept from the old lock-screen flow.
public enum LockScreenMetrics {
    public static let mediaWidth: CGFloat = 348
    public static let mediaCardHeight: CGFloat = 164
    public static let activityOnlyWidth: CGFloat = 240
    public static let captionHeight: CGFloat = 38
    public static let cardCornerRadius: CGFloat = 24
    public static let artworkSide: CGFloat = 64
    public static let artworkCornerRadius: CGFloat = 14
    /// Space between the media card and the caption under it.
    public static let captionGap: CGFloat = 8

    /// The card window size. `.zero` when there is nothing to show, so the
    /// parent can order the card window out and leave no mouse surface.
    public static func size(hasMedia: Bool, hasActivity: Bool) -> CGSize {
        switch (hasMedia, hasActivity) {
        case (true, true): CGSize(width: mediaWidth, height: mediaCardHeight + captionGap + captionHeight)
        case (true, false): CGSize(width: mediaWidth, height: mediaCardHeight)
        case (false, true): CGSize(width: activityOnlyWidth, height: captionHeight)
        case (false, false): .zero
        }
    }
}

/// One line under the media card, or alone. Battery notices stay out: the
/// parent sends nil for them, as the old flow did.
public struct LockScreenActivityCaption: Equatable, Sendable {
    /// An SF Symbol name, or nil for text only.
    public var symbolName: String?
    public var text: String

    public init(symbolName: String? = nil, text: String) {
        self.symbolName = symbolName
        self.text = text
    }
}

/// Everything the card shows. Media shows only for `.playing` and `.paused`.
public struct LockScreenContentState: Equatable {
    public var media: NowPlayingWidgetState?
    public var activity: LockScreenActivityCaption?

    public init(media: NowPlayingWidgetState? = nil, activity: LockScreenActivityCaption? = nil) {
        self.media = media
        self.activity = activity
    }

    public static var empty: LockScreenContentState { LockScreenContentState() }

    public var showsMedia: Bool {
        guard let media else { return false }
        return media.status == .playing || media.status == .paused
    }

    public var showsActivity: Bool {
        guard let activity else { return false }
        return !activity.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isEmpty: Bool { !showsMedia && !showsActivity }
    public var preferredSize: CGSize { LockScreenMetrics.size(hasMedia: showsMedia, hasActivity: showsActivity) }
}

/// The only lock-screen commands. No source picker and no app launch.
public enum LockScreenTransportAction: Equatable, Sendable {
    case previous
    case togglePlayPause
    case next
    /// Sent once, when the user releases the slider. Seconds from the start.
    case seek(TimeInterval)
}

// MARK: Silhouette

/// Black camera-housing shape at the physical notch size: the 0.21.35
/// `LockScreenContentView` (`NotchShape.collapsed`, black, top aligned). It
/// never takes a mouse event and VoiceOver skips it.
@MainActor
public final class LockScreenSilhouetteView: NSView {
    public static let identifier = "flux.lockScreen.silhouette"
    private let shape = CAShapeLayer()

    public var notchSize: CGSize {
        didSet {
            guard notchSize != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// At least 1 x 8 pt, as the old flow drew it.
    public var preferredSize: CGSize {
        CGSize(width: max(notchSize.width, 1), height: max(notchSize.height, 8))
    }

    public init(notchSize: CGSize) {
        self.notchSize = CGSize(width: max(0, notchSize.width), height: max(0, notchSize.height))
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: max(notchSize.width, 1), height: max(notchSize.height, 8))))
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        setAccessibilityElement(false)
        setAccessibilityIdentifier(Self.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var intrinsicContentSize: NSSize { preferredSize }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override public func isAccessibilityElement() -> Bool { false }

    override public func layout() {
        super.layout()
        let size = preferredSize
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = NotchShape.collapsed.path(in: rect).cgPath
        CATransaction.commit()
    }
}

// MARK: Card

/// Card-sized lock-screen content: the 0.21.35 `LockScreenMediaControlsView`.
/// Call `update(_:)` with new parent state. Read `preferredSize` after each
/// update and size the card window to it. When `isEmpty` is true the root has
/// no hit area and no VoiceOver element.
@MainActor
public final class LockScreenContentController: NSViewController {
    public static let identifier = "flux.lockScreen.card"

    public private(set) var state: LockScreenContentState
    public var preferredSize: CGSize { state.preferredSize }
    public var isEmpty: Bool { state.isEmpty }
    public var showsMedia: Bool { isViewLoaded && state.showsMedia }
    public var showsActivity: Bool { isViewLoaded && state.showsActivity }
    let model: LockScreenCardModel

    public init(state: LockScreenContentState = .empty, onAction: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.state = state
        model = LockScreenCardModel(state: state, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let host = LockScreenCardHostingView(model: model)
        host.setAccessibilityIdentifier(Self.identifier)
        host.frame = NSRect(origin: .zero, size: state.preferredSize)
        view = host
    }

    public func update(_ newState: LockScreenContentState) {
        guard newState != state else { return }
        state = newState
        model.update(newState)
    }

    /// Offscreen fixtures have no wallpaper behind them, so they draw the
    /// material card instead of live glass, as the 0.21.35 snapshots did.
    public var isFixtureRender: Bool {
        get { model.isFixtureRender }
        set { model.isFixtureRender = newValue }
    }
}

@MainActor
final class LockScreenCardModel: ObservableObject {
    @Published private(set) var state: LockScreenContentState
    @Published var isFixtureRender = false
    private(set) var receivedAt = Date()
    let onAction: @MainActor (LockScreenTransportAction) -> Void

    init(state: LockScreenContentState, onAction: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.state = state
        self.onAction = onAction
    }

    func update(_ newState: LockScreenContentState) {
        receivedAt = Date()
        state = newState
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let media = state.media else { return 0 }
        guard media.status == .playing else { return media.elapsed }
        return media.elapsed + max(0, date.timeIntervalSince(receivedAt))
    }
}

/// Takes no click and exposes no element while the card is empty.
@MainActor
final class LockScreenCardHostingView: NSHostingView<AnyView> {
    private let model: LockScreenCardModel

    init(model: LockScreenCardModel) {
        self.model = model
        super.init(rootView: AnyView(LockScreenMediaControlsView(model: model)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(*, unavailable)
    required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        model.state.isEmpty ? nil : super.hitTest(point)
    }

    override func accessibilityChildren() -> [Any]? {
        model.state.isEmpty ? [] : super.accessibilityChildren()
    }

    override func isAccessibilityElement() -> Bool { false }
}

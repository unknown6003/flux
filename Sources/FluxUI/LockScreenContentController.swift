import AppKit
import FluxCore
import QuartzCore
import SwiftUI

// Lock-screen content views. Pure AppKit/SwiftUI, parent driven.
//
// The parent owns the windows, the private presentation bridge, lock and
// unlock events, media reads, the playback clock and every command. These
// views own no window, timer, monitor, camera, network or permission code.

/// Dimensions for the floating Liquid Glass lock-screen music player and pill.
public enum LockScreenMetrics {
    public static let mediaWidth: CGFloat = 348
    /// Matches the compact, balanced Liquid Glass lock-screen player proportions.
    public static let mediaCardHeight: CGFloat = 148
    public static let activityOnlyWidth: CGFloat = 240
    public static let captionHeight: CGFloat = 38
    public static let cardCornerRadius: CGFloat = 28
    public static let artworkSide: CGFloat = 64
    public static let artworkCornerRadius: CGFloat = 14
    /// Space between the media card and the caption under it.
    public static let captionGap: CGFloat = 8
    /// Additional vertical room when the inline audio-output picker is open.
    public static let outputPickerRowHeight: CGFloat = 30
    public static let outputPickerMaxRows: Int = 4

    /// The card window size. `.zero` when there is nothing to show, so the
    /// parent can order the card window out and leave no mouse surface.
    public static func size(hasMedia: Bool, hasActivity: Bool, expandedOutputCount: Int = 0) -> CGSize {
        let pickerExtra: CGFloat = expandedOutputCount > 0
            ? CGFloat(min(expandedOutputCount, outputPickerMaxRows)) * outputPickerRowHeight + 22
            : 0
        return switch (hasMedia, hasActivity) {
        case (true, true): CGSize(width: mediaWidth, height: mediaCardHeight + pickerExtra + captionGap + captionHeight)
        case (true, false): CGSize(width: mediaWidth, height: mediaCardHeight + pickerExtra)
        case (false, true): CGSize(width: activityOnlyWidth, height: captionHeight)
        case (false, false): .zero
        }
    }
}

/// One selectable audio output route displayed in the lock-screen player.
public struct LockScreenAudioDevice: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var symbolName: String
    public var isSelected: Bool

    public init(id: UInt32, name: String, symbolName: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isSelected = isSelected
    }
}

/// Audio mute + route state surfaced by the lock-screen player's corner buttons.
public struct LockScreenAudioOutputState: Equatable, Sendable {
    public var isMuted: Bool
    public var canMute: Bool
    public var currentSymbolName: String
    public var currentDeviceName: String
    public var devices: [LockScreenAudioDevice]

    public init(isMuted: Bool = false,
                canMute: Bool = true,
                currentSymbolName: String = "display",
                currentDeviceName: String = "Speakers",
                devices: [LockScreenAudioDevice] = []) {
        self.isMuted = isMuted
        self.canMute = canMute
        self.currentSymbolName = currentSymbolName
        self.currentDeviceName = currentDeviceName
        self.devices = devices
    }
}

/// One line under the media card, or alone. Battery notices stay out.
public struct LockScreenActivityCaption: Equatable, Sendable {
    /// An SF Symbol name, or nil for text only.
    public var symbolName: String?
    public var text: String

    public init(symbolName: String? = nil, text: String) {
        self.symbolName = symbolName
        self.text = text
    }
}

/// Everything the floating card shows. Media shows only for `.playing` and `.paused`.
public struct LockScreenContentState: Equatable {
    public var media: NowPlayingWidgetState?
    public var activity: LockScreenActivityCaption?
    public var audioOutput: LockScreenAudioOutputState?

    public init(media: NowPlayingWidgetState? = nil,
                activity: LockScreenActivityCaption? = nil,
                audioOutput: LockScreenAudioOutputState? = nil) {
        self.media = media
        self.activity = activity
        self.audioOutput = audioOutput
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

/// Interactive lock-screen player commands.
public enum LockScreenTransportAction: Equatable, Sendable {
    case previous
    case togglePlayPause
    case next
    /// Sent once, when the user releases the scrubber. Seconds from the start.
    case seek(TimeInterval)
    /// Toggles default audio output mute state.
    case toggleMute
    /// Switches the CoreAudio default output device to the given `AudioObjectID`.
    case selectAudioOutput(UInt32)
}

// MARK: Silhouette

/// Black camera-housing shape at the physical notch size. Used when the full-
/// screen minimal backdrop is disabled. Never takes a mouse event.
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

    /// At least 1 x 8 pt.
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

/// Card-sized lock-screen content hosting the Liquid Glass music player and
/// optional live activity pill.
@MainActor
public final class LockScreenContentController: NSViewController {
    public static let identifier = "flux.lockScreen.card"

    public private(set) var state: LockScreenContentState
    public var onPreferredSizeChange: (@MainActor (CGSize) -> Void)?
    public var preferredSize: CGSize {
        let pickerRows = model.isOutputPickerExpanded ? (state.audioOutput?.devices.count ?? 0) : 0
        return LockScreenMetrics.size(hasMedia: state.showsMedia,
                                      hasActivity: state.showsActivity,
                                      expandedOutputCount: pickerRows)
    }
    public var isEmpty: Bool { state.isEmpty }
    public var showsMedia: Bool { isViewLoaded && state.showsMedia }
    public var showsActivity: Bool { isViewLoaded && state.showsActivity }
    let model: LockScreenCardModel

    public init(state: LockScreenContentState = .empty, onAction: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.state = state
        let cardModel = LockScreenCardModel(state: state, onAction: onAction)
        model = cardModel
        super.init(nibName: nil, bundle: nil)
        cardModel.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.onPreferredSizeChange?(self.preferredSize)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let host = LockScreenCardHostingView(model: model)
        host.setAccessibilityIdentifier(Self.identifier)
        host.frame = NSRect(origin: .zero, size: preferredSize)
        view = host
    }

    public func update(_ newState: LockScreenContentState) {
        guard newState != state else { return }
        state = newState
        if !newState.showsMedia { model.isOutputPickerExpanded = false }
        model.update(newState)
    }

    /// Offscreen fixtures have no live WindowServer backdrop behind them, so
    /// they use the translucent material fallback instead of `.glassEffect`.
    public var isFixtureRender: Bool {
        get { model.isFixtureRender }
        set { model.isFixtureRender = newValue }
    }
}

@MainActor
final class LockScreenCardModel: ObservableObject {
    @Published private(set) var state: LockScreenContentState
    @Published var isFixtureRender = false
    @Published var isOutputPickerExpanded = false {
        didSet {
            if isOutputPickerExpanded != oldValue { onLayoutChange?() }
        }
    }
    private(set) var receivedAt = Date()
    let onAction: @MainActor (LockScreenTransportAction) -> Void
    var onLayoutChange: (@MainActor () -> Void)?

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

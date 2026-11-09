import AppKit
import FluxCore
import QuartzCore

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

/// Black camera-housing shape at the physical notch size. It never takes a
/// mouse event and VoiceOver skips it. The parent puts it in its own
/// mouse-transparent window over the notch.
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
        shape.path = NotchShapeView.path(in: rect, radius: min(10, size.height / 2))
        CATransaction.commit()
    }
}

// MARK: Card

/// Card-sized lock-screen content: optional media controls and an optional
/// activity caption. Call `update(_:)` with new parent state; views change in
/// place. Read `preferredSize` after each update and size the card window to
/// it. When `isEmpty` is true the root has no hit area and no VoiceOver
/// element, and the parent should order the card window out.
@MainActor
public final class LockScreenContentController: NSViewController {
    public static let identifier = "flux.lockScreen.card"

    public private(set) var state: LockScreenContentState
    public var preferredSize: CGSize { state.preferredSize }
    public var isEmpty: Bool { state.isEmpty }
    /// Readback for tests and captures.
    public var showsMedia: Bool { isViewLoaded && !mediaCard.isHidden }
    public var showsActivity: Bool { isViewLoaded && !caption.isHidden }

    private let onAction: @MainActor (LockScreenTransportAction) -> Void

    private let stack = NSStackView()
    private let mediaCard = LockScreenGlassView(cornerRadius: LockScreenMetrics.cardCornerRadius)
    private let artwork = NSImageView()
    private let titleLabel = FluxUIStyle.label("", style: .headline, wraps: false)
    private let artistLabel = FluxUIStyle.label("", style: .subheadline, secondary: true, wraps: false)
    private let stateIcon = NSImageView()
    private let elapsedLabel = FluxUIStyle.label("0:00", style: .caption2, secondary: true, wraps: false)
    private let remainingLabel = FluxUIStyle.label("", style: .caption2, secondary: true, wraps: false)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private lazy var previousButton = NotchWidgetStyle.iconButton("backward.end.fill", label: L("lock.previous", "Previous track"), size: 16, target: self, action: #selector(previous))
    private lazy var playButton = NotchWidgetStyle.iconButton("play.fill", label: L("lock.play", "Play"), size: 15, target: self, action: #selector(togglePlay))
    private lazy var nextButton = NotchWidgetStyle.iconButton("forward.end.fill", label: L("lock.next", "Next track"), size: 16, target: self, action: #selector(next))
    private let caption = LockScreenGlassView(cornerRadius: LockScreenMetrics.captionHeight / 2)
    private let captionIcon = NSImageView()
    private let captionLabel = FluxUIStyle.label("", style: .body, wraps: false)
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    public init(state: LockScreenContentState = .empty, onAction: @escaping @MainActor (LockScreenTransportAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = LockScreenRootView()
        root.setAccessibilityIdentifier(Self.identifier)
        root.setAccessibilityRole(.group)

        buildMediaCard()
        buildCaption()

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = LockScreenMetrics.captionGap
        stack.detachesHiddenViews = true
        stack.addArrangedSubview(mediaCard)
        stack.addArrangedSubview(caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let width = root.widthAnchor.constraint(equalToConstant: 0)
        let height = root.heightAnchor.constraint(equalToConstant: 0)
        widthConstraint = width
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            width, height,
        ])
        view = root
        apply(animated: false)
    }

    /// Replaces the shown state in place. Focus stays on the same button
    /// when that button is still shown.
    public func update(_ newState: LockScreenContentState) {
        guard newState != state else { return }
        let structural = newState.showsMedia != state.showsMedia || newState.showsActivity != state.showsActivity
        state = newState
        guard isViewLoaded else { return }
        apply(animated: structural)
    }

    // MARK: Build

    private func buildMediaCard() {
        mediaCard.setAccessibilityElement(true)
        mediaCard.setAccessibilityRole(.group)
        mediaCard.setAccessibilityIdentifier("flux.lockScreen.media")
        mediaCard.setAccessibilityLabel(L("lock.media", "Lock Screen Now Playing"))

        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = LockScreenMetrics.artworkCornerRadius
        artwork.layer?.cornerCurve = .continuous
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        artwork.contentTintColor = .secondaryLabelColor
        artwork.setAccessibilityElement(false)
        stateIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        stateIcon.contentTintColor = .secondaryLabelColor
        stateIcon.setAccessibilityElement(false)
        for view in [artwork, stateIcon] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: LockScreenMetrics.artworkSide),
            artwork.heightAnchor.constraint(equalToConstant: LockScreenMetrics.artworkSide),
        ])
        NotchWidgetStyle.fillWidth(titleLabel, artistLabel)
        let text = FluxUIStyle.vstack([titleLabel, artistLabel], spacing: 3)
        let header = FluxUIStyle.hstack([artwork, text, stateIcon], spacing: 12)
        header.alignment = .centerY

        slider.target = self
        slider.action = #selector(seek)
        slider.isContinuous = false
        slider.controlSize = .mini
        slider.setAccessibilityIdentifier("flux.lockScreen.seek")
        slider.setAccessibilityLabel(L("lock.position", "Playback position"))
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        remainingLabel.alignment = .right
        for label in [elapsedLabel, remainingLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 38).isActive = true
            label.setAccessibilityElement(false)
        }
        let progress = FluxUIStyle.hstack([elapsedLabel, slider, remainingLabel], spacing: 7)
        progress.alignment = .centerY

        previousButton.setAccessibilityIdentifier("flux.lockScreen.previous")
        playButton.setAccessibilityIdentifier("flux.lockScreen.playPause")
        nextButton.setAccessibilityIdentifier("flux.lockScreen.next")
        playButton.wantsLayer = true
        playButton.layer?.cornerRadius = 19
        playButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playButton.widthAnchor.constraint(equalToConstant: 38),
            playButton.heightAnchor.constraint(equalToConstant: 38),
        ])
        let transport = NotchWidgetStyle.centered([previousButton, playButton, nextButton], spacing: 24)

        let column = FluxUIStyle.vstack([header, progress, transport], spacing: 6)
        column.translatesAutoresizingMaskIntoConstraints = false
        mediaCard.addSubview(column)
        mediaCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mediaCard.widthAnchor.constraint(equalToConstant: LockScreenMetrics.mediaWidth),
            mediaCard.heightAnchor.constraint(equalToConstant: LockScreenMetrics.mediaCardHeight),
            column.leadingAnchor.constraint(equalTo: mediaCard.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: mediaCard.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: mediaCard.topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: mediaCard.bottomAnchor, constant: -10),
        ])
    }

    private func buildCaption() {
        caption.setAccessibilityElement(true)
        caption.setAccessibilityRole(.staticText)
        caption.setAccessibilityIdentifier("flux.lockScreen.activity")
        captionIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        captionIcon.contentTintColor = .labelColor
        captionIcon.setAccessibilityElement(false)
        captionLabel.setAccessibilityElement(false)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        captionIcon.translatesAutoresizingMaskIntoConstraints = false
        let row = FluxUIStyle.hstack([captionIcon, captionLabel], spacing: 8)
        row.alignment = .centerY
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        caption.addSubview(row)
        caption.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            captionIcon.widthAnchor.constraint(equalToConstant: 24),
            captionIcon.heightAnchor.constraint(equalToConstant: 24),
            caption.heightAnchor.constraint(equalToConstant: LockScreenMetrics.captionHeight),
            caption.widthAnchor.constraint(lessThanOrEqualToConstant: LockScreenMetrics.mediaWidth),
            caption.widthAnchor.constraint(greaterThanOrEqualToConstant: LockScreenMetrics.captionHeight),
            row.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: caption.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: caption.trailingAnchor, constant: -12),
        ])
    }

    // MARK: Apply

    private func apply(animated: Bool) {
        let focused = view.window?.firstResponder
        let showsMedia = state.showsMedia
        let showsActivity = state.showsActivity
        if let media = state.media, showsMedia { applyMedia(media) }
        if let activity = state.activity, showsActivity { applyActivity(activity) }
        mediaCard.isHidden = !showsMedia
        caption.isHidden = !showsActivity
        // Activity alone keeps the old 240 pt width.
        caption.maximumWidth = showsMedia ? LockScreenMetrics.mediaWidth : LockScreenMetrics.activityOnlyWidth

        let size = state.preferredSize
        widthConstraint?.constant = size.width
        heightConstraint?.constant = size.height
        preferredContentSize = size

        let root = view as? LockScreenRootView
        root?.isInteractive = !state.isEmpty
        view.setAccessibilityLabel(showsMedia ? L("lock.media", "Lock Screen Now Playing")
                                   : L("lock.activity", "Lock Screen Activity"))
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            view.layer?.add(fade, forKey: nil)
        }
        NotchWidgetStyle.restoreFocus(focused, in: view.window)
    }

    private func applyMedia(_ media: NowPlayingWidgetState) {
        let title = media.title.isEmpty ? L("lock.unknownTitle", "Unknown title") : media.title
        titleLabel.stringValue = title
        artistLabel.stringValue = media.artist
        artistLabel.isHidden = media.artist.isEmpty
        if let image = media.artwork {
            artwork.image = image
            artwork.imageScaling = .scaleProportionallyUpOrDown
        } else {
            artwork.image = FluxUIStyle.symbol("music.note", label: "")
            artwork.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            artwork.imageScaling = .scaleNone
        }
        let playing = media.status == .playing
        stateIcon.image = FluxUIStyle.symbol(playing ? "waveform" : "music.note", label: "")
        NotchWidgetStyle.setSymbol(playButton, playing ? "pause.fill" : "play.fill",
                                   label: playing ? L("lock.pause", "Pause") : L("lock.play", "Play"))
        playButton.contentTintColor = NSColor.windowBackgroundColor
        playButton.layer?.backgroundColor = NSColor.labelColor.cgColor
        previousButton.isEnabled = media.canGoPrevious
        nextButton.isEnabled = media.canGoNext

        let artist = media.artist.isEmpty ? "" : ", \(media.artist)"
        mediaCard.setAccessibilityLabel(L("lock.media", "Lock Screen Now Playing") + ": \(title)\(artist)")

        if let duration = media.duration, duration.isFinite, duration > 0 {
            let elapsed = media.elapsed.isFinite ? min(max(0, media.elapsed), duration) : 0
            slider.isEnabled = true
            slider.maxValue = duration
            // Do not move the knob under a drag in progress.
            if !slider.isHighlighted { slider.doubleValue = elapsed }
            elapsedLabel.stringValue = NotchWidgetStyle.clock(elapsed)
            remainingLabel.stringValue = "-" + NotchWidgetStyle.clock(duration - elapsed)
            slider.setAccessibilityValueDescription(
                "\(NotchWidgetStyle.clock(elapsed)) / \(NotchWidgetStyle.clock(duration))")
        } else {
            slider.isEnabled = false
            slider.maxValue = 1
            slider.doubleValue = 0
            elapsedLabel.stringValue = ""
            remainingLabel.stringValue = ""
        }
    }

    private func applyActivity(_ activity: LockScreenActivityCaption) {
        captionLabel.stringValue = activity.text
        caption.setAccessibilityLabel(activity.text)
        if let name = activity.symbolName, let image = FluxUIStyle.symbol(name, label: "") {
            captionIcon.image = image
            captionIcon.isHidden = false
        } else {
            captionIcon.image = nil
            captionIcon.isHidden = true
        }
    }

    // MARK: Actions

    @objc private func previous() { send(.previous) }
    @objc private func togglePlay() { send(.togglePlayPause) }
    @objc private func next() { send(.next) }
    @objc private func seek() {
        guard slider.isEnabled else { return }
        send(.seek(slider.doubleValue))
    }

    private func send(_ action: LockScreenTransportAction) {
        guard state.showsMedia else { return }
        onAction(action)
    }
}

/// Clear root. With empty content it is not a hit target and not a
/// VoiceOver element, so the card window cannot block the login controls.
@MainActor
final class LockScreenRootView: NSView {
    var isInteractive = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        let hit = super.hitTest(point)
        // Clear space between the card and the caption passes clicks through.
        return hit === self ? nil : hit
    }
    override func isAccessibilityElement() -> Bool { isInteractive }
    override func accessibilityChildren() -> [Any]? { isInteractive ? super.accessibilityChildren() : [] }
}

/// A rounded system-material surface with a hairline edge.
@MainActor
final class LockScreenGlassView: NSVisualEffectView {
    var maximumWidth: CGFloat = LockScreenMetrics.mediaWidth {
        didSet { maxWidth?.constant = maximumWidth }
    }
    private var maxWidth: NSLayoutConstraint?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        let limit = widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth)
        limit.isActive = true
        maxWidth = limit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

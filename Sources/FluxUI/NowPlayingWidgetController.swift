import AppKit
import FluxCore

/// An app that can play media, shown in the source menu.
public struct NowPlayingSourceOption: Equatable, Sendable {
    public var id: ApplicationID
    public var name: String

    public init(id: ApplicationID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum NowPlayingWidgetStatus: Equatable, Sendable {
    /// The parent has not got its first media read yet. The widget shows a
    /// fixed "Loading" card with no button and no error.
    case loading
    case playing
    case paused
    /// No source has media. The widget shows "Nothing playing" and Check Again.
    case empty
    /// The parent cannot read media state. The widget shows Check Again.
    case noAccess
}

/// Everything the Now Playing widget shows. The parent owns the clock:
/// it sends a new `elapsed` when it wants the time to move.
public struct NowPlayingWidgetState: Equatable {
    public var status: NowPlayingWidgetStatus
    public var title: String
    public var artist: String
    public var artwork: NSImage?
    public var sources: [NowPlayingSourceOption]
    public var selectedSource: ApplicationID?
    /// Seconds. Ignored when `duration` is nil.
    public var elapsed: TimeInterval
    /// Seconds. Nil or 0 turns the seek slider off.
    public var duration: TimeInterval?
    public var canGoPrevious: Bool
    public var canGoNext: Bool

    public init(status: NowPlayingWidgetStatus, title: String = "", artist: String = "", artwork: NSImage? = nil,
                sources: [NowPlayingSourceOption] = [], selectedSource: ApplicationID? = nil,
                elapsed: TimeInterval = 0, duration: TimeInterval? = nil,
                canGoPrevious: Bool = true, canGoNext: Bool = true) {
        self.status = status
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.sources = sources
        self.selectedSource = selectedSource
        self.elapsed = elapsed
        self.duration = duration
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
    }

    public static var empty: NowPlayingWidgetState { NowPlayingWidgetState(status: .empty) }
}

public enum NowPlayingWidgetAction: Equatable, Sendable {
    case togglePlayPause
    case previous
    case next
    /// Sent once, when the user releases the slider. Seconds from the start.
    case seek(TimeInterval)
    case selectSource(ApplicationID)
    case openSource
    /// From the empty and no-access states.
    case checkAgain
}

/// The Now Playing notch widget. It only shows state and sends actions.
/// It reads no media, runs no timer and never changes state by itself.
@MainActor
public final class NowPlayingWidgetController: NSViewController {
    public private(set) var state: NowPlayingWidgetState
    private let onAction: @MainActor (NowPlayingWidgetAction) -> Void
    private var isApplying = false
    private var shownSources: [NowPlayingSourceOption] = []

    private let content = NSStackView()
    private let artwork = NSImageView()
    private let titleLabel = FluxUIStyle.label("", style: .headline, wraps: false)
    private let artistLabel = FluxUIStyle.label("", style: .subheadline, secondary: true, wraps: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var openButton = NotchWidgetStyle.iconButton("laptopcomputer", label: L("nowPlaying.open", "Open the app that\u{2019}s playing"), size: 15, target: self, action: #selector(openSource))
    private let elapsedLabel = FluxUIStyle.label("0:00", style: .caption1, secondary: true, wraps: false)
    private let remainingLabel = FluxUIStyle.label("", style: .caption1, secondary: true, wraps: false)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private lazy var previousButton = NotchWidgetStyle.iconButton("backward.fill", label: L("nowPlaying.previous", "Previous track"), size: 15, target: self, action: #selector(previous))
    private lazy var playButton = NotchWidgetStyle.iconButton("play.fill", label: L("nowPlaying.play", "Play"), size: 20, target: self, action: #selector(togglePlay))
    private lazy var nextButton = NotchWidgetStyle.iconButton("forward.fill", label: L("nowPlaying.next", "Next track"), size: 15, target: self, action: #selector(next))
    private let card = NotchCardHost()

    public init(state: NowPlayingWidgetState = .empty, onAction: @escaping @MainActor (NowPlayingWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = NotchWidgetStyle.root()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(Widget.nowPlaying.displayName)

        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        artwork.setAccessibilityElement(false)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 48),
            artwork.heightAnchor.constraint(equalToConstant: 48),
        ])

        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.controlSize = .small
        sourcePopup.setAccessibilityLabel(L("nowPlaying.source", "Source"))
        sourcePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        NotchWidgetStyle.fillWidth(titleLabel, artistLabel)
        let texts = FluxUIStyle.vstack([titleLabel, artistLabel], spacing: 2)
        let header = FluxUIStyle.hstack([artwork, texts, FluxUIStyle.spacer(), sourcePopup, openButton], spacing: 10)

        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(seek)
        slider.controlSize = .small
        slider.setAccessibilityLabel(L("nowPlaying.position", "Playback position"))
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        remainingLabel.font = elapsedLabel.font
        elapsedLabel.setAccessibilityElement(false)
        remainingLabel.setAccessibilityElement(false)
        for label in [elapsedLabel, remainingLabel] { label.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let progress = FluxUIStyle.hstack([elapsedLabel, slider, remainingLabel], spacing: 8)

        let transport = NotchWidgetStyle.centered([previousButton, playButton, nextButton], spacing: 18)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        for view in [header, progress, transport] {
            content.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        NotchWidgetStyle.pinTop(FluxUIStyle.vstack([content, card], spacing: 0), in: root)
        view = root
        apply()
    }

    /// Replaces the state. Controls are updated in place, so keyboard focus stays.
    public func update(_ newState: NowPlayingWidgetState) {
        state = newState
        if isViewLoaded { apply() }
    }

    private func apply() {
        let focus = view.window?.firstResponder
        isApplying = true
        defer {
            isApplying = false
            NotchWidgetStyle.restoreFocus(focus, in: view.window)
        }

        switch state.status {
        case .loading:
            showCard("loading", .init(symbolName: "music.note", title: L("nowPlaying.loading", "Loading\u{2026}"),
                           message: L("nowPlaying.loading.message", "Flux is reading what\u{2019}s playing.")))
            return
        case .empty:
            showCard("empty", .init(symbolName: "music.note", title: L("nowPlaying.empty", "Nothing playing"),
                           message: L("nowPlaying.empty.message", "Play something in a music or video app."),
                           actionTitle: L("nowPlaying.checkAgain", "Check Again")))
            return
        case .noAccess:
            showCard("noAccess", .init(symbolName: "music.note", title: L("nowPlaying.noAccess", "Flux can\u{2019}t read what\u{2019}s playing"),
                           message: L("nowPlaying.noAccess.message", "macOS didn\u{2019}t share media details with Flux."),
                           actionTitle: L("nowPlaying.checkAgain", "Check Again")))
            return
        case .playing, .paused:
            card.hide()
            content.isHidden = false
        }

        let title = state.title.isEmpty ? L("nowPlaying.untitled", "Unknown title") : state.title
        titleLabel.stringValue = title
        artistLabel.stringValue = state.artist
        artistLabel.isHidden = state.artist.isEmpty
        artwork.image = state.artwork ?? FluxUIStyle.symbol("music.note", label: "")
        artwork.contentTintColor = .secondaryLabelColor

        if state.sources != shownSources {
            shownSources = state.sources
            sourcePopup.removeAllItems()
            for source in state.sources {
                sourcePopup.addItem(withTitle: source.name)
                sourcePopup.lastItem?.representedObject = source.id.rawValue
            }
        }
        sourcePopup.isHidden = state.sources.count < 2
        if let selected = state.selectedSource, let index = state.sources.firstIndex(where: { $0.id == selected }) {
            sourcePopup.selectItem(at: index)
        }
        openButton.isEnabled = state.selectedSource != nil

        let playing = state.status == .playing
        NotchWidgetStyle.setSymbol(playButton, playing ? "pause.fill" : "play.fill",
                                   label: playing ? L("nowPlaying.pause", "Pause") : L("nowPlaying.play", "Play"))
        previousButton.isEnabled = state.canGoPrevious
        nextButton.isEnabled = state.canGoNext

        let duration = state.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        slider.isEnabled = duration != nil
        remainingLabel.isHidden = duration == nil
        elapsedLabel.isHidden = duration == nil
        if let duration {
            let elapsed = min(max(0, state.elapsed.isFinite ? state.elapsed : 0), duration)
            slider.maxValue = duration
            slider.doubleValue = elapsed
            elapsedLabel.stringValue = NotchWidgetStyle.clock(elapsed)
            remainingLabel.stringValue = "-" + NotchWidgetStyle.clock(duration - elapsed)
            slider.setAccessibilityValueDescription(String(format: L("nowPlaying.position.value", "%@ of %@"),
                                                           NotchWidgetStyle.clock(elapsed), NotchWidgetStyle.clock(duration)))
        } else {
            slider.doubleValue = 0
        }

        let summary = state.artist.isEmpty ? title : "\(title), \(state.artist)"
        view.setAccessibilityLabel("\(Widget.nowPlaying.displayName): \(summary)")
    }

    private func showCard(_ key: String, _ content: PermissionCardView.Content) {
        let action: (() -> Void)? = content.actionTitle == nil ? nil : { [weak self] in self?.send(.checkAgain) }
        card.show(key: key, content, onAction: action)
        self.content.isHidden = true
        view.setAccessibilityLabel("\(Widget.nowPlaying.displayName): \(content.title)")
    }

    private func send(_ action: NowPlayingWidgetAction) {
        guard !isApplying else { return }
        onAction(action)
    }

    @objc private func togglePlay() { send(.togglePlayPause) }
    @objc private func previous() { send(.previous) }
    @objc private func next() { send(.next) }
    @objc private func openSource() { send(.openSource) }
    @objc private func seek() { send(.seek(slider.doubleValue)) }

    @objc private func sourceChanged() {
        guard let raw = sourcePopup.selectedItem?.representedObject as? String,
              let id = ApplicationID(rawValue: raw), id != state.selectedSource else { return }
        send(.selectSource(id))
    }
}

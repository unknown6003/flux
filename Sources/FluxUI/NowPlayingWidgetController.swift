import AppKit
import FluxCore
import SwiftUI

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

/// The Now Playing notch widget: the 0.21.35 SwiftUI player. It only shows
/// state and sends actions. Elapsed time moves from the last `update`.
@MainActor
public final class NowPlayingWidgetController: NSViewController, NotchContentProviding {
    public private(set) var state: NowPlayingWidgetState
    let model: NowPlayingNotchModel

    public init(state: NowPlayingWidgetState = .empty, onAction: @escaping @MainActor (NowPlayingWidgetAction) -> Void) {
        self.state = state
        model = NowPlayingNotchModel(state: state, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = NotchWidgetHost.make(notchContent())
    }

    public func notchContent() -> AnyView { AnyView(NowPlayingExpandedView(model: model)) }

    public func update(_ newState: NowPlayingWidgetState) {
        state = newState
        model.update(newState)
    }
}

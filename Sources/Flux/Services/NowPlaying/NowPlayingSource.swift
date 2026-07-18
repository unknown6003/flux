import Combine
import OSLog

/// Shared logger for the whole Now Playing service layer. Created locally
/// (per-subsystem, like every other corner of Flux) rather than added to
/// `Support/Log.swift`, since this module is meant to be self-contained and
/// independently vendorable/removable.
let nowPlayingLog = Logger(subsystem: "com.flux.menubar", category: "nowPlaying")

/// A backend that can report "what's playing" and optionally act on
/// transport commands. `NowPlayingService` composes two of these
/// (`MediaRemoteAdapterSource`, `ScriptingNowPlayingSource`) behind one
/// failover-aware facade; nothing outside this folder should need to talk to
/// a `NowPlayingSource` directly.
@MainActor
protocol NowPlayingSource: AnyObject {
    /// Emits the current snapshot whenever it changes, and `nil` when there's
    /// nothing playing (or this source has nothing to say — e.g. its process
    /// isn't running). Never completes.
    var statePublisher: AnyPublisher<NowPlayingState?, Never> { get }

    /// Begin producing updates. Idempotent — calling it while already started
    /// is a no-op. Must not block.
    func start()

    /// Stop producing updates and release everything `start()` acquired
    /// (processes, timers, sessions). Idempotent. After this, `statePublisher`
    /// should have last emitted `nil` (or simply stop emitting — callers must
    /// not rely on a final nil specifically, since `stop()` itself doesn't
    /// re-publish for sources where "stopped" and "nothing playing" would
    /// otherwise be indistinguishable).
    func stop()

    /// Issue a transport command. Sources that can't act on commands (or
    /// aren't currently able to) should treat this as a no-op rather than
    /// throwing — `NowPlayingService` is responsible for routing to a source
    /// that can actually do something.
    func send(_ command: NowPlayingCommand)
}

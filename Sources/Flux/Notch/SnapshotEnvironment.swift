import SwiftUI

/// Whether the current view hierarchy is being rendered by the off-screen
/// snapshot pipeline (`NotchSnapshot`/`OffscreenRender`) rather than shown in
/// a real, on-screen window.
///
/// `WaveformVisualizer` (see `NowPlayingComponents.swift`) is the one place
/// this matters today: its production animation is driven by
/// `TimelineView(.animation)` — a display-link schedule, which is what makes
/// it track the real refresh rate (up to 120Hz on ProMotion) smoothly rather
/// than a fixed tick rate. That schedule needs an actual, on-screen, key
/// window to ever fire, though: `OffscreenRender.render` (behind both
/// `--snapshot-notch` and CI's batch `captureAll`) hosts its content in a
/// window deliberately parked off-screen (`setFrameOrigin(-10_000, -10_000)`)
/// so nothing is ever visible on a real display — and a display-link-driven
/// `TimelineView` can go dead silent in exactly that harness (its content
/// closure never runs even once), leaving the waveform blank in every
/// snapshot rather than showing a representative first frame. This flag is
/// how `WaveformVisualizer` tells the two situations apart and falls back to
/// a plain timer-driven `TimelineView(.periodic(...))` — proven to actually
/// fire in this exact off-screen harness by the scrubber's own
/// `TimelineView(.periodic(...))` above it — only while snapshotting.
private struct IsSnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set to `true` once, at the root, by `NotchSnapshot.buildRoot` — never
    /// read/written anywhere in the live, on-screen app path, where it stays
    /// at its `false` default.
    var isSnapshotRender: Bool {
        get { self[IsSnapshotRenderKey.self] }
        set { self[IsSnapshotRenderKey.self] = newValue }
    }
}

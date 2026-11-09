import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/LockScreenContentView.swift
// (LockScreenMediaControlsView, LockScreenGlassModifier and
// LockScreenActivityPill). Sizes, fonts, glass and controls are unchanged.

struct LockScreenMediaControlsView: View {
    @ObservedObject var model: LockScreenCardModel
    @Environment(\.colorScheme) private var colorScheme

    private var prominentControlForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        let state = model.state
        let hasMedia = state.showsMedia
        let hasAuxiliaryContent = state.showsActivity
        let size = LockScreenMetrics.size(hasMedia: hasMedia, hasActivity: hasAuxiliaryContent)

        Group {
            if hasMedia, let media = state.media {
                VStack(spacing: 0) {
                    mediaCard(for: media)
                    if hasAuxiliaryContent {
                        auxiliaryPill(state.activity)
                            .padding(.top, NotchDesign.space2)
                    }
                }
            } else if hasAuxiliaryContent {
                auxiliaryPill(state.activity)
            } else {
                Color.clear
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hasMedia ? "Lock Screen Now Playing" : "Lock Screen Activity")
        .environment(\.isSnapshotRender, model.isFixtureRender)
    }

    private func mediaCard(for media: NowPlayingWidgetState) -> some View {
        let isPlaying = media.status == .playing
        return VStack(spacing: 0) {
            HStack(spacing: NotchDesign.space3) {
                artwork(media.artwork)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title)
                        .font(NotchDesign.titleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !media.artist.isEmpty {
                        Text(media.artist)
                            .font(NotchDesign.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(height: LockScreenMetrics.artworkSide)

            progressRow(for: media)
                .padding(.top, 7)

            transportRow(isPlaying: isPlaying)
                .padding(.top, 5)
        }
        .padding(.horizontal, NotchDesign.space4)
        .padding(.vertical, NotchDesign.space3)
        .frame(width: LockScreenMetrics.mediaWidth, height: LockScreenMetrics.mediaCardHeight)
        .lockScreenGlass(in: RoundedRectangle(cornerRadius: LockScreenMetrics.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func progressRow(for media: NowPlayingWidgetState) -> some View {
        if media.status == .playing {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                progressRowBody(for: media, at: timeline.date)
            }
        } else {
            progressRowBody(for: media, at: Date())
        }
    }

    @ViewBuilder
    private func progressRowBody(for media: NowPlayingWidgetState, at date: Date) -> some View {
        let elapsed = model.elapsed(at: date)
        if let duration = media.duration, duration > 0 {
            let boundedElapsed = min(max(elapsed, 0), duration)
            HStack(spacing: 7) {
                Text(timeLabel(boundedElapsed))
                    .frame(width: 31, alignment: .leading)
                progressTrack(duration: duration, elapsed: boundedElapsed)
                Text("-\(timeLabel(max(duration - boundedElapsed, 0)))")
                    .frame(width: 35, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(height: 12)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.24))
                .frame(height: 3)
        }
    }

    private func progressTrack(duration: TimeInterval, elapsed: TimeInterval) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.24))
                Capsule()
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: geometry.size.width * elapsed / duration)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func auxiliaryPill(_ caption: LockScreenActivityCaption?) -> some View {
        HStack(spacing: NotchDesign.space2) {
            if let caption {
                LockScreenActivityPill(systemName: caption.symbolName, caption: caption.text)
            }
        }
        .frame(maxWidth: .infinity, minHeight: LockScreenMetrics.captionHeight)
    }

    @ViewBuilder
    private func artwork(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: LockScreenMetrics.artworkSide, height: LockScreenMetrics.artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: LockScreenMetrics.artworkCornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: LockScreenMetrics.artworkCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: LockScreenMetrics.artworkSide, height: LockScreenMetrics.artworkSide)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary))
        }
    }

    private func transportRow(isPlaying: Bool) -> some View {
        HStack(spacing: 24) {
            transportButton("backward.end.fill", label: "Previous track", action: .previous)
            transportButton(isPlaying ? "pause.fill" : "play.fill",
                            label: isPlaying ? "Pause" : "Play",
                            action: .togglePlayPause,
                            prominent: true)
            transportButton("forward.end.fill", label: "Next track", action: .next)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func transportButton(_ systemName: String, label: String,
                                 action: LockScreenTransportAction, prominent: Bool = false) -> some View {
        Button { model.onAction(action) } label: {
            if prominent {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(prominentControlForeground)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.primary))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(Int(min(seconds, Double(Int32.max)).rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LockScreenGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !isSnapshotRender {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
        }
    }
}

private extension View {
    func lockScreenGlass<S: Shape>(in shape: S) -> some View {
        modifier(LockScreenGlassModifier(shape: shape))
    }
}

private struct LockScreenActivityPill: View {
    let systemName: String?
    let caption: String

    var body: some View {
        HStack(spacing: NotchDesign.space2) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            Text(caption)
                .font(NotchDesign.bodyFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NotchDesign.space3)
        .frame(height: LockScreenMetrics.captionHeight)
        .lockScreenGlass(in: Capsule())
    }
}

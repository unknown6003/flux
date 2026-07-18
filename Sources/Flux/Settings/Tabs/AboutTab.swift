import SwiftUI
import AppKit

/// Version, quit action, and third-party license attributions — currently
/// just `mediaremote-adapter` (BSD 3-Clause), which the Now Playing widget's
/// system-media adapter is built from (see
/// `Vendor/mediaremote-adapter/PROVENANCE.md`).
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 18) {
            aboutCard
            licensesCard
        }
        .padding(20)
    }

    private var aboutCard: some View {
        FluxCard(title: "About") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Flux \(AppInfo.version) (\(AppInfo.build))")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text(AppInfo.tagline)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondaryColor)
                Rectangle().fill(Theme.hairlineColor).frame(height: 1)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit Flux")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }

    private var licensesCard: some View {
        FluxCard(title: "Third-Party Licenses") {
            VStack(alignment: .leading, spacing: 8) {
                Text("mediaremote-adapter")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text("Reads and controls system Now Playing metadata (used by the notch's Now Playing widget). BSD 3-Clause License, © 2025 Jonas van den Berg and contributors.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Button("View on GitHub") {
                    if let url = URL(string: "https://github.com/ungive/mediaremote-adapter") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accentInkColor)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }
}

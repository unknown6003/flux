import SwiftUI
import AppKit

/// Wraps `ClipboardMonitor` as a `NotchWidget`: a scrollable clipboard
/// history list, click-to-copy-back with a brief checkmark confirmation,
/// per-row hover-to-remove, and a Clear All action.
///
/// ## Lifecycle note: this widget does NOT start/stop `ClipboardMonitor`
/// Every other headless service in the notch suite is started/stopped by its
/// own widget's `willPresent()`/`didDismiss()`. This one is deliberately
/// different — see `ClipboardMonitor`'s own doc comment for the full
/// reasoning: the entire point of a clipboard *history* is that it keeps
/// accumulating while this widget stays closed, so there's something to
/// scroll back through the next time it's opened. Tying the monitor's
/// lifecycle to this widget's presentation would mean history only ever
/// covers however long the panel happened to be open, which defeats the
/// feature. The wiring agent is expected to start/stop `ClipboardMonitor`
/// from a Combine sink on the relevant `SettingsStore` toggle instead —
/// `willPresent()`/`didDismiss()` below are therefore intentionally empty,
/// not an oversight.
@MainActor
final class ClipboardWidget: NotchWidget {
    let id: WidgetID = .clipboard

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchClipboardEnabled` (or equivalent). Note this is a
    /// *separate* toggle from whatever setting drives `ClipboardMonitor.start()`/
    /// `.stop()` (see the type's own doc comment) — a user could disable the
    /// widget (hide it from the cycle order) while still capturing history
    /// in the background, or vice versa; the wiring agent decides whether
    /// those two settings are actually kept in lockstep.
    var isEnabled: Bool

    let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor, isEnabled: Bool = true) {
        self.monitor = monitor
        self.isEnabled = isEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(ClipboardExpandedView(monitor: monitor))
    }

    /// No compact/collapsed-strip presence — like `ShelfWidget`/
    /// `CalendarWidget`, history only shows once expanded.
    func makeCompactView() -> AnyView? { nil }

    /// Nothing to do — see the type's own doc comment: `ClipboardMonitor`'s
    /// lifecycle is settings-driven, not tied to this widget's presentation.
    func willPresent() {}

    /// Nothing to do — see the type's own doc comment.
    func didDismiss() {}
}

// MARK: - Expanded panel view

private struct ClipboardExpandedView: View {
    @ObservedObject var monitor: ClipboardMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if monitor.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("Clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
            if !monitor.entries.isEmpty {
                Button("Clear All") { monitor.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 20))
                .foregroundStyle(Color.white.opacity(0.3))
            Text("Nothing copied yet")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Alcove refit (M7): this panel's total height budget is 190, leaving
    /// ~100–150 of usable content height after fixed padding. Each row is
    /// ~34pt (6pt vertical padding × 2 + a 12pt preview line + 2pt inner
    /// spacing + a 9pt age line, i.e. 12 + 6 + 12 + 2 + 9 ≈ 41 at the high
    /// end, ~34 typical) plus 6pt list spacing — so 3 rows already
    /// approach the top of the usable range, which is why this list leans
    /// on `ScrollView` rather than trying to guarantee every entry is
    /// visible without scrolling.
    private var list: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(monitor.entries) { entry in
                    ClipboardRow(entry: entry, monitor: monitor)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - One row

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    @ObservedObject var monitor: ClipboardMonitor

    @State private var isHovering = false
    @State private var didConfirmCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Formatters.relativeAge.localizedString(for: entry.capturedAt, relativeTo: Date()))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.12 : 0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .onHover { isHovering = $0 }
    }

    /// A checkmark takes priority over the hover ✕ while the 1s copy
    /// confirmation is showing — swapping straight to a remove control mid-
    /// confirmation would read as the click itself having removed the row.
    @ViewBuilder
    private var trailingControl: some View {
        if didConfirmCopy {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
        } else if isHovering {
            Button {
                monitor.remove(entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    /// Image/other entries carry neither `fullString` nor `filePaths` (see
    /// `ClipboardEntry`'s own doc comments) — nothing to copy back, so
    /// tapping one of those rows is a deliberate no-op rather than silently
    /// clearing the pasteboard.
    private func handleTap() {
        guard entry.fullString != nil || entry.filePaths != nil else { return }
        monitor.copyBack(entry.id)
        withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = false }
        }
    }

    private var icon: String {
        switch entry.kind {
        case .text: return "doc.plaintext"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }
}

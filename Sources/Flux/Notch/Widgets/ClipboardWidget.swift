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
                .font(NotchDesign.captionFont.weight(.semibold))
                .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
            Spacer()
            if !monitor.entries.isEmpty {
                Button("Clear All") { monitor.clear() }
                    .buttonStyle(.plain)
                    .font(NotchDesign.captionFont)
                    .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
            }
        }
    }

    private var emptyState: some View {
        WidgetEmptyStateView(icon: "doc.on.clipboard", message: "Nothing copied yet")
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
            // Row spacing stays a literal 6, not `NotchDesign.rowSpacing`
            // (8) — this panel's height budget is documented above
            // (`list`'s own doc comment) as already approaching its usable
            // ceiling at 3 rows; the extra points `rowSpacing` would add per
            // gap risks reintroducing the very clipping this pass fixes.
            VStack(spacing: 6) {
                ForEach(monitor.entries) { entry in
                    ClipboardRow(entry: entry, monitor: monitor)
                }
            }
            .padding(.top, 2)
            // Bug fix (M8): matches `notchScrollFade()` below — the last
            // row's real content clears the fade zone instead of fading out
            // from underneath it.
            .padding(.bottom, 2 + NotchDesign.scrollFadeContentInset)
        }
        // Bug fix (M8): the clipboard's third row was clipping hard into
        // the panel's 32pt bottom corner radius; this fades it out instead.
        .notchScrollFade()
    }
}

// MARK: - One row

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    @ObservedObject var monitor: ClipboardMonitor

    @State private var isHovering = false
    @State private var didConfirmCopy = false
    /// Decoded once per entry rather than on every body pass. `leadingGlyph`
    /// is recomputed whenever `isHovering`/`didConfirmCopy` changes, so
    /// decoding inline meant re-decoding the thumbnail on every hover.
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: NotchDesign.rowSpacing) {
            leadingGlyph
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Formatters.age(from: entry.capturedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
            }

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.horizontal, NotchDesign.space2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: NotchDesign.rowRadius, style: .continuous)
                // Only a copyable row lifts on hover. Dimming a non-copyable
                // one while still highlighting it under the pointer sends two
                // opposite signals about the same row.
                .fill(Color.white.opacity(isHovering && isCopyable ? 0.12 : 0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .onHover { isHovering = $0 }
        // Keyed on the entry so a recycled row re-decodes for its new
        // content, and on the data so a thumbnail that lands asynchronously
        // (see `ClipboardMonitor.attachThumbnailIfNeeded`) is picked up.
        .task(id: entry.thumbnailData) {
            thumbnail = entry.thumbnailData.flatMap { NSImage(data: $0) }
        }
        // Image/"other" entries have nothing to copy back, so they must not
        // advertise themselves as tappable: no hover lift, dimmed, and no
        // accessibility action. They used to look and highlight exactly like
        // a copyable row and then do nothing at all when clicked.
        .opacity(isCopyable ? 1 : NotchDesign.secondaryOpacity)
        // `.contain`, NOT `.combine`: combining would fold the remove button
        // into a single element for the whole row, which is the exact
        // opposite of what the change just below is for — that button has to
        // stay separately focusable and actionable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        // `.contain` keeps the remove button separately focusable, but it
        // also stops the ROW itself being an actionable element — so the
        // copy-on-tap has no VoiceOver activation path of its own. This
        // context menu is therefore load-bearing for accessibility, not a
        // convenience: it is how a non-pointer user copies an entry at all.
        // (Flagged for the hardware QA pass in docs/notch-checklist.md;
        // whether SwiftUI routes an accessibility activation around
        // `allowsHitTesting` is not something to assert from a Linux box.)
        .contextMenu {
            if isCopyable {
                Button("Copy") { handleTap() }
            }
            if let url = entry.linkURL {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
            Button("Remove", role: .destructive) { monitor.remove(entry.id) }
        }
    }

    /// Whether this entry can actually be copied back — see `handleTap`.
    private var isCopyable: Bool {
        entry.fullString != nil || entry.filePaths != nil || entry.imageData != nil
    }

    private var accessibilityLabel: String {
        let kind: String
        switch entry.kind {
        case .text: kind = "Text"
        case .url: kind = "Link"
        case .image: kind = "Image"
        case .color: kind = "Colour"
        case .file: kind = "File"
        case .other: kind = "Clipboard item"
        }
        return isCopyable ? "\(kind): \(entry.preview)" : "\(kind): \(entry.preview), not copyable"
    }

    /// A checkmark takes priority over the hover ✕ while the 1s copy
    /// confirmation is showing — swapping straight to a remove control mid-
    /// confirmation would read as the click itself having removed the row.
    @ViewBuilder
    private var trailingControl: some View {
        if didConfirmCopy {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
        } else {
            // Always built, faded rather than conditionally created: a view
            // that only exists while hovered also only exists in the
            // accessibility tree while hovered, which puts the sole remove
            // control out of reach of anyone not using a pointer.
            HStack(spacing: 4) {
                if let url = entry.linkURL {
                    // Copying a URL back so you can paste it into a browser
                    // is a strictly worse version of just opening it, and
                    // opening is the commonest thing to want from a copied
                    // link. Also in the context menu, for pointer-free use.
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .foregroundStyle(.white.opacity(NotchDesign.secondaryOpacity))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityLabel("Open \(url.host ?? "link") in browser")
                }
                Button {
                    monitor.remove(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(NotchDesign.secondaryOpacity))
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityLabel("Remove clipboard item")
            }
        }
    }

    /// Image/other entries carry neither `fullString` nor `filePaths` (see
    /// `ClipboardEntry`'s own doc comments) — nothing to copy back, so
    /// tapping one of those rows is a deliberate no-op rather than silently
    /// clearing the pasteboard.
    private func handleTap() {
        guard isCopyable else { return }
        monitor.copyBack(entry.id)
        withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = false }
        }
    }

    /// A real thumbnail for an image, a real swatch for a colour, an SF
    /// Symbol for everything else. The point of a clipboard history is
    /// recognising an entry at a glance, and "Image (1470×956)" is not
    /// recognisable — every screenshot looks identical.
    @ViewBuilder
    private var leadingGlyph: some View {
        if entry.kind == .image, let image = thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if let components = entry.colorComponents {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(.sRGB, red: components.red, green: components.green,
                            blue: components.blue, opacity: components.alpha))
                .frame(width: 16, height: 16)
                .overlay(
                    // A hairline, so a white or fully transparent swatch is
                    // still visible against the panel's black.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.white.opacity(NotchDesign.hairlineOpacity))
                )
        } else {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
        }
    }

    private var icon: String {
        switch entry.kind {
        case .text: return "doc.plaintext"
        case .url: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }
}

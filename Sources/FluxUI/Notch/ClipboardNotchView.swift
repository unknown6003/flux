import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/Widgets/ClipboardWidget.swift
// (ClipboardExpandedView and ClipboardRow). Text, layout and styles are
// unchanged; the monitor is replaced by typed actions.

@MainActor
final class ClipboardNotchModel: ObservableObject {
    @Published var state: ClipboardWidgetState
    let onAction: @MainActor (ClipboardWidgetAction) -> Void

    init(state: ClipboardWidgetState, onAction: @escaping @MainActor (ClipboardWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
    }

    var entries: [ClipboardWidgetItem] { Array(state.items.prefix(ClipboardWidgetController.maximumItems)) }
}

struct ClipboardExpandedView: View {
    @ObservedObject var model: ClipboardNotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.entries.isEmpty {
                WidgetEmptyStateView(icon: "doc.on.clipboard", message: "Nothing copied yet")
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
                .foregroundStyle(NotchDesign.secondaryColor)
            Spacer()
            if !model.entries.isEmpty {
                Button("Clear All") { model.onAction(.clearAll) }
                    .buttonStyle(.plain)
                    .font(NotchDesign.captionFont)
                    .foregroundStyle(NotchDesign.tertiaryColor)
            }
        }
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(model.entries, id: \.id) { entry in
                    ClipboardRow(entry: entry, onAction: model.onAction)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 2 + NotchDesign.scrollFadeContentInset)
        }
        .notchScrollFade()
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardWidgetItem
    let onAction: @MainActor (ClipboardWidgetAction) -> Void

    @State private var isHovering = false
    @State private var didConfirmCopy = false

    var body: some View {
        HStack(spacing: NotchDesign.rowSpacing) {
            leadingGlyph
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(NotchDesign.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.capturedAt.map { NotchAge.text(from: $0) } ?? "now")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchDesign.tertiaryColor)
            }

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.horizontal, NotchDesign.space2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: NotchDesign.rowRadius, style: .continuous)
                .fill(NotchDesign.primaryColor.opacity(isHovering && isCopyable ? 0.12 : 0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .onHover { isHovering = $0 }
        .opacity(isCopyable ? 1 : NotchDesign.secondaryOpacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if isCopyable {
                Button("Copy") { handleTap() }
            }
            if entry.webLink != nil {
                Button("Open in Browser") { onAction(.openLink(entry.id)) }
            }
            Button("Remove", role: .destructive) { onAction(.remove(entry.id)) }
        }
    }

    private var isCopyable: Bool { entry.hasPayload }

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

    @ViewBuilder
    private var trailingControl: some View {
        if didConfirmCopy {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(NotchDesign.primaryColor)
        } else {
            HStack(spacing: 4) {
                if let url = entry.webLink {
                    Button { onAction(.openLink(entry.id)) } label: {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .foregroundStyle(NotchDesign.secondaryColor)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityLabel("Open \(url.host ?? "link") in browser")
                }
                Button {
                    onAction(.remove(entry.id))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NotchDesign.secondaryColor)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityLabel("Remove clipboard item")
            }
        }
    }

    private func handleTap() {
        guard isCopyable else { return }
        onAction(.copy(entry.id))
        withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.15)) { didConfirmCopy = false }
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if entry.kind == .image, let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if let components = entry.color {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(.sRGB, red: components.red, green: components.green,
                            blue: components.blue, opacity: components.alpha))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(NotchDesign.hairlineColor)
                )
        } else {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(NotchDesign.secondaryColor)
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

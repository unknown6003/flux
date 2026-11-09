import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/Widgets/ShelfWidget.swift
// (ShelfExpandedView and ShelfTileView). Text, layout and styles are
// unchanged; the store is replaced by typed actions.

@MainActor
final class ShelfNotchModel: ObservableObject {
    @Published var state: FileShelfWidgetState
    let onAction: @MainActor (FileShelfWidgetAction) -> Void

    init(state: FileShelfWidgetState, onAction: @escaping @MainActor (FileShelfWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
    }

    /// Files appear once their copy has finished, as in 0.21.35.
    var items: [FileShelfWidgetItem] { state.items.filter { $0.status == .ready } }
}

struct ShelfExpandedView: View {
    @ObservedObject var model: ShelfNotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.items.isEmpty {
                WidgetEmptyStateView(icon: "tray.and.arrow.down", message: "Drop files here")
            } else {
                tileScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("File Shelf")
                .font(NotchDesign.captionFont.weight(.semibold))
                .foregroundStyle(NotchDesign.secondaryColor)
            Spacer()
            if !model.items.isEmpty {
                Button("Clear All") { model.onAction(.clearAll) }
                    .buttonStyle(.plain)
                    .font(NotchDesign.captionFont)
                    .foregroundStyle(NotchDesign.tertiaryColor)
            }
        }
    }

    private var tileScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotchDesign.space3) {
                ForEach(model.items, id: \.id) { item in
                    ShelfTileView(item: item, onAction: model.onAction)
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 2 + NotchDesign.scrollFadeContentInset)
        }
        .notchScrollFade(edge: .trailing)
    }
}

private struct ShelfTileView: View {
    let item: FileShelfWidgetItem
    let onAction: @MainActor (FileShelfWidgetAction) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(NotchDesign.primaryColor.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
            Text(item.addedAt.map { NotchAge.text(from: $0) } ?? "now")
                .font(.system(size: 9))
                .foregroundStyle(NotchDesign.tertiaryColor)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .onTapGesture { onAction(.open(item.id)) }
        .onHover { isHovering = $0 }
        .onDrag {
            guard let url = item.dragURL, let provider = NSItemProvider(contentsOf: url) else {
                return NSItemProvider()
            }
            return provider
        }
        .contextMenu { shareMenu }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(NotchTheme.surfaceRaisedColor)
                        .overlay(Image(systemName: "doc.fill").foregroundStyle(NotchDesign.primaryColor.opacity(0.35)))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: NotchDesign.tileRadius, style: .continuous))

            Button {
                onAction(.remove(item.id))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(NotchDesign.primaryColor, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    @ViewBuilder
    private var shareMenu: some View {
        if item.dragURL != nil {
            Button("AirDrop") { onAction(.airDrop(item.id)) }
            Button("Show in Finder") { onAction(.showInFinder(item.id)) }
            Button("Copy") { onAction(.copy(item.id)) }
            Divider()
        }
        Button("Remove", role: .destructive) { onAction(.remove(item.id)) }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Wraps `ShelfStore` as a `NotchWidget`: a horizontal strip of recently
/// dropped/added files with thumbnails, a drag source for dragging files back
/// out to Finder/other apps, quick AirDrop/Finder/Copy actions, and the
/// notch's own drag-*in* destination for a file dropped directly onto the
/// already-expanded shelf.
///
/// Files dropped on the *collapsed* notch are a separate path: `NotchPanel`'s
/// window-level `NSDraggingDestination` (see that file) auto-expands to this
/// widget before the drop lands, then hands the dropped URLs to
/// `NotchWindowController.onShelfDrop` — which the wiring agent points at
/// `store.add(urls:)` — rather than going through this view's own `.onDrop`
/// at all. This view's `.onDrop` only matters once the panel is already open.
///
/// Owns no file/thumbnail state of its own — `ShelfStore` is the single
/// source of truth; this class only adapts it to the `NotchWidget` surface.
@MainActor
final class ShelfWidget: NotchWidget {
    let id: WidgetID = .shelf

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchShelfEnabled`. `NotchWidgetRegistry` reads this
    /// every time it computes `enabledWidgets`.
    var isEnabled: Bool

    let store: ShelfStore

    init(store: ShelfStore, isEnabled: Bool = true) {
        self.store = store
        self.isEnabled = isEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(ShelfExpandedView(store: store))
    }

    /// No compact/collapsed-strip presence for M2 — the shelf only shows
    /// once expanded (unlike Now Playing's mini artwork + equalizer).
    func makeCompactView() -> AnyView? { nil }

    /// Sweep anything past `store.expiryInterval` every time the shelf
    /// becomes visible, rather than on a running timer — matching the notch
    /// suite's zero-idle-timer perf contract. A shelf that's never opened
    /// simply keeps its expired items until the next time someone looks,
    /// which is fine: expiry is a tidiness feature, not a guarantee.
    func willPresent() {
        store.sweepExpired()
    }

    /// `ShelfStore` holds no timers/sessions of its own (see its own doc
    /// comment on why all its work is synchronous, main-actor, on-access),
    /// so there is nothing to stop here.
    func didDismiss() {}
}

// MARK: - Expanded panel view

private struct ShelfExpandedView: View {
    @ObservedObject var store: ShelfStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                tileScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The expanded shelf's own drop target — for a drag that's released
        // once the panel is already open (anywhere over this view, not just
        // the tiny physical notch pixels the collapsed-state window-level
        // destination in `NotchPanel` cares about).
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            performDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accentColor.opacity(isDropTargeted ? 0.6 : 0), lineWidth: 2)
        )
    }

    private var header: some View {
        HStack {
            Text("File Shelf")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Spacer()
            if !store.items.isEmpty {
                Button("Clear All") { store.removeAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accentColor)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentColor.opacity(0.5))
            Text("Drop files here")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tileScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(store.items) { item in
                    ShelfTileView(item: item, store: store)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Drop handling

    /// Reads file URLs off each provider and adds them to the store.
    /// `NSItemProvider.loadItem`'s completion handler isn't guaranteed to
    /// fire on the main thread, so the loading loop runs on a plain
    /// (non-isolated) `Task` and only hops to the main actor for the final
    /// `store.add(urls:)` call, since `ShelfStore` is `@MainActor`-isolated.
    private func performDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                _ = store.add(urls: urls)
            }
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                switch item {
                case let data as Data:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let url as URL:
                    continuation.resume(returning: url)
                case let nsurl as NSURL:
                    continuation.resume(returning: nsurl as URL)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - One tile

private struct ShelfTileView: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore

    @State private var isHovering = false

    /// Shared rather than one-per-tile: `RelativeDateTimeFormatter` is
    /// non-trivial to construct and every tile wants the identical style.
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
            Text(item.fileName)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
            Text(Self.ageFormatter.localizedString(for: item.addedAt, relativeTo: Date()))
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .onTapGesture { store.open(item.id) }
        .onHover { isHovering = $0 }
        // Drag-*out*: hands the file's own stored URL to whatever the user
        // drags it onto (Finder, Mail, Slack, ...). `store.url(for:)` can
        // return `nil` for an item whose backing file has since vanished
        // from disk — falling back to a plain, empty `NSItemProvider` makes
        // that a harmless no-op drag rather than a crash.
        .onDrag {
            guard let url = store.url(for: item.id), let provider = NSItemProvider(contentsOf: url) else {
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
                if let image = store.thumbnails[item.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Theme.surfaceRaisedColor)
                        .overlay(Image(systemName: "doc.fill").foregroundStyle(Theme.accentColor.opacity(0.7)))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if isHovering {
                Button {
                    store.remove(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
    }

    /// AirDrop / Show in Finder / Copy — a deliberately simpler substitute
    /// for a full `NSSharingServicePicker`, which needs an `NSView` anchor
    /// that a SwiftUI-only tile doesn't cleanly have without an extra
    /// `NSViewRepresentable` shim. These three cover the flows people
    /// actually reach for from a shelf item; see `ShelfWidget`'s own doc
    /// comment for the full reasoning.
    @ViewBuilder
    private var shareMenu: some View {
        if let url = store.url(for: item.id) {
            Button("AirDrop") {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
            }
            Divider()
        }
        Button("Remove", role: .destructive) { store.remove(item.id) }
    }
}

import SwiftUI
import AppKit

/// Wraps `ShelfStore` as a `NotchWidget`: a horizontal strip of recently
/// dropped/added files with thumbnails, a drag source for dragging files back
/// out to Finder/other apps, and quick AirDrop/Finder/Copy actions.
///
/// This widget owns no drag-*in* handling of its own — every file drop, in
/// every state (landing on the collapsed notch and auto-expanding to this
/// widget, or landing directly on the already-open shelf panel), is caught by
/// `NotchPanel`'s window-level `NSDraggingDestination` (see that file's doc
/// comment) and handed to `NotchWindowController.onShelfDrop`, which the
/// wiring agent points at `store.add(urls:)`. An earlier revision *also* gave
/// this view's expanded content its own SwiftUI `.onDrop` for the
/// already-open case — a second, independent drop destination that raced the
/// window-level one (a `draggingExited`/`draggingEntered` flicker mid-drag,
/// and drops that could be declined right after an auto-expand). It's been
/// removed so the window-level destination is the sole drag-and-drop path,
/// in every state.
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

    /// Sweep anything past `store.expiryInterval`, then generate thumbnails
    /// for anything still missing one — both run every time the shelf
    /// becomes visible, rather than on a running timer, matching the notch
    /// suite's zero-idle-timer perf contract. A shelf that's never opened
    /// simply keeps its expired items (and un-thumbnailed tiles) until the
    /// next time someone looks, which is fine: neither is a guarantee, just
    /// tidiness/polish. Sweeping first means an about-to-be-swept item never
    /// gets a thumbnail generated for it needlessly.
    func willPresent() {
        store.sweepExpired()
        store.ensureThumbnails()
    }

    /// `ShelfStore` holds no timers/sessions of its own (see its own doc
    /// comment on why all its work is synchronous, main-actor, on-access),
    /// so there is nothing to stop here.
    func didDismiss() {}
}

// MARK: - Expanded panel view

private struct ShelfExpandedView: View {
    @ObservedObject var store: ShelfStore

    // No `.onDrop` here — see `ShelfWidget`'s own doc comment for why every
    // drop (whether it lands here, already open, or on the collapsed notch)
    // is caught upstream by `NotchPanel`'s window-level
    // `NSDraggingDestination` instead of a second, competing destination on
    // this view.
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
}

// MARK: - One tile

private struct ShelfTileView: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
            Text(item.fileName)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
            Text(Formatters.relativeAge.localizedString(for: item.addedAt, relativeTo: Date()))
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

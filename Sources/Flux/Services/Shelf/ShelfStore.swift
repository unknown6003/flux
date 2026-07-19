import AppKit
import Combine
import OSLog
import QuickLookThumbnailing

/// Shared logging point for the shelf subsystem — mirrors `nowPlayingLog`'s
/// file-scope-constant pattern rather than adding a new case to `Log.swift`,
/// since the Shelf folder is a self-contained subsystem the notch suite owns.
let shelfLog = Logger(subsystem: "com.flux.menubar", category: "shelf")

/// Headless data layer behind the notch's file-shelf widget: copies dropped
/// files into Flux's own storage (so a shelved file survives the source being
/// moved/ejected/deleted), persists a manifest across launches, generates
/// QuickLook thumbnails, and can auto-expire old items.
///
/// All `FileManager` work here runs synchronously on the main actor. That's a
/// deliberate call, not an oversight: at M2 scale (a user's shelf — tens of
/// items, not thousands) copying/removing/stat'ing local files is fast enough
/// that hopping to a background queue would only add complexity without a
/// perceptible win, and it keeps `items`/`thumbnails` trivially consistent
/// with no cross-actor synchronization to get wrong. If the shelf ever grows
/// to handle much larger batches or slower (e.g. network) volumes, that's the
/// point to revisit this.
@MainActor
final class ShelfStore: ObservableObject {
    /// Newest-added first — re-sorted after every mutation so callers never
    /// have to think about insertion order.
    @Published private(set) var items: [ShelfItem] = []
    /// Populated asynchronously as `QLThumbnailGenerator` (or its
    /// `NSWorkspace` icon fallback) finishes for each item. Absence of a key
    /// just means "not ready yet" — callers should show a placeholder.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    /// `nil` = keep shelved files forever. Set from settings; not persisted
    /// by this type itself (the settings layer owns that).
    var expiryInterval: TimeInterval?

    /// Storage directory — created on init if missing.
    let directory: URL

    private let fileManager = FileManager.default
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()

        do {
            try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        } catch {
            shelfLog.error("Failed to create shelf directory at \(self.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let loaded = Self.loadManifest(at: manifestURL)
        let reconciled = Self.reconcile(loaded, directory: self.directory, fileManager: fileManager)
        self.items = reconciled.sorted { $0.addedAt > $1.addedAt }
        Self.logStrayFiles(knownNames: Set(reconciled.map(\.storedFileName)),
                            directory: self.directory, fileManager: fileManager)

        // Persist immediately if reconciliation actually dropped anything, so
        // a manifest full of dangling entries doesn't keep re-surfacing them
        // as "missing" work on every subsequent launch.
        if reconciled.count != loaded.count {
            saveManifest()
        }

        for item in items {
            generateThumbnail(for: item)
        }

        sweepExpired()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Practically never nil on macOS, but fall back to a sane,
            // still-per-user location rather than force-unwrapping.
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }

    // MARK: - Mutation

    /// Copies each URL's file into the shelf directory under a fresh,
    /// collision-proof stored name. Sources that fail to copy (permissions,
    /// already gone, source disappeared mid-drag, etc.) are logged and
    /// skipped rather than aborting the whole batch. Returns only the items
    /// that were actually added.
    @discardableResult
    func add(urls: [URL]) -> [ShelfItem] {
        sweepExpired()

        var added: [ShelfItem] = []
        for source in urls {
            let displayName = source.lastPathComponent
            let storedName = "\(UUID().uuidString)-\(displayName)"
            let dest = directory.appendingPathComponent(storedName)

            do {
                // `copyItem` recurses automatically when the source is a
                // directory, so directories are supported for free.
                try fileManager.copyItem(at: source, to: dest)
            } catch {
                shelfLog.error("Failed to copy \(displayName, privacy: .public) onto the shelf: \(error.localizedDescription, privacy: .public)")
                continue
            }

            let values = try? dest.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let fileSize = isDirectory ? 0 : Int64(values?.fileSize ?? 0)

            let item = ShelfItem(fileName: displayName, storedFileName: storedName,
                                  addedAt: Date(), fileSize: fileSize, originURL: source)
            added.append(item)
        }

        guard !added.isEmpty else { return [] }

        items.append(contentsOf: added)
        items.sort { $0.addedAt > $1.addedAt }
        saveManifest()

        for item in added {
            generateThumbnail(for: item)
        }

        return added
    }

    /// Removes one item: deletes its stored file, drops its manifest entry
    /// and thumbnail, and persists. A missing/already-gone stored file is
    /// logged but doesn't stop the manifest entry from being dropped — the
    /// user asked for it gone either way.
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]

        do {
            try fileManager.removeItem(at: item.storedURL(in: directory))
        } catch {
            shelfLog.error("Failed to delete stored file for \(item.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        items.remove(at: index)
        thumbnails[id] = nil
        saveManifest()
    }

    func removeAll() {
        for item in items {
            try? fileManager.removeItem(at: item.storedURL(in: directory))
        }
        items.removeAll()
        thumbnails.removeAll()
        saveManifest()
    }

    // MARK: - Access

    /// Stored URL for a given item — for drag-out, opening, or sharing
    /// (AirDrop). `nil` if `id` isn't (or is no longer) on the shelf.
    func url(for id: UUID) -> URL? {
        items.first { $0.id == id }?.storedURL(in: directory)
    }

    func open(_ id: UUID) {
        guard let url = url(for: id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Removes every item older than `expiryInterval`. Called on access
    /// (init, `add`) rather than from a repeating timer — matches the notch
    /// suite's zero-idle-CPU perf contract; a shelf nobody looks at doesn't
    /// need to prune itself on a schedule.
    func sweepExpired() {
        guard let expiryInterval else { return }
        let cutoff = Date().addingTimeInterval(-expiryInterval)
        let expiredIDs = items.filter { $0.addedAt < cutoff }.map(\.id)
        for id in expiredIDs {
            remove(id)
        }
    }

    // MARK: - Manifest persistence

    private static func loadManifest(at url: URL) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ShelfItem].self, from: data)
        } catch {
            shelfLog.error("Failed to decode shelf manifest at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) — starting empty")
            return []
        }
    }

    /// Writes the manifest atomically (`Data.write(options: .atomic)` writes
    /// to a temp file in the same directory and swaps it in), so a crash or
    /// power loss mid-write can never leave a truncated, corrupt
    /// `manifest.json` behind.
    private func saveManifest() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            shelfLog.error("Failed to save shelf manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops manifest entries whose stored file no longer exists on disk
    /// (e.g. the user deleted it directly in Finder, or a backup restore lost
    /// it) — otherwise the shelf UI would show phantom items whose
    /// drag-out/open/share would silently fail.
    private static func reconcile(_ items: [ShelfItem], directory: URL, fileManager: FileManager) -> [ShelfItem] {
        items.filter { item in
            let exists = fileManager.fileExists(atPath: item.storedURL(in: directory).path)
            if !exists {
                shelfLog.notice("Shelf manifest entry \(item.fileName, privacy: .public) is missing on disk — dropping it")
            }
            return exists
        }
    }

    /// Files that exist in the shelf directory but aren't referenced by any
    /// manifest entry are left alone — deleting unrecognized files
    /// automatically would risk destroying user data over a bug or a manifest
    /// that simply failed to save. They're only logged, as a breadcrumb for
    /// diagnosing how they got there.
    private static func logStrayFiles(knownNames: Set<String>, directory: URL, fileManager: FileManager) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent != "manifest.json" {
            if !knownNames.contains(url.lastPathComponent) {
                shelfLog.notice("Stray file in shelf directory not referenced by the manifest — left in place: \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    // MARK: - Thumbnails

    /// Requests a QuickLook thumbnail at roughly 64pt (scaled for the main
    /// screen's backing scale) and hops the result to the main actor —
    /// `QLThumbnailGenerator`'s completion handler fires on an arbitrary
    /// background queue, and this call itself is async/non-blocking, so the
    /// main thread is never touched until the result is ready. Falls back to
    /// the generic Finder icon for the file's type on failure (unreadable
    /// file, unsupported type, generator error, etc.).
    private func generateThumbnail(for item: ShelfItem) {
        let url = item.storedURL(in: directory)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, error in
            Task { @MainActor in
                // The item may have been removed while the request was in
                // flight — don't resurrect a thumbnail entry for it.
                guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                if let representation {
                    self.thumbnails[item.id] = representation.nsImage
                } else {
                    if let error {
                        shelfLog.debug("QuickLook thumbnail unavailable for \(item.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    self.thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
    }
}

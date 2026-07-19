import Foundation

/// A single file living on the shelf — Flux keeps its own copy on disk (under
/// `ShelfStore.directory`) rather than merely referencing the original, so a
/// shelved file survives the source being moved, renamed, ejected, or deleted.
///
/// Two files both called "Screenshot.png" must be able to sit on the shelf at
/// once, so each item gets its own `id`-named subdirectory
/// (`<directory>/<id>/`) rather than mangling the on-disk file name to force
/// uniqueness. That keeps `fileName` — the *only* name stored — exactly the
/// original basename, so every export (drag-out, AirDrop, Copy) hands out a
/// URL whose last path component is precisely what the user dropped, never a
/// UUID-prefixed stand-in leaking into the destination app.
struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Name shown in the UI *and* the on-disk file name inside this item's
    /// subdirectory — the original file's last path component, unmodified.
    var fileName: String
    var addedAt: Date

    init(id: UUID = UUID(), fileName: String, addedAt: Date) {
        self.id = id
        self.fileName = fileName
        self.addedAt = addedAt
    }

    /// This item's private subdirectory within the store's storage
    /// directory: `<directory>/<id>/`. `id` is already guaranteed unique, so
    /// it doubles as the collision-proof directory name with no separate
    /// UUID bookkeeping needed. Kept as a function of `directory` (rather
    /// than a stored absolute URL) so the whole shelf directory can move —
    /// or just resolve to a different sandbox/App Support path across
    /// machines/backups — without invalidating every persisted item.
    func storedDirectoryURL(in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Where this item's copy actually lives: `<directory>/<id>/<fileName>`.
    /// Callers that need to delete the whole item (not just its file) should
    /// remove `storedDirectoryURL(in:)` instead, so an empty `<id>/`
    /// directory doesn't linger on disk forever.
    func storedURL(in directory: URL) -> URL {
        storedDirectoryURL(in: directory).appendingPathComponent(fileName)
    }
}

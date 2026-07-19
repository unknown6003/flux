import Foundation

/// A single file living on the shelf — Flux keeps its own copy on disk (under
/// `ShelfStore.directory`) rather than merely referencing the original, so a
/// shelved file survives the source being moved, renamed, ejected, or deleted.
///
/// `fileName` (what the user sees) and `storedFileName` (what's actually on
/// disk) are deliberately separate: two files both called "Screenshot.png"
/// must be able to sit on the shelf at once, so the on-disk name is always
/// prefixed with a fresh UUID to guarantee uniqueness, while the display name
/// stays exactly what the user recognizes.
struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Name shown in the UI — the original file's last path component.
    var fileName: String
    /// Unique on-disk name inside `ShelfStore.directory`, of the form
    /// `<uuid>-<fileName>`. The UUID prefix is what makes it collision-proof;
    /// the original name is kept as a suffix purely so the directory is
    /// human-readable if anyone ever has to look at it directly (Finder,
    /// backups, support requests).
    var storedFileName: String
    var addedAt: Date

    init(id: UUID = UUID(), fileName: String, storedFileName: String, addedAt: Date) {
        self.id = id
        self.fileName = fileName
        self.storedFileName = storedFileName
        self.addedAt = addedAt
    }

    /// Where this item's copy actually lives, given the store's storage
    /// directory. Kept as a function of `directory` (rather than a stored
    /// absolute URL) so the whole shelf directory can move — or just resolve
    /// to a different sandbox/App Support path across machines/backups —
    /// without invalidating every persisted item.
    func storedURL(in directory: URL) -> URL {
        directory.appendingPathComponent(storedFileName)
    }
}

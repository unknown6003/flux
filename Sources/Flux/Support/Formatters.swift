import Foundation

/// Shared, pre-configured formatters used identically by more than one notch
/// widget — pulled out once two call sites (`ShelfWidget`'s tile and
/// `ClipboardWidget`'s row) ended up with byte-identical construction of the
/// same formatter rather than one of them importing the other's.
enum Formatters {
    /// "3m ago"/"2h ago"-style relative timestamps — `ShelfTileView`'s tile
    /// caption and `ClipboardRow`'s row caption both want the identical
    /// abbreviated style. Shared as one `static let` rather than one per
    /// call site: `RelativeDateTimeFormatter` is non-trivial to construct,
    /// and every caller wants it configured exactly the same way.
    static let relativeAge: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

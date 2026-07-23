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
    ///
    /// Not called directly by either widget any more — see `age(from:to:)`
    /// below, the wrapper that fixes their shared "in 0s" bug. Kept
    /// `internal` (not `private`) only because `age(from:to:)`'s own tests
    /// reference it directly.
    static let relativeAge: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The bug fix for Shelf/Clipboard row captions reading a future-tense
    /// "in 0s" for an item added moments ago: calling `relativeAge.
    /// localizedString(for:relativeTo:)` directly on a just-captured
    /// timestamp is one sign flip away from disaster — `capturedAt`/
    /// `addedAt` and the `Date()` passed as `relativeTo` are read from two
    /// separate clock calls a few instructions apart, so `capturedAt` can
    /// land microseconds AFTER `relativeTo` (clock skew/rounding, never a
    /// real future timestamp), and `RelativeDateTimeFormatter` reads that as
    /// "in 0 seconds" rather than "0 seconds ago" — a formatter behaving
    /// correctly on genuinely ambiguous input, not a bug in the formatter
    /// itself.
    ///
    /// Fixed two ways here, both required:
    /// - Anything under 60s old reads as a flat "now" — nobody needs
    ///   second-level precision for "just now", and collapsing the whole
    ///   sub-minute range to one literal removes the tense question
    ///   entirely for exactly the window clock skew could otherwise flip.
    /// - Past that, the interval is floored and only ever fed to
    ///   `relativeAge` as a date strictly at-or-before `now` (never
    ///   `date` itself, which is what `relativeTo:` is really comparing
    ///   against) — so a real multi-minute-old timestamp can never
    ///   round-trip through the same sign-flip bug on some future edge
    ///   case (e.g. a laggy call site formatting slightly before its own
    ///   `Date()` snapshot was taken).
    static func age(from date: Date, to now: Date = Date()) -> String {
        let interval = max(now.timeIntervalSince(date), 0)
        guard interval >= 60 else { return "now" }
        let flooredPastDate = now.addingTimeInterval(-interval.rounded(.down))
        return relativeAge.localizedString(for: flooredPastDate, relativeTo: now)
    }
}

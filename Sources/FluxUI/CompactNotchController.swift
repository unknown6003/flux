import Foundation

/// Queue actions the notch sends to its parent.
public enum CompactNotchAction: Equatable, Sendable {
    /// Open the expanded panel.
    case expand
    /// `ActivityQueue.cycle()`.
    case cycle
    /// `ActivityQueue.dismissCurrent()`.
    case dismissActivity
    /// `ActivityQueue.restoreLastDismissed()`.
    case restoreActivity
}

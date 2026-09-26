import Foundation
import Combine

/// Small transient bridge for the one hidden drawer's overflow state.
@MainActor
final class MenuBarArranger: ObservableObject {
    @Published private(set) var isArranging = false
    @Published private(set) var overflowsNotch = false
    @Published private(set) var overflowIconCount = 0
    @Published private(set) var notchOverflow = false

    /// Kept for the legacy marker bridge and headless self-test only. The normal
    /// icon-management path is `MenuBarIconManager` in Settings.
    var onChange: ((Bool) -> Void)?

    func setArranging(_ on: Bool) {
        guard on != isArranging else { return }
        isArranging = on
        if !on { overflowsNotch = false }
        onChange?(on)
    }

    func toggle() { setArranging(!isArranging) }

    func setOverflow(arrange: Bool, notch: Bool, iconCount: Int) {
        let arranging = isArranging && arrange
        let count = notch ? max(1, iconCount) : 0
        guard arranging != overflowsNotch || notch != notchOverflow || count != overflowIconCount else { return }
        overflowsNotch = arranging
        notchOverflow = notch
        overflowIconCount = count
    }
}

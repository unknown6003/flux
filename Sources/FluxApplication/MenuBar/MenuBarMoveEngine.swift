import Foundation
import FluxCore
import FluxPlatform

/// Runs one editor move against the real menu bar: read, plan, Cmd-drag,
/// then read again until the item sits between its requested neighbours.
/// Each attempt plans from a fresh read, so a partial move is corrected.
@MainActor struct MenuBarMoveEngine {
    static let attempts = 3

    /// A fresh layout, or nil when Accessibility is missing.
    var read: @MainActor () async throws(MenuBarMoveFailure) -> MenuBarLayout?
    var drag: @MainActor (CGPoint, CGPoint) async throws -> Void
    var inputIsQuiet: @MainActor () -> Bool
    var sleep: @Sendable (TimeInterval) async throws -> Void

    /// `progress` gets the attempt number, starting at 1, before each drag.
    func run(_ move: MenuBarItemMove, progress: @MainActor (Int) -> Void) async throws(MenuBarMoveFailure) {
        for attempt in 0..<Self.attempts {
            guard let layout = try await read() else { throw .accessibilityRequired }
            guard let plan = try MenuBarMovePlanner.plan(move, in: layout) else { return }
            if plan.target == .none { return }
            guard let points = MenuBarMovePlanner.dragPoints(for: plan, in: layout, attempt: attempt) else {
                throw .neighbourGone
            }
            try await waitForQuietInput()
            progress(attempt + 1)
            do { try await drag(points.from, points.to) }
            catch MenuBarItemDragError.inputBusy { throw .inputBusy }
            catch MenuBarItemDragError.eventsUnavailable { throw .eventsUnavailable }
            catch { throw .notAccepted }
            // MenuBarAgent settles a moved item in about half a second.
            for _ in 0..<6 {
                do { try await sleep(0.25) } catch { throw .notAccepted }
                guard let fresh = try await read() else { throw .accessibilityRequired }
                if MenuBarMovePlanner.isPlaced(move, in: fresh) { return }
            }
        }
        guard let last = try await read() else { throw .accessibilityRequired }
        if MenuBarMovePlanner.isPlaced(move, in: last) { return }
        throw .notAccepted
    }

    /// The user's own drop just ended. Wait for the button and modifier keys
    /// to come up, so the posted drag does not mix with real input.
    private func waitForQuietInput() async throws(MenuBarMoveFailure) {
        for _ in 0..<20 {
            if inputIsQuiet() { return }
            do { try await sleep(0.1) } catch { throw .inputBusy }
        }
        throw .inputBusy
    }
}

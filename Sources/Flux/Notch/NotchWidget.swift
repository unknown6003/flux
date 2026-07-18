import SwiftUI
import Combine

/// Stable identity for each notch widget — used for persistence (widget order,
/// last-used widget) and for `NotchState.expanded`, so the state machine and
/// settings never need to hold a live widget reference.
enum WidgetID: String, CaseIterable, Codable {
    case nowPlaying, shelf, calendar, mirror, timers, clipboard
}

/// A single pane of notch content: something that can render into the
/// expanded panel and, optionally, into the collapsed notch's side "wings".
///
/// Conforming types own their own headless service (Now Playing, Shelf, ...);
/// this protocol only describes the UI-facing surface plus the perf contract
/// that keeps a widget's cost at zero while it isn't visible.
@MainActor
protocol NotchWidget: AnyObject {
    var id: WidgetID { get }

    /// Settings-driven; the registry filters `enabledWidgets` on this so a
    /// disabled widget never appears in the cycle order or the expanded
    /// panel. Settable (rather than `{ get }`) so `NotchWidgetRegistry.
    /// setEnabled` — the one place the wiring agent should flip this — can
    /// write it uniformly across every conforming widget without each one
    /// exposing its own separate setter.
    var isEnabled: Bool { get set }

    /// Full content shown in the expanded notch panel.
    func makeExpandedView() -> AnyView

    /// Compact content rendered in the notch "wings" while collapsed (e.g. a
    /// tiny spinning record for Now Playing). `nil` means this widget has
    /// nothing worth showing collapsed.
    func makeCompactView() -> AnyView?

    /// Called exactly once when the widget becomes visible (the notch expands
    /// to it) — start whatever timers/sessions/subscriptions it needs.
    func willPresent()

    /// Called exactly once when the widget stops being visible (collapsed,
    /// swiped away, or disabled) — MUST stop everything `willPresent` started.
    /// This is the idle-CPU/RAM perf contract: a widget that keeps a timer or
    /// session alive after `didDismiss` is a bug.
    func didDismiss()
}

/// Registration + ordering for every notch widget. Widgets register themselves
/// once at launch, in registration order; `enabledWidgets` is the live,
/// settings-filtered, user-ordered list the UI and swipe-cycling actually walk.
@MainActor
final class NotchWidgetRegistry: ObservableObject {
    /// Every registered widget, in registration order — also the fallback
    /// order for any widget `order` hasn't placed yet.
    @Published private(set) var widgets: [NotchWidget] = []

    /// User-chosen widget order (persisted by the wiring agent from settings).
    /// Only entries naming a *registered* widget matter, so a stale id left
    /// over from a removed widget can't wedge the list.
    @Published var order: [WidgetID] = []

    /// Fires the id of a widget right after `setEnabled` actually changes its
    /// `isEnabled`. `NotchViewModel` is the one subscriber that matters: if
    /// the widget named here is the one currently `.expanded`, it re-resolves
    /// away from it instead of being left pointing at a widget that just
    /// dropped out of `enabledWidgets`.
    let enabledDidChange = PassthroughSubject<WidgetID, Never>()

    /// Enabled widgets, in `order`. Any registered-but-unordered widget (e.g.
    /// one added after `order` was last persisted) is appended afterward in
    /// registration order, so it still shows up somewhere sane instead of
    /// silently disappearing from the cycle.
    var enabledWidgets: [NotchWidget] {
        let byID = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
        var seen = Set<WidgetID>()
        var result: [NotchWidget] = []
        for id in order {
            guard seen.insert(id).inserted, let widget = byID[id], widget.isEnabled else { continue }
            result.append(widget)
        }
        for widget in widgets where widget.isEnabled && !seen.contains(widget.id) {
            seen.insert(widget.id)
            result.append(widget)
        }
        return result
    }

    /// Register a widget once at launch. A second registration of the same
    /// `id` is ignored — registration order must stay a stable, one-shot thing.
    func register(_ widget: NotchWidget) {
        guard !widgets.contains(where: { $0.id == widget.id }) else { return }
        widgets.append(widget)
    }

    func widget(for id: WidgetID) -> NotchWidget? {
        widgets.first { $0.id == id }
    }

    /// The one place a widget's enabled flag should be written — routes
    /// through the registry (rather than the wiring agent poking
    /// `widget.isEnabled` directly) so every enable/disable, for every
    /// widget, uniformly fires `enabledDidChange` and can never forget to.
    /// A no-op if `id` isn't registered, or the value isn't actually changing
    /// (so a settings sink that re-delivers the same value on every launch
    /// doesn't spuriously nudge `NotchViewModel`).
    func setEnabled(_ id: WidgetID, _ enabled: Bool) {
        guard let widget = widget(for: id), widget.isEnabled != enabled else { return }
        widget.isEnabled = enabled
        enabledDidChange.send(id)
    }

    /// The widget after `id` in the enabled/ordered cycle, wrapping around.
    /// `nil` only when there are no enabled widgets at all; falls back to the
    /// first enabled widget when `id` itself isn't (currently) one of them.
    func next(after id: WidgetID) -> WidgetID? {
        let ids = enabledWidgets.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        return ids[(index + 1) % ids.count]
    }

    /// The widget before `id`, wrapping around. `nil` only when there are no
    /// enabled widgets at all.
    func previous(before id: WidgetID) -> WidgetID? {
        let ids = enabledWidgets.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let index = ids.firstIndex(of: id) else { return ids.last }
        return ids[(index - 1 + ids.count) % ids.count]
    }
}

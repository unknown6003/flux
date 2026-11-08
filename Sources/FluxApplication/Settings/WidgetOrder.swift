import FluxCore

/// The saved `flux.notch.widgetOrder` list. Unknown IDs from a newer build
/// stay in place. A known ID keeps its first position only.
struct WidgetOrder: Equatable {
    private(set) var saved: [String]

    init(saved: [String]) {
        var seen = Set<Widget>()
        var result: [String] = []
        for raw in saved {
            if let widget = Widget(rawValue: raw) {
                guard seen.insert(widget).inserted else { continue }
            }
            result.append(raw)
        }
        for widget in Widget.allCases where !seen.contains(widget) {
            result.append(widget.rawValue)
        }
        self.saved = result
    }

    /// All known widgets, each once, in saved order.
    var widgets: [Widget] { saved.compactMap(Widget.init(rawValue:)) }

    /// Swaps `widget` with the nearest known widget before or after it.
    /// Returns false at either end. Unknown IDs keep their index.
    mutating func move(_ widget: Widget, up: Bool) -> Bool {
        guard let index = saved.firstIndex(of: widget.rawValue) else { return false }
        let neighbors = up
            ? Array(saved.indices[..<index].reversed())
            : Array(saved.indices[(index + 1)...])
        guard let other = neighbors.first(where: { Widget(rawValue: saved[$0]) != nil }) else { return false }
        saved.swapAt(index, other)
        return true
    }
}

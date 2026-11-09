import AppKit

/// Base for Settings pages built from sections of native controls.
/// `update` rebuilds the sections and gives focus back to the control with
/// the same identifier, so a state change keeps keyboard focus.
@MainActor
public class FormPageController: NSViewController, SettingsPageFocus {
    private let stack = FluxUIStyle.vstack([], spacing: FluxUIStyle.Form.sectionSpacing)
    private let controls = FormControls()

    public var preferredFirstResponder: NSView? { controls.firstControl }

    init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = FluxUIStyle.page(stack)
        rebuild()
    }

    /// Subclasses return their sections for the current state.
    func makeSections() -> [NSView] { [] }

    func rebuild() {
        guard isViewLoaded else { return }
        let focused = FormControls.focusedID(in: view.window)
        controls.reset()
        stack.setViews(makeSections(), in: .top)
        FormControls.restoreFocus(focused, in: stack)
    }

    func toggle(_ id: String, _ isOn: Bool, enabled: Bool = true, _ handler: @escaping (Bool) -> Void) -> NSSwitch {
        controls.toggle(id, isOn, enabled: enabled, handler)
    }

    func popup<T: Equatable>(_ id: String, _ options: [(String, T)], selected: T, enabled: Bool = true, _ handler: @escaping (T) -> Void) -> NSPopUpButton {
        controls.popup(id, options, selected: selected, enabled: enabled, handler)
    }

    func button(_ id: String, _ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSButton {
        controls.button(id, title, enabled: enabled, handler)
    }

    // One line per setting. A new setting is one more row in a section.

    func switchRow(_ id: String, _ title: String, help: String? = nil, isOn: Bool, enabled: Bool = true,
                   _ handler: @escaping (Bool) -> Void) -> NSView {
        FluxUIStyle.row(title, helper: help, control: toggle(id, isOn, enabled: enabled, handler))
    }

    func popupRow<T: Equatable>(_ id: String, _ title: String, help: String? = nil, _ options: [(String, T)], selected: T,
                                enabled: Bool = true, _ handler: @escaping (T) -> Void) -> NSView {
        FluxUIStyle.row(title, helper: help, control: popup(id, options, selected: selected, enabled: enabled, handler))
    }

    func buttonRow(_ id: String, _ title: String, help: String? = nil, action: String, enabled: Bool = true,
                   _ handler: @escaping () -> Void) -> NSView {
        FluxUIStyle.row(title, helper: help, control: button(id, action, enabled: enabled, handler))
    }
}

/// Makes native form controls and owns their targets. A page calls `reset()`
/// before it builds new controls, so old closures do not stay alive.
@MainActor
final class FormControls {
    private var targets: [ControlTarget] = []
    private(set) weak var firstControl: NSView?

    func reset() {
        targets.removeAll()
        firstControl = nil
    }

    private func bind(_ control: NSControl, _ id: String, _ handler: @escaping (NSControl) -> Void) {
        let target = ControlTarget(handler)
        targets.append(target)
        control.target = target
        control.action = #selector(ControlTarget.fire(_:))
        control.identifier = .init(id)
        if firstControl == nil { firstControl = control }
    }

    func toggle(_ id: String, _ isOn: Bool, enabled: Bool = true, _ handler: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
        control.state = isOn ? .on : .off
        control.isEnabled = enabled
        bind(control, id) { handler(($0 as? NSSwitch)?.state == .on) }
        return control
    }

    func popup<T: Equatable>(_ id: String, _ options: [(String, T)], selected: T, enabled: Bool = true, _ handler: @escaping (T) -> Void) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: options.map(\.0))
        control.selectItem(at: options.firstIndex { $0.1 == selected } ?? 0)
        control.isEnabled = enabled
        bind(control, id) { sender in
            let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? -1
            if options.indices.contains(index) { handler(options[index].1) }
        }
        return control
    }

    func button(_ id: String, _ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSButton {
        let control = NSButton(title: title, target: nil, action: nil)
        control.bezelStyle = .push
        control.isEnabled = enabled
        control.setAccessibilityLabel(title)
        bind(control, id) { _ in handler() }
        return control
    }

    /// The identifier of the focused control, read before a rebuild.
    static func focusedID(in window: NSWindow?) -> NSUserInterfaceItemIdentifier? {
        (window?.firstResponder as? NSView)?.identifier
    }

    /// Gives focus back to the control with `id` after a rebuild. If that
    /// control is now disabled, for example Move Up on the first row, focus
    /// goes to the nearest enabled control in the same row. If the row has
    /// none, focus does not move to a disabled control.
    static func restoreFocus(_ id: NSUserInterfaceItemIdentifier?, in root: NSView) {
        guard let id, let window = root.window, let match = find(id, in: root) else { return }
        if let target = focusTarget(for: match) { window.makeFirstResponder(target) }
    }

    static func focusTarget(for view: NSView) -> NSView? {
        if isFocusable(view) { return view }
        guard let peers = view.superview?.subviews, let index = peers.firstIndex(of: view) else { return nil }
        // Same distance: the later control wins, so a disabled Up goes to Down.
        let order = peers.indices.filter { $0 != index }.sorted {
            let a = abs($0 - index), b = abs($1 - index)
            return a == b ? $0 > $1 : a < b
        }
        return order.lazy.map { peers[$0] }.first(where: isFocusable)
    }

    private static func isFocusable(_ view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder else { return false }
        return (view as? NSControl)?.isEnabled ?? true
    }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in root: NSView) -> NSView? {
        if root.identifier == id { return root }
        for sub in root.subviews { if let hit = find(id, in: sub) { return hit } }
        return nil
    }
}

/// Holds one control's closure. The page owns it, so nothing outlives the page.
@MainActor
final class ControlTarget: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

/// Update progress, shown on About. Text is static.
public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case installing
    case failed(code: String)

    var text: String {
        switch self {
        case .idle: ""
        case .checking: L("update.checking", "Checking for updates…")
        case .upToDate: L("update.current", "Flux is up to date.")
        case .available(let version): String(format: L("update.available", "Version %@ is available."), version)
        case .installing: L("update.installing", "Installing the update…")
        case .failed(let code): String(format: L("update.failed", "Update check failed (%@)."), code)
        }
    }

    var isBusy: Bool { self == .checking || self == .installing }
}

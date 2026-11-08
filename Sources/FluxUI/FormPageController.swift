import AppKit

/// Base for Settings pages built from sections of native controls.
/// `update` rebuilds the sections and gives focus back to the control with
/// the same identifier, so a state change keeps keyboard focus.
@MainActor
public class FormPageController: NSViewController, SettingsPageFocus {
    private let stack = FluxUIStyle.vstack([], spacing: 20)
    private var targets: [ControlTarget] = []
    private weak var firstControl: NSView?

    public var preferredFirstResponder: NSView? { firstControl }

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
        let focused = (view.window?.firstResponder as? NSView)?.identifier
        targets.removeAll()
        firstControl = nil
        stack.setViews(makeSections(), in: .top)
        if let focused, let match = Self.find(focused, in: stack) {
            view.window?.makeFirstResponder(match)
        }
    }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in root: NSView) -> NSView? {
        if root.identifier == id { return root }
        for sub in root.subviews { if let hit = find(id, in: sub) { return hit } }
        return nil
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
}

/// Holds one control's closure. The page owns it, so nothing outlives the page.
@MainActor
final class ControlTarget: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

/// Update progress, shared by General and About. Text is static.
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
        case .failed(let code): String(format: L("update.failed", "The update check failed (%@)."), code)
        }
    }

    var isBusy: Bool { self == .checking || self == .installing }
}

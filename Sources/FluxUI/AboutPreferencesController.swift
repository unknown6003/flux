import AppKit

/// The parent's state for Copy Diagnostic Report. Static text only.
public enum DiagnosticStatus: Equatable, Sendable {
    case ready
    case copied
    case unavailable
}

/// Everything Settings › About shows. `version` and `build` come from the
/// app bundle. The parent sends a new value after each change.
public struct AboutPreferencesState: Equatable, Sendable {
    public let version: String
    public let build: String
    public let update: UpdateStatus
    public let diagnostics: DiagnosticStatus

    public init(version: String, build: String, update: UpdateStatus = .idle, diagnostics: DiagnosticStatus = .ready) {
        self.version = version
        self.build = build
        self.update = update
        self.diagnostics = diagnostics
    }
}

/// Requests from Settings › About. The parent copies the report and opens links.
public enum AboutPreferencesAction: Equatable, Sendable {
    case checkForUpdates
    case installUpdate
    case copyDiagnosticReport
    /// Show the MediaRemoteAdapter BSD 3-Clause license text.
    case openMediaRemoteAdapterLicense
    case openSourceRepository
}

/// Settings › About page. It only shows state and sends actions.
@MainActor
public final class AboutPreferencesController: FormPageController {
    public private(set) var state: AboutPreferencesState
    private let onAction: (AboutPreferencesAction) -> Void

    public init(state: AboutPreferencesState, onAction: @escaping (AboutPreferencesAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init()
    }

    /// Shows a new state. It never sends an action.
    public func update(state: AboutPreferencesState) {
        guard state != self.state else { return }
        self.state = state
        rebuild()
    }

    override func makeSections() -> [NSView] {
        [brand(), FluxUIStyle.section(L("about.updates", "Updates"), [
            updateRow(self, id: "about.updates.action", status: state.update) { [weak self] in self?.onAction($0 ? .installUpdate : .checkForUpdates) },
        ]), diagnosticSection(), creditSection()]
    }

    private func brand() -> NSView {
        let name = FluxUIStyle.label("Flux", style: .largeTitle, wraps: false)
        let version = FluxUIStyle.label(String(format: L("about.version", "Version %@ (%@)"), state.version, state.build), secondary: true)
        version.isSelectable = true
        let trust = FluxUIStyle.label(L("about.trust", "Self-signed. Not notarized."), style: .callout, secondary: true)
        return FluxUIStyle.vstack([name, version, trust], spacing: 4)
    }

    private func diagnosticSection() -> NSView {
        let copy = button("about.diagnostics.copy", L("about.diagnostics.copy", "Copy Diagnostic Report"), enabled: state.diagnostics != .unavailable) { [weak self] in
            self?.onAction(.copyDiagnosticReport)
        }
        let helper: String = switch state.diagnostics {
        case .ready: L("about.diagnostics.ready", "Copies fixed status lines to the clipboard. It has no IDs, file names or log text.")
        case .copied: L("about.diagnostics.copied", "Report copied to the clipboard.")
        case .unavailable: L("about.diagnostics.unavailable", "The report is not available now.")
        }
        return FluxUIStyle.section(L("about.diagnostics", "Diagnostics"), [
            FluxUIStyle.row(L("about.diagnostics.title", "Diagnostic report"), helper: helper, control: copy),
        ])
    }

    private func creditSection() -> NSView {
        let license = button("about.credits.license", L("about.credits.license", "View License")) { [weak self] in
            self?.onAction(.openMediaRemoteAdapterLicense)
        }
        license.setAccessibilityLabel(L("about.credits.license.ax", "View MediaRemoteAdapter license"))
        let source = button("about.credits.source", L("about.credits.source", "View Source")) { [weak self] in
            self?.onAction(.openSourceRepository)
        }
        source.setAccessibilityLabel(L("about.credits.source.ax", "View Flux source code"))
        return FluxUIStyle.section(L("about.credits", "Credits"), [
            FluxUIStyle.row(L("about.credits.media", "MediaRemoteAdapter"), helper: L(
                "about.credits.media.helper",
                "Now Playing uses MediaRemoteAdapter by Jonas van den Berg and contributors, under the BSD 3-Clause License."
            ), control: license),
            FluxUIStyle.row(L("about.credits.repo", "Source code"), helper: L("about.credits.repo.helper", "Flux source code is on GitHub."), control: source),
        ])
    }
}

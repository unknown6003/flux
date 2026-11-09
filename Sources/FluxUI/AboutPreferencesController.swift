import AppKit

/// The parent's state for Copy Diagnostic Report. Static text only.
public enum DiagnosticStatus: Equatable, Sendable {
    case ready
    case copied
    case unavailable
}

/// The parent's typed result from its last-session check. It holds no log
/// text, paths or error content. FluxUI shows fixed messages only.
public enum CrashNotice: Equatable, Sendable {
    case none
    /// The last run did not end cleanly. A crash, Force Quit or logout can cause this.
    case previousSessionUnclean(cameraWasRunning: Bool)
}

/// Everything Settings › About shows. `version` and `build` come from the
/// app bundle. The parent sends a new value after each change.
public struct AboutPreferencesState: Equatable, Sendable {
    public let version: String
    public let build: String
    public let automaticUpdateChecks: Bool
    public let update: UpdateStatus
    public let diagnostics: DiagnosticStatus
    public let crashNotice: CrashNotice

    public init(
        version: String,
        build: String,
        automaticUpdateChecks: Bool = true,
        update: UpdateStatus = .idle,
        diagnostics: DiagnosticStatus = .ready,
        crashNotice: CrashNotice = .none
    ) {
        self.version = version
        self.build = build
        self.automaticUpdateChecks = automaticUpdateChecks
        self.update = update
        self.diagnostics = diagnostics
        self.crashNotice = crashNotice
    }
}

/// Requests from Settings › About. The parent copies the report and opens links.
public enum AboutPreferencesAction: Equatable, Sendable {
    case setAutomaticUpdateChecks(Bool)
    case checkForUpdates
    case installUpdate
    case copyDiagnosticReport
    /// Hide the last-session notice. The parent saves that it was dismissed.
    case dismissCrashNotice
    /// Show the MediaRemoteAdapter BSD 3-Clause license text.
    case openMediaRemoteAdapterLicense
    case openSourceRepository
    /// The user chose Rate Flux…. The parent opens the rating form as a sheet.
    case rateFlux
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
        var sections = [brand()]
        if case .previousSessionUnclean(let camera) = state.crashNotice { sections.append(crashBanner(cameraWasRunning: camera)) }
        sections += [updateSection(), helpSection(), creditSection()]
        return sections
    }

    private func brand() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = FluxUIStyle.label("Flux", style: .title1, wraps: false)
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let version = FluxUIStyle.label(String(format: L("about.version", "Version %@ (%@)"), state.version, state.build),
                                        secondary: true, wraps: false)
        version.isSelectable = true
        let stack = NSStackView(views: [icon, name, version])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
        return stack
    }

    private func crashBanner(cameraWasRunning: Bool) -> NSView {
        var detail = L("about.crash.detail", "A crash, Force Quit or logout can cause this.")
        if cameraWasRunning { detail += " " + L("about.crash.camera", "The camera was on.") }
        let copy = button("about.crash.copy", L("about.crash.copy", "Copy Report"), enabled: state.diagnostics != .unavailable) { [weak self] in
            self?.onAction(.copyDiagnosticReport)
        }
        let dismiss = button("about.crash.dismiss", L("about.crash.dismiss", "Dismiss")) { [weak self] in
            self?.onAction(.dismissCrashNotice)
        }
        dismiss.setAccessibilityLabel(L("about.crash.dismiss.ax", "Dismiss last session notice"))
        let title = L("about.crash.title", "The last session did not close cleanly")
        let section = FluxUIStyle.section(nil, [
            FluxUIStyle.row(title, helper: detail, control: FluxUIStyle.hstack([dismiss, copy], spacing: 8)),
        ])
        section.setAccessibilityElement(true)
        section.setAccessibilityRole(.group)
        section.setAccessibilityLabel(title)
        return section
    }

    private func updateSection() -> NSView {
        let install: Bool
        if case .available = state.update { install = true } else { install = false }
        let status = state.update.text
        return FluxUIStyle.section(L("about.updates", "Updates"), [
            switchRow("about.updates.auto", L("about.updates.auto", "Check automatically"),
                      isOn: state.automaticUpdateChecks) { [weak self] in self?.onAction(.setAutomaticUpdateChecks($0)) },
            buttonRow("about.updates.action", L("about.updates.title", "Software update"), help: status.isEmpty ? nil : status,
                      action: install ? L("update.install", "Install Update") : L("update.check", "Check Now"),
                      enabled: !state.update.isBusy) { [weak self] in self?.onAction(install ? .installUpdate : .checkForUpdates) },
        ])
    }

    private func helpSection() -> NSView {
        let report: String? = switch state.diagnostics {
        case .ready: nil
        case .copied: L("about.diagnostics.copied", "Copied to the clipboard.")
        case .unavailable: L("about.diagnostics.unavailable", "Not available now.")
        }
        return FluxUIStyle.section(L("about.help", "Feedback"), [
            buttonRow("about.feedback.rate", L("about.feedback.title", "Rate Flux"), action: L("about.feedback.rate", "Rate…")) { [weak self] in
                self?.onAction(.rateFlux)
            },
            buttonRow("about.diagnostics.copy", L("about.diagnostics.title", "Diagnostic report"), help: report,
                      action: L("about.diagnostics.copy", "Copy Report"), enabled: state.diagnostics != .unavailable) { [weak self] in
                self?.onAction(.copyDiagnosticReport)
            },
        ])
    }

    private func creditSection() -> NSView {
        let source = button("about.credits.source", L("about.credits.source", "View on GitHub")) { [weak self] in
            self?.onAction(.openSourceRepository)
        }
        source.setAccessibilityLabel(L("about.credits.source.ax", "View Flux source code"))
        let license = button("about.credits.license", L("about.credits.license", "View License")) { [weak self] in
            self?.onAction(.openMediaRemoteAdapterLicense)
        }
        license.setAccessibilityLabel(L("about.credits.license.ax", "View MediaRemoteAdapter license"))
        return FluxUIStyle.section(L("about.credits", "Credits"), [
            FluxUIStyle.row(L("about.credits.repo", "Source code"), control: source),
            FluxUIStyle.row(L("about.credits.media", "MediaRemoteAdapter"), helper: L(
                "about.credits.media.helper", "Used by Now Playing. BSD 3-Clause License."
            ), control: license),
        ])
    }
}

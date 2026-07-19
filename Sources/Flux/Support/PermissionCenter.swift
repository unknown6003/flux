import AppKit
import ApplicationServices
import EventKit
import AVFoundation
import Combine
import OSLog

/// Shared logging point for the permission subsystem — mirrors `shelfLog`'s/
/// `powerLog`'s file-scope-constant pattern rather than adding a new case to
/// `Log.swift`, since this is a self-contained M4+ subsystem.
let permissionLog = Logger(subsystem: "com.flux.menubar", category: "permission")

/// Every TCC-gated capability the notch suite needs, across every milestone
/// that touches one — calendar (M4), camera (M6's mirror widget), and
/// accessibility (M5's media-key interception). Declared together, up front,
/// rather than growing this enum piecemeal per milestone, so `PermissionRow`
/// (`SettingsRows.swift`) and every call site can be written once and reused
/// as each later milestone turns its case on.
enum PermissionKind: String, CaseIterable {
    case calendar, camera, accessibility
}

/// A normalized status independent of any one framework's own authorization
/// enum (`EKAuthorizationStatus`, `AVAuthorizationStatus`, `AXIsProcessTrusted`'s
/// plain `Bool`) — the one vocabulary every permission-aware view in the app
/// speaks, so `PermissionRow` doesn't need a case for each framework's status
/// type.
enum PermissionStatus: Equatable {
    case notDetermined, granted, denied, restricted, unavailable
}

/// Unified TCC status/request center for every permission above. Ad-hoc
/// signing (see this app's own README) means a grant can be revoked by the
/// system on a re-sign — often surfacing as the user having to re-grant after
/// an update — so every consumer of `statuses` is expected to handle
/// `.denied`/`.restricted` gracefully rather than assuming a grant is
/// permanent once observed.
///
/// `refresh(_:)` is a plain re-query — cheap, synchronous, no prompt.
/// `request(_:)` is the one place that can trigger the system's own
/// permission dialog; calendar and camera hand back a real completion,
/// Accessibility does not (see its own doc comment below), which is why this
/// also refreshes every status on `NSApplication.didBecomeActiveNotification`
/// — the moment the user could plausibly be returning from having granted
/// (or revoked) something in System Settings.
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    /// Owned here purely for `requestFullAccessToEvents` — `CalendarService`
    /// owns its own separate `EKEventStore` for actually fetching events.
    /// TCC authorization is process-wide, not per-instance, so two instances
    /// never disagree about it; keeping them separate avoids coupling this
    /// permission-only type to the event-fetching one.
    private let eventStore: EKEventStore

    private var cancellables = Set<AnyCancellable>()

    init(eventStore: EKEventStore? = nil) {
        self.eventStore = eventStore ?? EKEventStore()
        for kind in PermissionKind.allCases {
            statuses[kind] = Self.currentStatus(for: kind, eventStore: self.eventStore)
        }
        observeAppActivation()
    }

    /// Catches the user coming back from System Settings (or from a system
    /// permission prompt) without this needing its own polling timer —
    /// activation is an existing, event-driven signal every app already gets
    /// for free.
    private func observeAppActivation() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                for kind in PermissionKind.allCases { self.refresh(kind) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Query

    /// Re-query one permission's live status. No prompt, cheap enough to call
    /// freely (e.g. from a widget's `willPresent()`).
    func refresh(_ kind: PermissionKind) {
        statuses[kind] = Self.currentStatus(for: kind, eventStore: eventStore)
    }

    private static func currentStatus(for kind: PermissionKind, eventStore: EKEventStore) -> PermissionStatus {
        switch kind {
        case .calendar:
            return mapCalendarStatus(EKEventStore.authorizationStatus(for: .event))
        case .camera:
            return mapCameraStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .accessibility:
            // No "not determined" concept here — the OS either trusts this
            // process or it doesn't, and `AXIsProcessTrusted()` never prompts
            // on its own (see `request(_:)` for the one call that can).
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }

    /// `.writeOnly` (macOS 14's "add events, but can't read the calendar")
    /// is intentionally mapped to `.denied` rather than a separate case —
    /// every consumer here (the Calendar widget's read-only agenda, the
    /// event-soon live activity) only ever *reads* events, so write-only
    /// access is exactly as useless to them as no access at all, and adding
    /// a fourth "partially granted" status solely to describe a grant this
    /// app can't use anyway isn't worth the API's extra surface area.
    static func mapCalendarStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .granted
        case .writeOnly: return .denied
        @unknown default: return .unavailable
        }
    }

    static func mapCameraStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        @unknown default: return .unavailable
        }
    }

    // MARK: - Request

    /// Trigger the system prompt where one exists. Calendar and camera hand
    /// back a real completion (dispatched from an arbitrary background
    /// thread by the framework — hopped back to the main actor the same way
    /// `ScriptingNowPlayingSource`'s AppleScript-queue callbacks do, via a
    /// plain `Task { @MainActor in ... }`); Accessibility's "prompt" is a
    /// system alert offering to open System Settings, with no completion at
    /// all — `observeAppActivation()` is what eventually notices the grant.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .calendar:
            eventStore.requestFullAccessToEvents { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        permissionLog.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
                    }
                    self?.refresh(.calendar)
                }
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in self?.refresh(.camera) }
            }
        case .accessibility:
            // `kAXTrustedCheckOptionPrompt` is imported as `Unmanaged<CFString>!`
            // (an audited CF-returning global), so it must be unwrapped with
            // `takeUnretainedValue()` before it can be used as a dictionary key.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Deep-links straight to this permission's own pane in System Settings —
    /// the one recovery path once a grant has been denied (`request(_:)`'s
    /// system dialog only ever prompts once per kind; after that, macOS
    /// expects the user to flip it manually).
    func openSystemSettings(_ kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .calendar: anchor = "Privacy_Calendars"
        case .camera: anchor = "Privacy_Camera"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

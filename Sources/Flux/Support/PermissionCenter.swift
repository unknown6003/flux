import AppKit
import EventKit
import AVFoundation
import Combine
import OSLog

/// Shared logging point for the permission subsystem — mirrors `shelfLog`'s/
/// `powerLog`'s file-scope-constant pattern rather than adding a new case to
/// `Log.swift`, since this is a self-contained M4+ subsystem.
let permissionLog = Logger(subsystem: "com.flux.menubar", category: "permission")

/// Every TCC-gated capability the notch suite needs — calendar (M4) and
/// camera (M6's mirror widget). Declared together, up front, rather than
/// growing this enum piecemeal per milestone, so `PermissionRow`
/// (`SettingsRows.swift`) and every call site can be written once and reused
/// as each later milestone turns its case on. M11 removed the third case,
/// `accessibility` (M5's media-key interception, deleted along with it) —
/// Calendar and Camera are now the only two permissions Flux ever requests.
enum PermissionKind: String, CaseIterable {
    case calendar, camera
}

/// A normalized status independent of any one framework's own authorization
/// enum (`EKAuthorizationStatus`, `AVAuthorizationStatus`) — the one
/// vocabulary every permission-aware view in the app speaks, so
/// `PermissionRow` doesn't need a case for each framework's status type.
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
/// permission dialog, and both calendar and camera hand back a real
/// completion — but this still also refreshes every status on
/// `NSApplication.didBecomeActiveNotification` for the moment the user could
/// plausibly be returning from having granted (or revoked) something
/// directly in System Settings, bypassing `request(_:)` entirely.
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
    /// freely (e.g. from a widget's `willPresent()`). Only actually writes
    /// `statuses[kind]` when the freshly-queried value differs from what's
    /// already there — `statuses` is `@Published`, and this is called on
    /// every `NSApplication.didBecomeActiveNotification` (`observeAppActivation`)
    /// for every `PermissionKind` at once, so an unconditional write would
    /// republish (and cascade through every downstream subscriber —
    /// `NotchActivityRouter`'s `permissions.$statuses` sink included) on
    /// every single app activation even when nothing about the permission
    /// actually changed.
    func refresh(_ kind: PermissionKind) {
        let current = Self.currentStatus(for: kind, eventStore: eventStore)
        guard statuses[kind] != current else { return }
        statuses[kind] = current
    }

    private static func currentStatus(for kind: PermissionKind, eventStore: EKEventStore) -> PermissionStatus {
        switch kind {
        case .calendar:
            return mapCalendarStatus(EKEventStore.authorizationStatus(for: .event))
        case .camera:
            return mapCameraStatus(AVCaptureDevice.authorizationStatus(for: .video))
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

    // MARK: - Fixture injection (dev/testing only)

    /// Directly overwrites one permission's status, bypassing the real TCC
    /// query entirely. Used by `NotchSnapshot` (`--snapshot-notch`) to render
    /// a gated widget's GRANTED content (Calendar's agenda, the Mirror
    /// preview) deterministically offscreen, without this process actually
    /// holding that grant. Mirrors `NowPlayingService.injectPreviewState` —
    /// never called from a live query path. `refresh(_:)` would simply
    /// overwrite this on the next real check, so a caller seeding a snapshot
    /// must inject AFTER anything — e.g. a widget's own `willPresent()` —
    /// that could trigger one, not before.
    func injectPreviewStatus(_ kind: PermissionKind, _ status: PermissionStatus) {
        statuses[kind] = status
    }

    // MARK: - Request

    /// Trigger the system prompt where one exists. Both Calendar and camera
    /// hand back a real completion, dispatched from an arbitrary background
    /// thread by the framework — hopped back to the main actor via a plain
    /// `Task { @MainActor in ... }`.
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
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

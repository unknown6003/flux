import SwiftUI
import AppKit

/// Wraps `CalendarService` + `PermissionCenter` as a `NotchWidget`: an
/// upcoming-events agenda (Today/Tomorrow) when calendar access is granted,
/// or a permission explainer with the one action that actually helps
/// (request access, or open System Settings) when it isn't. Owns no
/// calendar/permission state of its own — both are the single sources of
/// truth; this class only adapts them to the `NotchWidget` surface and
/// starts/stops the service on presentation.
@MainActor
final class CalendarWidget: NotchWidget {
    let id: WidgetID = .calendar

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchCalendarEnabled`. `NotchWidgetRegistry` reads this
    /// every time it computes `enabledWidgets`.
    var isEnabled: Bool

    let service: CalendarService
    let permissions: PermissionCenter

    /// Read fresh (not cached) every time `didDismiss()` runs — see
    /// `CalendarService`'s own doc comment on why this widget defers to the
    /// live setting rather than always stopping unconditionally. Wired by
    /// the wiring agent to `settings.notchActivityCalendarEventEnabled`.
    private let isEventSoonActivityEnabled: () -> Bool

    init(service: CalendarService,
         permissions: PermissionCenter,
         isEnabled: Bool = true,
         isEventSoonActivityEnabled: @escaping () -> Bool = { false }) {
        self.service = service
        self.permissions = permissions
        self.isEnabled = isEnabled
        self.isEventSoonActivityEnabled = isEventSoonActivityEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(CalendarExpandedView(service: service, permissions: permissions))
    }

    /// No compact/collapsed-strip presence — like `ShelfWidget`, the agenda
    /// only shows once expanded. The one collapsed-notch signal this feature
    /// has ("an event is starting soon") is already covered by the
    /// event-soon `LiveActivity` wing (see `NotchActivityRouter`), which
    /// exists independently of whether this widget itself is even enabled.
    func makeCompactView() -> AnyView? { nil }

    /// Starting is gated on the *current* permission status, re-checked
    /// every time this widget is presented — a grant made moments ago in
    /// System Settings (or one revoked by an ad-hoc re-sign, per this app's
    /// README) is picked up the next time the widget opens, not just at
    /// launch.
    func willPresent() {
        permissions.refresh(.calendar)
        if permissions.statuses[.calendar] == .granted {
            service.start()
        }
    }

    /// Stopping is conditional on the event-soon toggle rather than
    /// unconditional — if it's on, `NotchActivityRouter` still wants the
    /// service running after this widget closes. The reverse direction (the
    /// router stopping the service while this widget is still open) can't
    /// happen either: see `CalendarService`'s doc comment and
    /// `NotchActivityRouter.isCalendarWidgetPresented`.
    func didDismiss() {
        guard !isEventSoonActivityEnabled() else { return }
        service.stop()
    }
}

// MARK: - Expanded panel view

private struct CalendarExpandedView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var permissions: PermissionCenter

    private var status: PermissionStatus { permissions.statuses[.calendar] ?? .notDetermined }

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                explainer(
                    message: "Flux can show your upcoming events right in the notch.",
                    actionTitle: "Grant Access",
                    action: { permissions.request(.calendar) })
            case .denied, .restricted, .unavailable:
                explainer(
                    message: "Calendar access is off. Turn it on in System Settings to see your upcoming events here.",
                    actionTitle: "Open System Settings",
                    action: { permissions.openSystemSettings(.calendar) })
            case .granted:
                agenda
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Permission explainer

    private func explainer(message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accentColor.opacity(0.6))
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.fluxProminent)
                .frame(width: 170)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Agenda

    @ViewBuilder
    private var agenda: some View {
        let groups = CalendarService.groupByDay(events: service.upcoming, now: Date())
        if groups.today.isEmpty && groups.tomorrow.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if !groups.today.isEmpty {
                        section(title: "Today", events: groups.today)
                    }
                    if !groups.tomorrow.isEmpty {
                        section(title: "Tomorrow", events: groups.tomorrow)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentColor.opacity(0.5))
            Text("No upcoming events")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(title: String, events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
                .tracking(0.8)
            ForEach(events) { event in
                EventRow(event: event)
            }
        }
    }
}

/// One agenda row: a colored dot for the owning calendar, title, time range
/// (or an "All-day" badge), and an optional location caption.
private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: event.calendarColor ?? Theme.accent))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeRange)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                    if let location = event.location {
                        Text("· \(location)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var timeRange: String {
        if event.isAllDay { return "All-day" }
        return "\(Self.timeFormatter.string(from: event.start)) – \(Self.timeFormatter.string(from: event.end))"
    }

    /// Shared rather than one-per-row — mirrors `ShelfTileView.ageFormatter`'s
    /// reasoning for a formatter every row wants identically configured.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

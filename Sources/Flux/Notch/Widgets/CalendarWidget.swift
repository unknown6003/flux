import SwiftUI
import AppKit

/// Wraps `CalendarService` + `PermissionCenter` as a `NotchWidget`: an
/// upcoming-events agenda (Today/Tomorrow) when calendar access is granted,
/// or a permission explainer (via the shared `PermissionGatedView`) with the
/// one action that actually helps (request access, or open System Settings)
/// when it isn't. Owns no calendar/permission state of its own — both are
/// the single sources of truth; this class only adapts them to the
/// `NotchWidget` surface.
///
/// ## Ownership note: this widget does NOT start/stop `CalendarService`
/// That used to be split between this widget's own `willPresent`/
/// `didDismiss` and `NotchActivityRouter`'s settings-driven lifecycle — a
/// code review found that shape let a permission grant made while this
/// widget was open never actually start the service (neither owner's own
/// condition was individually true at that instant), among other cross-owner
/// bugs. The fix made `NotchActivityRouter` the SOLE owner of
/// `service.start()`/`.stop()` — see its `calendarServiceShouldRun` and
/// `CalendarService`'s own doc comment — driven by the notch's state machine
/// (is this widget the one expanded?), calendar permission, settings, and
/// presentation. `willPresent()` below only refreshes the permission status,
/// which the router's own `permissions.$statuses` subscription then reacts
/// to on its own.
@MainActor
final class CalendarWidget: NotchWidget {
    let id: WidgetID = .calendar

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchCalendarEnabled`. `NotchWidgetRegistry` reads this
    /// every time it computes `enabledWidgets`.
    var isEnabled: Bool

    let service: CalendarService
    let permissions: PermissionCenter

    init(service: CalendarService,
         permissions: PermissionCenter,
         isEnabled: Bool = true) {
        self.service = service
        self.permissions = permissions
        self.isEnabled = isEnabled
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

    /// Re-checks the *current* permission status every time this widget is
    /// presented — a grant made moments ago in System Settings (or one
    /// revoked by an ad-hoc re-sign, per this app's README) is picked up the
    /// next time the widget opens, not just at launch. See the type's own
    /// doc comment: this is the ONLY thing `willPresent` does now —
    /// `NotchActivityRouter` owns starting the service, and reacts to this
    /// same permission refresh on its own.
    func willPresent() {
        permissions.refresh(.calendar)
    }

    /// Nothing to do — see the type's own doc comment on why stopping the
    /// service is no longer this widget's responsibility at all.
    func didDismiss() {}
}

// MARK: - Expanded panel view

/// The expanded panel: the permission explainer/agenda split is now entirely
/// `PermissionGatedView`'s job (see that type's own doc comment) — this view
/// only supplies the calendar-specific copy/icon and the agenda content shown
/// once granted.
private struct CalendarExpandedView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        PermissionGatedView(
            kind: .calendar,
            permissions: permissions,
            icon: "calendar",
            notDeterminedMessage: "Flux can show your upcoming events right in the notch.",
            deniedMessage: "Calendar access is off. Turn it on in System Settings to see your upcoming events here."
        ) {
            agenda
        }
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

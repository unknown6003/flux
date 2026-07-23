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
        // Bug fix (M8): `NotchRootView`'s Duo layout gives this pane chrome's
        // 16pt horizontal inset only on the panel's own outer edge, nothing
        // on the inner edge against the divider — see `NotchDesign.
        // paneInsets`'s own doc comment for why this is applied
        // symmetrically rather than only on the divider-facing side.
        .padding(.horizontal, NotchDesign.paneInsets)
    }

    // MARK: Agenda

    /// Alcove refit (M7): this panel's total height budget is 190, minus
    /// fixed padding (top `notchHeight + 6`, bottom 18 — bumped from 14 when
    /// the 32pt corner radius clipped content) leaves a usable
    /// content height of roughly 100–150. A section header (9pt, ~11pt line
    /// height) + 6pt spacing to its first row, then N rows of ~28pt
    /// (12pt title line + 2pt inner spacing + 10pt time line, ~14+2+12) each
    /// separated by 6pt: header(11) + 6 + 4×28 + 3×6 = 11+6+112+18 = 147 —
    /// right at the top of the usable range for a *single* section at 4
    /// visible rows, which is why only ~4 rows are expected to show before
    /// the `ScrollView` below takes over (a second section, e.g. Tomorrow,
    /// scrolls into view rather than both being guaranteed on-screen at
    /// once).
    @ViewBuilder
    private var agenda: some View {
        let groups = CalendarService.groupByDay(events: service.upcoming, now: Date())
        if groups.today.isEmpty && groups.tomorrow.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: NotchDesign.sectionSpacing) {
                    if !groups.today.isEmpty {
                        section(title: "Today", events: groups.today)
                    }
                    if !groups.tomorrow.isEmpty {
                        section(title: "Tomorrow", events: groups.tomorrow)
                    }
                }
                // Bug fix (M8): without this, an unconstrained-width VStack
                // inside a ScrollView takes its own intrinsic (widest-row)
                // width and centers within the ScrollView's full width by
                // default — the "floats with huge dead margins left AND
                // right" bug. Leading-aligning it across the full available
                // width is the actual fix; `NotchDesign.paneInsets` above
                // (on `CalendarExpandedView.body`) only handles the
                // Duo-pane divider gap, a separate concern.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                // Bug fix (M8): the extra bottom inset `notchScrollFade`
                // expects, so the last row's real content clears the fade
                // zone instead of fading out from underneath it.
                .padding(.bottom, 2 + NotchDesign.scrollFadeContentInset)
            }
            .notchScrollFade()
        }
    }

    private var emptyState: some View {
        WidgetEmptyStateView(icon: "calendar", message: "No upcoming events")
    }

    private func section(title: String, events: [CalendarEvent]) -> some View {
        // Row spacing here stays a literal 6, not `NotchDesign.rowSpacing`
        // (8) — this panel's height budget is already documented above
        // (`agenda`'s own doc comment) as landing right at the top of its
        // usable range at 4 visible rows; the extra 2pt × 3 gaps `rowSpacing`
        // would add is enough to reintroduce the very clipping this pass
        // fixed elsewhere.
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(NotchDesign.microFont)
                .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
                .tracking(0.7)
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
        HStack(alignment: .top, spacing: NotchDesign.rowSpacing) {
            // The one deliberately colorful element in this near-monochrome
            // panel (Alcove's own agenda dot) — an event's real calendar
            // color when it has one. An event with no calendar color at all
            // falls back to a neutral white dot rather than the old amber,
            // since a colorless fallback isn't actually "the event's
            // calendar color" and shouldn't borrow the accent just to have
            // *a* color.
            Circle()
                .fill(event.calendarColor.map { Color(nsColor: $0) } ?? Color.white.opacity(NotchDesign.tertiaryOpacity))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: NotchDesign.space1) {
                    Text(timeRange)
                        .font(NotchDesign.monoDigitsCaption)
                        .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
                    if let location = event.location {
                        Text("· \(location)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
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

    /// Shared rather than one-per-row — mirrors `Formatters.relativeAge`'s
    /// reasoning for a formatter every row wants identically configured.
    /// Not itself shared via `Formatters` (a `DateFormatter` configured for
    /// time-of-day, not `ShelfTileView`/`ClipboardRow`'s relative-age
    /// `RelativeDateTimeFormatter`) — nothing else in the notch suite wants
    /// this exact style, unlike the byte-identical case `Formatters.
    /// relativeAge` was pulled out of.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

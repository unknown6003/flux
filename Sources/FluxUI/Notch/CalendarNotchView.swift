import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/Widgets/CalendarWidget.swift
// (CalendarExpandedView and EventRow). Text, layout and styles are unchanged.

@MainActor
final class CalendarNotchModel: ObservableObject {
    @Published var state: CalendarWidgetState
    let onAction: @MainActor (CalendarWidgetAction) -> Void

    init(state: CalendarWidgetState, onAction: @escaping @MainActor (CalendarWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
    }

    var gate: NotchPermissionGate {
        switch state {
        case .needsPermission: .notDetermined
        case .unavailable: .denied
        case .loading, .events: .granted
        }
    }
}

struct CalendarExpandedView: View {
    @ObservedObject var model: CalendarNotchModel
    @Environment(\.isNarrowPane) private var compact

    var body: some View {
        PermissionGatedView(
            status: model.gate,
            icon: "calendar",
            notDeterminedMessage: "Flux can show your upcoming events right in the notch.",
            deniedMessage: "Calendar access is off. Turn it on in System Settings to see your upcoming events here.",
            request: { model.onAction(.requestAccess) },
            openSettings: { model.onAction(.openSettings) }
        ) {
            agenda
        }
        .padding(.horizontal, NotchDesign.paneInsets)
    }

    @ViewBuilder
    private var agenda: some View {
        let groups = groups
        if groups.today.isEmpty && groups.tomorrow.isEmpty {
            WidgetEmptyStateView(icon: "calendar", message: "No upcoming events")
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.bottom, 2 + NotchDesign.scrollFadeContentInset)
            }
            .notchScrollFade()
        }
    }

    private var groups: (today: [CalendarWidgetEvent], tomorrow: [CalendarWidgetEvent]) {
        if case .events(let today, let tomorrow) = model.state { return (today, tomorrow) }
        return ([], [])
    }

    private func section(title: String, events: [CalendarWidgetEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(NotchDesign.microFont)
                .foregroundStyle(NotchDesign.tertiaryColor)
                .tracking(0.7)
            ForEach(events, id: \.id) { event in
                CalendarEventRow(event: event, compact: compact)
            }
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarWidgetEvent
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: NotchDesign.rowSpacing) {
            Circle()
                .fill(event.color.map { Color(nsColor: $0.nsColor) } ?? NotchDesign.tertiaryColor)
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(NotchDesign.primaryColor)
                    .lineLimit(1)
                HStack(spacing: NotchDesign.space1) {
                    Text(timeRange)
                        .font(NotchDesign.monoDigitsCaption)
                        .foregroundStyle(NotchDesign.secondaryColor)
                        .lineLimit(1)
                    if !compact, let location = event.location {
                        Text("· \(location)")
                            .font(.caption2)
                            .foregroundStyle(NotchDesign.tertiaryColor)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var timeRange: String {
        if event.isAllDay { return "All-day" }
        let start = Self.timeFormatter.string(from: event.start)
        guard !compact else { return start }
        return "\(start) – \(Self.timeFormatter.string(from: event.end))"
    }

    @MainActor private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

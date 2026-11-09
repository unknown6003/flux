import Foundation
import FluxPlatform

/// Preserve the saved Duo rule, including tomorrow morning after 20:00.
/// This policy reads no store and creates no timer.
enum DuoCalendarPolicy {
    static func events(_ snapshot: AgendaSnapshot, at now: Date,
                       calendar: Calendar = .current) -> [AgendaEntry] {
        let today = calendar.startOfDay(for: now)
        guard snapshot.today == today,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow) else { return [] }
        let evening = calendar.component(.hour, from: now) >= 20
        return snapshot.entries.filter {
            $0.end > now && (($0.start < tomorrow && $0.end > today)
                || (evening && $0.start >= tomorrow && $0.start < noon))
        }
    }

    static func hasEvents(_ snapshot: AgendaSnapshot, at now: Date,
                          calendar: Calendar = .current) -> Bool {
        !events(snapshot, at: now, calendar: calendar).isEmpty
    }

    static func nextBoundary(_ snapshot: AgendaSnapshot, after now: Date,
                             calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard snapshot.today == today,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        var candidates = snapshot.entries.map(\.end).filter { $0 > now && $0 < tomorrow }
        candidates.append(tomorrow)
        if let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today), evening > now {
            candidates.append(evening)
        }
        return candidates.min()
    }
}

import Foundation

/// Pushing a message out of the way until it actually matters.
///
/// A snoozed message leaves the inbox entirely rather than sitting there greyed
/// out, because a list you have trained yourself to skip is the same as no list.
/// When it comes back it comes back UNREAD, so the tab's dot lights up: the point
/// of snoozing is to be reminded, not to hide something permanently.
enum Snooze: String, CaseIterable, Identifiable {
    case hour
    case threeHours
    case evening
    case tomorrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: return "For an Hour"
        case .threeHours: return "For 3 Hours"
        case .evening: return "Until This Evening"
        case .tomorrow: return "Until Tomorrow"
        }
    }

    /// When the message should come back.
    ///
    /// `now` is a parameter so this can be tested at any hour of the day rather
    /// than only at whatever time the suite happens to run.
    static func date(for option: Snooze, from now: Date,
                     calendar: Calendar = .current) -> Date {
        switch option {
        case .hour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)

        case .evening:
            // "This evening" has to mean a future evening. Asking for it at 9pm
            // must not hand back a time that has already passed.
            let target = at(hour: 18, on: now, calendar: calendar)
            guard target.timeIntervalSince(now) > 900 else {
                return at(hour: 18, on: nextDay(now, calendar), calendar: calendar)
            }
            return target

        case .tomorrow:
            return at(hour: 9, on: nextDay(now, calendar), calendar: calendar)
        }
    }

    private static func nextDay(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }

    private static func at(hour: Int, on date: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        return calendar.date(from: parts) ?? date
    }

    /// How a snoozed row describes itself while it is put away.
    static func label(until date: Date, from now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "Back at \(formatter.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "h:mm a"
            return "Back tomorrow, \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EEE h:mm a"
        return "Back \(formatter.string(from: date))"
    }
}

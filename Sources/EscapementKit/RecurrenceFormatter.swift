import Foundation

/// Renders a `Recurrence` as a short, plain-language sentence for the status
/// list and the editor ("Daily at 3:00 AM", "Weekdays at 2:00 AM").
///
/// Lives in the kit, not the app, so the wording is unit-tested. Time-of-day is
/// formatted through the caller's locale so 12- and 24-hour clocks both read
/// naturally.
public struct RecurrenceFormatter: Sendable {

    private let calendar: Calendar
    private let locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    public func summary(_ recurrence: Recurrence) -> String {
        switch recurrence.kind {
        case .hourly(let everyHours, let minute, let window):
            let every =
                everyHours == 1 ? "Every hour" : "Every \(everyHours) hours"
            let padded = String(format: "%02d", minute)
            var summary = "\(every) at :\(padded)"
            if let window {
                let overnight = window.isOvernight ? "overnight " : ""
                summary += " \(overnight)from \(formatted(window.start)) to \(formatted(window.end))"
            }
            return summary

        case .daily(let everyDays):
            if everyDays == 1 {
                return "Daily at \(times(recurrence.times))"
            }
            return "Every \(everyDays) days at \(times(recurrence.times))"

        case .weekly(let weekdays):
            return "\(weekdayPhrase(weekdays)) at \(times(recurrence.times))"

        case .monthly(let days):
            return "Monthly on the \(dayPhrase(days)) at \(times(recurrence.times))"
        }
    }

    // MARK: - Times

    private func times(_ times: [TimeOfDay]) -> String {
        join(times.map(formatted))
    }

    private func formatted(_ time: TimeOfDay) -> String {
        var reference = calendar
        reference.locale = locale
        let date = reference.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: time.hour, minute: time.minute))!
        let formatter = DateFormatter()
        formatter.calendar = reference
        formatter.locale = locale
        // Assigning `calendar` does *not* set the formatter's time zone — that
        // is a separate property which otherwise defaults to the machine's.
        // Without this the instant built above (in the injected calendar's
        // zone) is rendered in the host's zone instead, so the summary reads a
        // different clock time than the user chose.
        formatter.timeZone = reference.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Weekdays

    private func weekdayPhrase(_ weekdays: Set<Weekday>) -> String {
        let weekdaysOnly: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        let weekendOnly: Set<Weekday> = [.saturday, .sunday]
        if weekdays.count == 7 { return "Every day" }
        if weekdays == weekdaysOnly { return "Weekdays" }
        if weekdays == weekendOnly { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols  // index 0 == Sunday
        let names = Weekday.allCases
            .filter { weekdays.contains($0) }
            .map { symbols[$0.rawValue - 1] }
        return join(names)
    }

    // MARK: - Days of month

    private func dayPhrase(_ days: Set<Int>) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        let ordinals = days.sorted().map { formatter.string(from: NSNumber(value: $0)) ?? "\($0)" }
        return join(ordinals)
    }

    // MARK: - Joining

    private func join(_ parts: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: parts) ?? parts.joined(separator: ", ")
    }
}

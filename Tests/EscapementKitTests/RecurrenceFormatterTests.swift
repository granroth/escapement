import Foundation
import Testing

@testable import EscapementKit

private func formatter() -> RecurrenceFormatter {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Phoenix")!
    let locale = Locale(identifier: "en_US")
    cal.locale = locale
    return RecurrenceFormatter(calendar: cal, locale: locale)
}

private func t(_ h: Int, _ m: Int = 0) -> TimeOfDay { TimeOfDay(hour: h, minute: m)! }

/// Normalises the various Unicode spaces ICU may place before AM/PM (a narrow
/// no-break space on current macOS) to a plain space, so the tests assert the
/// wording rather than an OS-version-specific separator codepoint.
private func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

@Suite("RecurrenceFormatter")
struct RecurrenceFormatterTests {
    private let f = formatter()

    private func summary(_ r: Recurrence) -> String { norm(f.summary(r)) }

    @Test("hourly reads as an interval and a minute")
    func hourly() {
        #expect(summary(.hourly(everyHours: 4, minute: 30)!) == "Every 4 hours at :30")
        #expect(summary(.hourly(everyHours: 1, minute: 0)!) == "Every hour at :00")
    }

    @Test("daily reads with a 12-hour time in en_US")
    func daily() {
        #expect(summary(.daily(times: [t(3)])!) == "Daily at 3:00 AM")
        #expect(summary(.daily(times: [t(14, 5)])!) == "Daily at 2:05 PM")
    }

    @Test("multiple daily times are listed")
    func multipleTimes() {
        #expect(summary(.daily(times: [t(3), t(14)])!) == "Daily at 3:00 AM and 2:00 PM")
    }

    @Test("weekday-only selection reads as Weekdays")
    func weekdays() {
        let r = Recurrence.weekly(
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday], times: [t(2)])!
        #expect(summary(r) == "Weekdays at 2:00 AM")
    }

    @Test("weekend-only selection reads as Weekends")
    func weekends() {
        #expect(summary(.weekly(weekdays: [.saturday, .sunday], times: [t(2)])!)
            == "Weekends at 2:00 AM")
    }

    @Test("all seven days reads as Every day")
    func everyDay() {
        #expect(summary(.weekly(weekdays: Set(Weekday.allCases), times: [t(2)])!)
            == "Every day at 2:00 AM")
    }

    @Test("an arbitrary weekday set lists the days in week order")
    func someWeekdays() {
        let r = Recurrence.weekly(weekdays: [.wednesday, .monday], times: [t(4)])!
        #expect(summary(r) == "Mon and Wed at 4:00 AM")
    }

    @Test("monthly reads with ordinal days")
    func monthly() {
        #expect(summary(.monthly(days: [1], times: [t(5)])!) == "Monthly on the 1st at 5:00 AM")
        #expect(
            summary(.monthly(days: [1, 15, 31], times: [t(5)])!)
                == "Monthly on the 1st, 15th, and 31st at 5:00 AM")
    }
}

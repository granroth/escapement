import Foundation
import Testing

@testable import EscapementKit

private func calendar(_ tz: String = "America/Phoenix") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    calendar().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func t(_ h: Int, _ m: Int = 0) -> TimeOfDay { TimeOfDay(hour: h, minute: m)! }

@Suite("Daily interval")
struct DailyIntervalTests {
    private let cal = calendar()

    @Test("every day is unchanged when the interval is one")
    func everyDay() {
        let r = Recurrence.daily(everyDays: 1, times: [t(3)])!
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 4, 0), calendar: cal, anchor: date(2026, 3, 1))
                == date(2026, 3, 11, 3, 0))
    }

    @Test("daily(times:) still means every day")
    func convenienceIsEveryDay() {
        let r = Recurrence.daily(times: [t(3)])!
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 4, 0), calendar: cal)
                == date(2026, 3, 11, 3, 0))
    }

    @Test("every other day fires on the anchor day parity")
    func everyOtherDay() {
        // Anchor on the 1st; every 2 days -> 1st, 3rd, 5th, ...
        let anchor = date(2026, 3, 1, 12, 0)
        let r = Recurrence.daily(everyDays: 2, times: [t(3)])!
        // From the 2nd, the next fire is the 3rd (odd offset from the 1st).
        #expect(
            r.nextFireDate(after: date(2026, 3, 2, 0, 0), calendar: cal, anchor: anchor)
                == date(2026, 3, 3, 3, 0))
        // From the 3rd after its time, next is the 5th (the 4th is skipped).
        #expect(
            r.nextFireDate(after: date(2026, 3, 3, 4, 0), calendar: cal, anchor: anchor)
                == date(2026, 3, 5, 3, 0))
    }

    @Test("every third day counts from the anchor")
    func everyThirdDay() {
        let anchor = date(2026, 3, 10, 9, 0)
        let r = Recurrence.daily(everyDays: 3, times: [t(2)])!
        // Anchor day is the 10th -> fires 10th, 13th, 16th.
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 0, 0), calendar: cal, anchor: anchor)
                == date(2026, 3, 13, 2, 0))
    }

    @Test("interval is validated")
    func validation() {
        #expect(Recurrence.daily(everyDays: 0, times: [t(3)]) == nil)
        #expect(Recurrence.daily(everyDays: 367, times: [t(3)]) == nil)
        #expect(Recurrence.daily(everyDays: 1, times: [t(3)]) != nil)
        #expect(Recurrence.daily(everyDays: 366, times: [t(3)]) != nil)
    }
}

@Suite("Hourly window")
struct HourlyWindowTests {
    private let cal = calendar()

    @Test("no window fires all day, unchanged")
    func allDay() {
        let r = Recurrence.hourly(everyHours: 4, minute: 30)!
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 20, 31), calendar: cal)
                == date(2026, 3, 11, 0, 30))
    }

    @Test("a window restricts which anchored times fire")
    func windowRestricts() {
        // Every 4 hours at :30 -> 00:30 04:30 08:30 12:30 16:30 20:30.
        // Window 08:00–18:00 keeps 08:30 12:30 16:30.
        let window = TimeWindow(start: t(8), end: t(18))!
        let r = Recurrence.hourly(everyHours: 4, minute: 30, window: window)!
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 6, 0), calendar: cal)
                == date(2026, 3, 10, 8, 30))
        // After 16:30 the next is the following day's 08:30, not 20:30.
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 16, 31), calendar: cal)
                == date(2026, 3, 11, 8, 30))
    }

    @Test("the window is inclusive of its endpoints")
    func inclusiveEndpoints() {
        let window = TimeWindow(start: t(8, 30), end: t(16, 30))!
        let r = Recurrence.hourly(everyHours: 4, minute: 30, window: window)!
        // 08:30 (start) is included.
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 6, 0), calendar: cal)
                == date(2026, 3, 10, 8, 30))
        // 16:30 (end) is included, so after 12:30 the next is 16:30.
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 12, 30), calendar: cal)
                == date(2026, 3, 10, 16, 30))
    }

    @Test("a window rejects start after end")
    func rejectsInverted() {
        #expect(TimeWindow(start: t(18), end: t(8)) == nil)
        #expect(TimeWindow(start: t(8), end: t(8)) != nil)  // a single-instant window is allowed
    }

    @Test("TimeWindow.contains is inclusive")
    func contains() {
        let w = TimeWindow(start: t(8), end: t(18))!
        #expect(w.contains(t(8)))
        #expect(w.contains(t(18)))
        #expect(w.contains(t(12)))
        #expect(!w.contains(t(7, 59)))
        #expect(!w.contains(t(18, 1)))
    }
}

@Suite("Refinement backward compatibility")
struct RefinementCodingTests {
    private func decode(_ json: String) throws -> Recurrence {
        try JSONDecoder().decode(Recurrence.self, from: Data(json.utf8))
    }

    @Test("a first-cut daily config (no everyDays) decodes as every day")
    func oldDaily() throws {
        let r = try decode(#"{"kind":{"daily":{}},"times":[{"hour":3,"minute":0}]}"#)
        guard case .daily(let everyDays) = r.kind else {
            Issue.record("expected daily, got \(r.kind)")
            return
        }
        #expect(everyDays == 1)
    }

    @Test("a first-cut hourly config (no window) decodes with no window")
    func oldHourly() throws {
        let r = try decode(#"{"kind":{"hourly":{"everyHours":4,"minute":30}},"times":[]}"#)
        guard case .hourly(let everyHours, let minute, let window) = r.kind else {
            Issue.record("expected hourly, got \(r.kind)")
            return
        }
        #expect(everyHours == 4)
        #expect(minute == 30)
        #expect(window == nil)
    }

    @Test("daily interval round-trips")
    func dailyRoundTrip() throws {
        let original = Recurrence.daily(everyDays: 2, times: [t(3)])!
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Recurrence.self, from: data) == original)
    }

    @Test("hourly window round-trips")
    func hourlyWindowRoundTrip() throws {
        let original = Recurrence.hourly(
            everyHours: 4, minute: 30, window: TimeWindow(start: t(8), end: t(18))!)!
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Recurrence.self, from: data) == original)
    }

    @Test("an inverted window in a decoded config is rejected")
    func invertedWindowRejected() {
        #expect(throws: (any Error).self) {
            try decode(
                #"{"kind":{"hourly":{"everyHours":4,"minute":0,"window":{"start":{"hour":18,"minute":0},"end":{"hour":8,"minute":0}}}},"times":[]}"#)
        }
    }
}

@Suite("Refinement formatting")
struct RefinementFormatterTests {
    private func f() -> RecurrenceFormatter {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        let locale = Locale(identifier: "en_US")
        cal.locale = locale
        return RecurrenceFormatter(calendar: cal, locale: locale)
    }
    private func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test("every-N-days reads with the interval")
    func everyNDays() {
        #expect(norm(f().summary(.daily(everyDays: 1, times: [t(3)])!)) == "Daily at 3:00 AM")
        #expect(norm(f().summary(.daily(everyDays: 2, times: [t(3)])!)) == "Every 2 days at 3:00 AM")
        #expect(norm(f().summary(.daily(everyDays: 3, times: [t(3)])!)) == "Every 3 days at 3:00 AM")
    }

    @Test("hourly window appends a from/to phrase")
    func hourlyWindow() {
        #expect(norm(f().summary(.hourly(everyHours: 4, minute: 30)!)) == "Every 4 hours at :30")
        let windowed = Recurrence.hourly(
            everyHours: 4, minute: 30, window: TimeWindow(start: t(8), end: t(18))!)!
        #expect(norm(f().summary(windowed)) == "Every 4 hours at :30 from 8:00 AM to 6:00 PM")
    }
}

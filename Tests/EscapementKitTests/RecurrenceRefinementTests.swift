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
        let window = TimeWindow(start: t(8), end: t(18))
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
        let window = TimeWindow(start: t(8, 30), end: t(16, 30))
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

    @Test("start after end now constructs as an overnight window")
    func invertedConstructsOvernight() {
        let w = TimeWindow(start: t(18), end: t(8))
        #expect(w.isOvernight)
        #expect(!TimeWindow(start: t(8), end: t(18)).isOvernight)
        #expect(!TimeWindow(start: t(8), end: t(8)).isOvernight)  // equal stays same-day
    }

    @Test("TimeWindow.contains is inclusive")
    func contains() {
        let w = TimeWindow(start: t(8), end: t(18))
        #expect(w.contains(t(8)))
        #expect(w.contains(t(18)))
        #expect(w.contains(t(12)))
        #expect(!w.contains(t(7, 59)))
        #expect(!w.contains(t(18, 1)))
    }

    @Test("an overnight window contains the wrap on both sides of midnight")
    func overnightContains() {
        let w = TimeWindow(start: t(23), end: t(4))
        #expect(w.contains(t(23)))
        #expect(w.contains(t(23, 59)))
        #expect(w.contains(t(0)))
        #expect(w.contains(t(2)))
        #expect(w.contains(t(4)))
        #expect(!w.contains(t(4, 1)))
        #expect(!w.contains(t(12)))
        #expect(!w.contains(t(22, 59)))
    }

    @Test("equal endpoints stay a single instant, not the whole day")
    func equalEndpointsAreOneInstant() {
        let w = TimeWindow(start: t(8), end: t(8))
        #expect(w.contains(t(8)))
        #expect(!w.contains(t(7, 59)))
        #expect(!w.contains(t(8, 1)))
        #expect(!w.contains(t(0)))
    }

    @Test("a one-minute wrap contains exactly its two endpoints")
    func oneMinuteWrap() {
        let w = TimeWindow(start: t(23, 59), end: t(0))
        #expect(w.contains(t(23, 59)))
        #expect(w.contains(t(0)))
        #expect(!w.contains(t(23, 58)))
        #expect(!w.contains(t(0, 1)))
    }

    @Test("a boundary literal at midnight classifies as same-day, not overnight")
    func startAtMidnightIsSameDay() {
        let w = TimeWindow(start: t(0), end: t(4))
        #expect(!w.isOvernight)
        #expect(w.contains(t(2)))
        #expect(!w.contains(t(5)))
    }

    @Test("adjacent endpoints anywhere in the day collapse the window to match everything")
    func adjacentEndpointsMatchEverything() {
        // See "Adjacent endpoints mean the whole day" in spec 016: this is not
        // a midnight-only quirk. Any `start` exactly one minute after `end`
        // leaves nothing excluded, since TimeOfDay has no value strictly
        // between two adjacent minutes.
        let w = TimeWindow(start: t(13, 1), end: t(13, 0))
        #expect(w.isOvernight)
        #expect(w.contains(t(0)))
        #expect(w.contains(t(12)))
        #expect(w.contains(t(13)))
        #expect(w.contains(t(13, 1)))
        #expect(w.contains(t(23, 59)))
    }
}

@Suite("Overnight window firing points")
struct OvernightFiringPointTests {
    private let cal = calendar()
    private func overnight(everyHours: Int, minute: Int = 0) -> Recurrence {
        Recurrence.hourly(
            everyHours: everyHours, minute: minute,
            window: TimeWindow(start: t(23), end: t(4)))!
    }

    @Test("from mid-morning, the next fire is this evening's window open")
    func fromMorning() {
        let r = overnight(everyHours: 1)
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 10, 0), calendar: cal)
                == date(2026, 3, 10, 23, 0))
    }

    @Test("the window chains past midnight into the next calendar day")
    func chainsPastMidnight() {
        let r = overnight(everyHours: 1)
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 23, 0), calendar: cal)
                == date(2026, 3, 11, 0, 0))
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 0, 30), calendar: cal)
                == date(2026, 3, 11, 1, 0))
    }

    @Test("after the morning half ends, the loop does not skip a day early")
    func doesNotSkipTheDay() {
        // The single most likely thing to get wrong: at 04:00 the *current*
        // day still has an evening candidate (23:00) left, so the day loop
        // must not advance past it to the next day's 00:00.
        let r = overnight(everyHours: 1)
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 4, 0), calendar: cal)
                == date(2026, 3, 11, 23, 0))
    }

    @Test("chaining twelve fires produces exactly two clean nightly runs")
    func chainsCleanly() {
        let r = overnight(everyHours: 1)
        var reference = date(2026, 3, 10, 12, 0)
        var fires: [Date] = []
        for _ in 0..<12 {
            guard let next = r.nextFireDate(after: reference, calendar: cal) else { break }
            fires.append(next)
            reference = next
        }
        #expect(fires.count == 12)
        #expect(Set(fires).count == 12)  // no duplicates
        #expect(fires == fires.sorted())  // strictly increasing
    }

    @Test("every 3 hours in an overnight window skips hours off the grid")
    func gridFilterEvery3Hours() {
        // 23 is not a multiple of 3, so the window never fires at 23:00 even
        // though 23:00 is the window's own start.
        let r = overnight(everyHours: 3)
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 10, 0), calendar: cal)
                == date(2026, 3, 11, 0, 0))
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 0, 0), calendar: cal)
                == date(2026, 3, 11, 3, 0))
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 3, 0), calendar: cal)
                == date(2026, 3, 12, 0, 0))
    }

    @Test("every 2 hours at :00 in an overnight window has no evening candidate")
    func gridFilterEvery2Hours() {
        // The grid is 0,2,4,...,22 — 23 is never on it, so this window's
        // nightly candidates are morning-only: 00:00, 02:00, 04:00.
        let r = overnight(everyHours: 2)
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 10, 0), calendar: cal)
                == date(2026, 3, 11, 0, 0))
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 4, 0), calendar: cal)
                == date(2026, 3, 12, 0, 0))
    }

    @Test("every 4 hours at :00 in an overnight window fires at 00:00 and 04:00 only")
    func gridFilterEvery4Hours() {
        let r = overnight(everyHours: 4)
        #expect(
            r.nextFireDate(after: date(2026, 3, 10, 10, 0), calendar: cal)
                == date(2026, 3, 11, 0, 0))
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 0, 0), calendar: cal)
                == date(2026, 3, 11, 4, 0))
    }

    @Test("the window end is a time, not an hour: :30 stops before the next :30 past it")
    func endIsATimeNotAnHour() {
        let r = Recurrence.hourly(
            everyHours: 2, minute: 30, window: TimeWindow(start: t(23), end: t(4)))!
        #expect(
            r.nextFireDate(after: date(2026, 3, 11, 2, 30), calendar: cal)
                == date(2026, 3, 12, 0, 30))
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
            everyHours: 4, minute: 30, window: TimeWindow(start: t(8), end: t(18)))!
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Recurrence.self, from: data) == original)
    }

    @Test("an overnight window round-trips with the same JSON key shape as same-day")
    func overnightWindowRoundTrip() throws {
        let original = Recurrence.hourly(
            everyHours: 1, minute: 0, window: TimeWindow(start: t(23), end: t(4)))!
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Recurrence.self, from: data) == original)
    }

    @Test("a window with start after end now decodes as overnight instead of throwing")
    func invertedWindowDecodesAsOvernight() throws {
        let r = try decode(
            #"{"kind":{"hourly":{"everyHours":4,"minute":0,"window":{"start":{"hour":18,"minute":0},"end":{"hour":8,"minute":0}}}},"times":[]}"#)
        guard case .hourly(_, _, let window) = r.kind, let window else {
            Issue.record("expected an hourly recurrence with a window, got \(r.kind)")
            return
        }
        #expect(window.isOvernight)
        #expect(window.start == t(18))
        #expect(window.end == t(8))
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
            everyHours: 4, minute: 30, window: TimeWindow(start: t(8), end: t(18)))!
        #expect(norm(f().summary(windowed)) == "Every 4 hours at :30 from 8:00 AM to 6:00 PM")
    }

    @Test("an overnight window's summary says so")
    func overnightWindowSummary() {
        let windowed = Recurrence.hourly(
            everyHours: 1, minute: 0, window: TimeWindow(start: t(23), end: t(4)))!
        #expect(
            norm(f().summary(windowed)) == "Every hour at :00 overnight from 11:00 PM to 4:00 AM")
    }

    @Test("equal endpoints keep the same-day summary form, not overnight")
    func equalEndpointsSummary() {
        let windowed = Recurrence.hourly(
            everyHours: 1, minute: 0, window: TimeWindow(start: t(8), end: t(8)))!
        #expect(norm(f().summary(windowed)) == "Every hour at :00 from 8:00 AM to 8:00 AM")
    }
}

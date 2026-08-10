import Foundation
import Testing

@testable import EscapementKit

/// A fixed, well-known calendar so the tests never depend on the machine's locale.
private func calendar(_ tz: String = "America/Phoenix") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

private func date(
    _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0,
    _ cal: Calendar = calendar()
) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

@Suite("TimeOfDay")
struct TimeOfDayTests {
    @Test("accepts the full valid range")
    func validRange() {
        #expect(TimeOfDay(hour: 0, minute: 0) != nil)
        #expect(TimeOfDay(hour: 23, minute: 59) != nil)
    }

    @Test("rejects out-of-range components")
    func invalidRange() {
        #expect(TimeOfDay(hour: 24, minute: 0) == nil)
        #expect(TimeOfDay(hour: -1, minute: 0) == nil)
        #expect(TimeOfDay(hour: 0, minute: 60) == nil)
        #expect(TimeOfDay(hour: 0, minute: -1) == nil)
    }

    @Test("orders chronologically within a day")
    func ordering() {
        let early = TimeOfDay(hour: 2, minute: 30)!
        let late = TimeOfDay(hour: 14, minute: 5)!
        #expect(early < late)
        #expect(TimeOfDay(hour: 9, minute: 0)! < TimeOfDay(hour: 9, minute: 1)!)
    }
}

@Suite("Recurrence validation")
struct RecurrenceValidationTests {
    @Test("hourly interval must be 1...12")
    func hourlyInterval() {
        #expect(Recurrence.hourly(everyHours: 1, minute: 0) != nil)
        #expect(Recurrence.hourly(everyHours: 12, minute: 0) != nil)
        #expect(Recurrence.hourly(everyHours: 0, minute: 0) == nil)
        #expect(Recurrence.hourly(everyHours: 13, minute: 0) == nil)
    }

    @Test("hourly minute must be 0...59")
    func hourlyMinute() {
        #expect(Recurrence.hourly(everyHours: 4, minute: 59) != nil)
        #expect(Recurrence.hourly(everyHours: 4, minute: 60) == nil)
        #expect(Recurrence.hourly(everyHours: 4, minute: -1) == nil)
    }

    @Test("recurrences requiring times reject an empty list")
    func emptyTimes() {
        #expect(Recurrence.daily(times: []) == nil)
        #expect(Recurrence.weekly(weekdays: [.monday], times: []) == nil)
        #expect(Recurrence.monthly(days: [1], times: []) == nil)
    }

    @Test("weekly rejects an empty weekday selection")
    func emptyWeekdays() {
        #expect(Recurrence.weekly(weekdays: [], times: [TimeOfDay(hour: 3, minute: 0)!]) == nil)
    }

    @Test("monthly days must be 1...31 and non-empty")
    func monthlyDays() {
        let t = [TimeOfDay(hour: 3, minute: 0)!]
        #expect(Recurrence.monthly(days: [1, 31], times: t) != nil)
        #expect(Recurrence.monthly(days: [], times: t) == nil)
        #expect(Recurrence.monthly(days: [0], times: t) == nil)
        #expect(Recurrence.monthly(days: [32], times: t) == nil)
    }

    @Test("duplicate times collapse")
    func duplicateTimes() {
        let t = TimeOfDay(hour: 3, minute: 0)!
        let r = Recurrence.daily(times: [t, t, t])!
        #expect(r.times == [t])
    }

    @Test("times are normalised into chronological order")
    func sortedTimes() {
        let late = TimeOfDay(hour: 20, minute: 0)!
        let early = TimeOfDay(hour: 6, minute: 0)!
        let r = Recurrence.daily(times: [late, early])!
        #expect(r.times == [early, late])
    }
}

@Suite("Hourly recurrence")
struct HourlyRecurrenceTests {
    @Test("fires at clock positions anchored to midnight")
    func anchoredToMidnight() {
        let cal = calendar()
        let r = Recurrence.hourly(everyHours: 4, minute: 30)!
        // 01:00 -> next multiple-of-4 hour at :30 is 04:30
        #expect(r.nextFireDate(after: date(2026, 3, 10, 1, 0), calendar: cal)
            == date(2026, 3, 10, 4, 30))
        // 04:31 -> 08:30
        #expect(r.nextFireDate(after: date(2026, 3, 10, 4, 31), calendar: cal)
            == date(2026, 3, 10, 8, 30))
    }

    @Test("rolls over midnight into the next day")
    func rollsOverMidnight() {
        let cal = calendar()
        let r = Recurrence.hourly(everyHours: 4, minute: 30)!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 20, 31), calendar: cal)
            == date(2026, 3, 11, 0, 30))
    }

    @Test("an interval that does not divide 24 restarts at midnight")
    func unevenIntervalRestartsAtMidnight() {
        let cal = calendar()
        // Every 5 hours at :00 -> 00, 05, 10, 15, 20, then midnight wins over 25.
        let r = Recurrence.hourly(everyHours: 5, minute: 0)!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 20, 1), calendar: cal)
            == date(2026, 3, 11, 0, 0))
    }

    @Test("every hour fires on the next hour")
    func everyHour() {
        let cal = calendar()
        let r = Recurrence.hourly(everyHours: 1, minute: 15)!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 9, 20), calendar: cal)
            == date(2026, 3, 10, 10, 15))
    }
}

@Suite("Daily recurrence")
struct DailyRecurrenceTests {
    @Test("returns today's remaining time")
    func laterToday() {
        let cal = calendar()
        let r = Recurrence.daily(times: [TimeOfDay(hour: 3, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 1, 0), calendar: cal)
            == date(2026, 3, 10, 3, 0))
    }

    @Test("rolls to tomorrow once today's time has passed")
    func tomorrow() {
        let cal = calendar()
        let r = Recurrence.daily(times: [TimeOfDay(hour: 3, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 3, 0, 1), calendar: cal)
            == date(2026, 3, 11, 3, 0))
    }

    @Test("picks the earliest future time when several are configured")
    func multipleTimes() {
        let cal = calendar()
        let r = Recurrence.daily(times: [
            TimeOfDay(hour: 2, minute: 0)!,
            TimeOfDay(hour: 13, minute: 0)!,
            TimeOfDay(hour: 22, minute: 0)!,
        ])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 5, 0), calendar: cal)
            == date(2026, 3, 10, 13, 0))
        #expect(r.nextFireDate(after: date(2026, 3, 10, 23, 0), calendar: cal)
            == date(2026, 3, 11, 2, 0))
    }
}

@Suite("Weekly recurrence")
struct WeeklyRecurrenceTests {
    @Test("finds the next selected weekday")
    func nextSelectedWeekday() {
        let cal = calendar()
        // 2026-03-10 is a Tuesday.
        let r = Recurrence.weekly(
            weekdays: [.wednesday, .saturday],
            times: [TimeOfDay(hour: 4, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 12, 0), calendar: cal)
            == date(2026, 3, 11, 4, 0))
    }

    @Test("returns today when today is selected and the time is still ahead")
    func todayStillAhead() {
        let cal = calendar()
        let r = Recurrence.weekly(
            weekdays: [.tuesday], times: [TimeOfDay(hour: 23, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 12, 0), calendar: cal)
            == date(2026, 3, 10, 23, 0))
    }

    @Test("wraps to next week when the only selected day has passed")
    func wrapsToNextWeek() {
        let cal = calendar()
        let r = Recurrence.weekly(
            weekdays: [.tuesday], times: [TimeOfDay(hour: 4, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 12, 0), calendar: cal)
            == date(2026, 3, 17, 4, 0))
    }
}

@Suite("Monthly recurrence")
struct MonthlyRecurrenceTests {
    @Test("finds the next selected day of the month")
    func nextSelectedDay() {
        let cal = calendar()
        let r = Recurrence.monthly(days: [1, 15], times: [TimeOfDay(hour: 5, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 12, 0), calendar: cal)
            == date(2026, 3, 15, 5, 0))
    }

    @Test("rolls into the following month")
    func rollsIntoNextMonth() {
        let cal = calendar()
        let r = Recurrence.monthly(days: [1], times: [TimeOfDay(hour: 5, minute: 0)!])!
        #expect(r.nextFireDate(after: date(2026, 3, 10, 12, 0), calendar: cal)
            == date(2026, 4, 1, 5, 0))
    }

    @Test("skips months where the chosen day does not exist rather than clamping")
    func skipsShortMonths() {
        let cal = calendar()
        let r = Recurrence.monthly(days: [31], times: [TimeOfDay(hour: 5, minute: 0)!])!
        // From late January, the next 31st is in March — February is skipped,
        // not clamped to the 28th.
        #expect(r.nextFireDate(after: date(2026, 1, 31, 6, 0), calendar: cal)
            == date(2026, 3, 31, 5, 0))
    }

    @Test("handles a leap-year 29th")
    func leapDay() {
        let cal = calendar()
        let r = Recurrence.monthly(days: [29], times: [TimeOfDay(hour: 5, minute: 0)!])!
        // 2028 is a leap year, so February 29 exists.
        #expect(r.nextFireDate(after: date(2028, 2, 1, 0, 0), calendar: cal)
            == date(2028, 2, 29, 5, 0))
        // 2026 is not, so February is skipped entirely.
        #expect(r.nextFireDate(after: date(2026, 2, 1, 0, 0), calendar: cal)
            == date(2026, 3, 29, 5, 0))
    }
}

@Suite("Boundary behaviour")
struct BoundaryTests {
    @Test("the result is always strictly after the reference instant")
    func strictlyFuture() {
        let cal = calendar()
        let now = date(2026, 3, 10, 3, 0)
        let r = Recurrence.daily(times: [TimeOfDay(hour: 3, minute: 0)!])!
        let next = r.nextFireDate(after: now, calendar: cal)
        #expect(next != nil)
        #expect(next! > now)
    }

    @Test("repeated application makes progress and never repeats an instant")
    func iterationMakesProgress() {
        let cal = calendar()
        let r = Recurrence.hourly(everyHours: 3, minute: 0)!
        var cursor = date(2026, 3, 10, 0, 1)
        var seen: [Date] = []
        for _ in 0..<40 {
            guard let next = r.nextFireDate(after: cursor, calendar: cal) else {
                Issue.record("engine stopped producing occurrences")
                return
            }
            #expect(next > cursor)
            seen.append(next)
            cursor = next
        }
        #expect(Set(seen).count == seen.count)
    }
}

@Suite("Daylight saving")
struct DaylightSavingTests {
    // Los Angeles springs forward 2026-03-08 (02:00 -> 03:00) and falls back
    // 2026-11-01 (02:00 occurs twice). Phoenix, used elsewhere, has no DST.
    private var la: Calendar { calendar("America/Los_Angeles") }

    @Test("a wall-clock time skipped by spring-forward still yields an instant")
    func springForwardGap() {
        let cal = la
        let r = Recurrence.daily(times: [TimeOfDay(hour: 2, minute: 30)!])!
        let before = date(2026, 3, 8, 0, 0, 0, cal)
        let next = r.nextFireDate(after: before, calendar: cal)
        #expect(next != nil)
        // 02:30 does not exist that day; the engine must not return nil or a
        // time in the past, and must land on 2026-03-08.
        #expect(next! > before)
        #expect(cal.isDate(next!, inSameDayAs: before))
    }

    @Test("a fall-back day fires once, on the first occurrence of the hour")
    func fallBackDuplicate() {
        let cal = la
        let r = Recurrence.daily(times: [TimeOfDay(hour: 1, minute: 30)!])!
        let before = date(2026, 11, 1, 0, 0, 0, cal)
        let first = r.nextFireDate(after: before, calendar: cal)
        #expect(first != nil)
        // The following occurrence must be the next day, not the repeated
        // 01:30 that happens an hour later the same morning.
        let second = r.nextFireDate(after: first!, calendar: cal)
        #expect(second != nil)
        #expect(!cal.isDate(second!, inSameDayAs: first!))
    }

    @Test("daily cadence across spring-forward keeps the wall-clock time")
    func wallClockPreserved() {
        let cal = la
        let r = Recurrence.daily(times: [TimeOfDay(hour: 9, minute: 0)!])!
        let saturday = date(2026, 3, 7, 12, 0, 0, cal)
        let sunday = r.nextFireDate(after: saturday, calendar: cal)!
        let comps = cal.dateComponents([.hour, .minute], from: sunday)
        // Wall-clock 09:00 is preserved even though the day is 23 hours long.
        #expect(comps.hour == 9)
        #expect(comps.minute == 0)
    }

    /// `TimeWindow.contains` only ever sees a `TimeOfDay`, never a `Date`, so an
    /// overnight window's membership test cannot itself be DST-sensitive — but
    /// the *count* of fires on a transition night still depends on how many
    /// wall-clock hours actually occurred, exactly as it does for an
    /// unwindowed hourly schedule. These pin that the wrap adds no new
    /// failure mode on top of the existing spring/fall behaviour above.
    @Test("an overnight window loses exactly the skipped hour on spring-forward")
    func overnightWindowSpringForward() {
        let cal = la
        let window = TimeWindow(start: TimeOfDay(hour: 23, minute: 0)!, end: TimeOfDay(hour: 4, minute: 0)!)
        let r = Recurrence.hourly(everyHours: 1, minute: 0, window: window)!
        var reference = date(2026, 3, 7, 22, 0, 0, cal)
        var fires: [Date] = []
        for _ in 0..<5 {
            guard let next = r.nextFireDate(after: reference, calendar: cal) else { break }
            fires.append(next)
            reference = next
        }
        // 23:00, 00:00, 01:00, 03:00, 04:00 — five fires, not six, because
        // 02:00 does not exist that night. No duplicates from the grid point
        // that collapses onto 03:00.
        #expect(fires.count == 5)
        #expect(Set(fires).count == 5)
        #expect(fires == fires.sorted())
    }

    @Test("an overnight window does not double-fire the repeated hour on fall-back")
    func overnightWindowFallBack() {
        let cal = la
        let window = TimeWindow(start: TimeOfDay(hour: 23, minute: 0)!, end: TimeOfDay(hour: 4, minute: 0)!)
        let r = Recurrence.hourly(everyHours: 1, minute: 0, window: window)!
        let justBeforeOne = date(2026, 11, 1, 0, 59, 0, cal)
        let fireAfterOne = r.nextFireDate(after: justBeforeOne, calendar: cal)!
        let comps = cal.dateComponents([.hour], from: fireAfterOne)
        #expect(comps.hour == 1)
        let next = r.nextFireDate(after: fireAfterOne, calendar: cal)!
        // The gap to the following fire is two real hours, not one, because
        // wall-clock 01:00 occurred twice but only the first firing counts.
        #expect(next.timeIntervalSince(fireAfterOne) == 2 * 60 * 60)
    }
}

import Foundation
import Testing

@testable import EscapementKit

@Suite("PauseOption")
struct PauseOptionTests {

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test("a fixed-length pause is that long from now")
    func fixedDurations() {
        let now = date(2026, 3, 10, 13, 20)
        #expect(PauseOption.oneHour.expiry(from: now, calendar: calendar()) == date(2026, 3, 10, 14, 20))
        #expect(
            PauseOption.fourHours.expiry(from: now, calendar: calendar())
                == date(2026, 3, 10, 17, 20))
    }

    @Test("an indefinite pause has no expiry")
    func indefiniteHasNoExpiry() {
        #expect(PauseOption.indefinitely.expiry(from: date(2026, 3, 10, 13, 20), calendar: calendar()) == nil)
    }

    @Test("until tomorrow morning resumes at the next 8am")
    func untilTomorrowFromAfternoon() {
        let expiry = PauseOption.untilTomorrow.expiry(
            from: date(2026, 3, 10, 13, 20), calendar: calendar())
        #expect(expiry == date(2026, 3, 11, 8, 0))
    }

    @Test("chosen after midnight, until tomorrow morning means this morning, not the next")
    func untilTomorrowFromSmallHours() {
        // The trap: a naive "add one day" would resume thirty hours later.
        let expiry = PauseOption.untilTomorrow.expiry(
            from: date(2026, 3, 10, 2, 0), calendar: calendar())
        #expect(expiry == date(2026, 3, 10, 8, 0))
    }

    @Test("chosen exactly at 8am, until tomorrow morning waits for the next one")
    func untilTomorrowAtBoundary() {
        let expiry = PauseOption.untilTomorrow.expiry(
            from: date(2026, 3, 10, 8, 0), calendar: calendar())
        #expect(expiry == date(2026, 3, 11, 8, 0))
    }

    @Test("every option has a title")
    func allHaveTitles() {
        for option in PauseOption.allCases {
            #expect(!option.title.isEmpty)
        }
    }

    /// `nil` is the "pause until I resume" sentinel all the way down to
    /// `SchedulerRunner.pause(until:)`. If a *timed* option could also return
    /// nil, picking it would silently pause backups forever.
    @Test("only the indefinite option yields a nil expiry", arguments: PauseOption.allCases)
    func onlyIndefiniteIsNil(option: PauseOption) {
        let expiry = option.expiry(from: date(2026, 3, 10, 13, 20), calendar: calendar())
        #expect((expiry == nil) == (option == .indefinitely))
    }

    /// Across a spring-forward transition the morning hour still resolves, and
    /// in every timezone the timed option keeps an expiry.
    @Test(
        "until tomorrow morning keeps an expiry across a DST transition",
        arguments: ["America/New_York", "Europe/London", "Australia/Lord_Howe", "Pacific/Chatham"])
    func untilTomorrowSurvivesDST(zone: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        // The evening before US and EU spring-forward dates.
        for day in [8, 9, 29, 30] {
            let now = cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 23))!
            let expiry = PauseOption.untilTomorrow.expiry(from: now, calendar: cal)
            #expect(expiry != nil)
            #expect(expiry! > now)
        }
    }
}

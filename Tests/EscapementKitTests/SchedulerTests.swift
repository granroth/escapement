import Foundation
import Testing

@testable import EscapementKit

private func calendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Phoenix")!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date
{
    calendar().date(
        from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

private func dailySchedule(
    _ id: String, at hour: Int, minute: Int = 0, enabled: Bool = true, from: Date
) -> DestinationSchedule {
    DestinationSchedule(
        destinationID: id,
        recurrence: .daily(times: [TimeOfDay(hour: hour, minute: minute)!])!,
        isEnabled: enabled,
        effectiveFrom: from)
}

@Suite("Scheduler decision")
struct SchedulerDecisionTests {
    private let scheduler = Scheduler(calendar: calendar())

    @Test("does nothing while a backup is already running")
    func busyRunning() {
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 12, 0),
            schedules: [s],
            lastRuns: [:],
            activity: .running(
                destinationID: "A", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.5)))
        #expect(decision == .idle)
    }

    @Test("does nothing while a cancellation is in progress")
    func busyStopping() {
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 12, 0),
            schedules: [s],
            lastRuns: [:],
            activity: .stopping(destinationID: "A"))
        #expect(decision == .idle)
    }

    @Test("does not fire before the first occurrence after effectiveFrom")
    func noImmediateFireOnCreation() {
        // Configured at noon; first 03:00 is tomorrow, so nothing is due yet.
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 10, 12, 0))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 12, 0, 1),
            schedules: [s], lastRuns: [:], activity: .idle)
        #expect(decision == .idle)
    }

    @Test("fires once the first occurrence has passed")
    func firesWhenDue() {
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 9, 12, 0))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 3, 0, 1),
            schedules: [s], lastRuns: [:], activity: .idle)
        #expect(decision == .start(destinationID: "A"))
    }

    @Test("a disabled schedule never fires")
    func disabledNeverFires() {
        let s = dailySchedule("A", at: 3, enabled: false, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 12, 0),
            schedules: [s], lastRuns: [:], activity: .idle)
        #expect(decision == .idle)
    }

    @Test("does not re-fire when the last run is more recent than the last occurrence")
    func noRefireAfterRecentRun() {
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        // Last ran today at 03:05, after today's 03:00 occurrence.
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 12, 0),
            schedules: [s], lastRuns: ["A": date(2026, 3, 10, 3, 5)], activity: .idle)
        #expect(decision == .idle)
    }

    @Test("a long outage coalesces into a single catch-up, not one per missed day")
    func missedRunsCoalesce() {
        let s = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        // Last ran three days ago; three 03:00s were missed.
        let now = date(2026, 3, 10, 12, 0)
        let lastRuns = ["A": date(2026, 3, 7, 3, 0)]
        // First evaluation: due, starts once.
        #expect(
            scheduler.decision(now: now, schedules: [s], lastRuns: lastRuns, activity: .idle)
                == .start(destinationID: "A"))
        // After that run records, the reference advances and it is no longer due.
        #expect(
            scheduler.decision(
                now: now, schedules: [s], lastRuns: ["A": now], activity: .idle) == .idle)
    }

    @Test("when several are due, the most overdue starts first")
    func mostOverdueFirst() {
        // B's occurrence (01:00) is earlier in the day than A's (05:00), so on
        // a morning where both are overdue B is more overdue.
        let a = dailySchedule("A", at: 5, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 1, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 6, 0),
            schedules: [a, b], lastRuns: [:], activity: .idle)
        #expect(decision == .start(destinationID: "B"))
    }

    @Test("ties are broken by configuration order")
    func tieBreak() {
        let a = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 3, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 6, 0),
            schedules: [a, b], lastRuns: [:], activity: .idle)
        #expect(decision == .start(destinationID: "A"))
    }

    @Test(
        "the least recently attempted destination wins even when it is less overdue by occurrence"
    )
    func leastRecentlyAttemptedWinsOverMostOverdue() {
        // A has never completed, so its reference stays at effectiveFrom and
        // its due occurrence (day 1) is far more overdue than B's (day 9).
        // But A was attempted (and failed) ten minutes ago, while B has not
        // been attempted since it last completed a week ago — B should get
        // the slot, not the destination that keeps consuming it and failing.
        let a = dailySchedule("A", at: 3, from: date(2026, 3, 1, 12, 0))
        let b = dailySchedule("B", at: 3, from: date(2026, 3, 1, 12, 0))
        let now = date(2026, 3, 10, 12, 0)
        let decision = scheduler.decision(
            now: now,
            schedules: [a, b],
            lastRuns: ["B": date(2026, 3, 8, 3, 0)],
            lastAttempts: [
                "A": now.addingTimeInterval(-600),
                "B": date(2026, 3, 8, 3, 0),
            ],
            activity: .idle)
        #expect(decision == .start(destinationID: "B"))
    }

    @Test("when attempts tie, the more overdue occurrence wins")
    func attemptTieFallsBackToOccurrence() {
        let a = dailySchedule("A", at: 5, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 1, from: date(2026, 3, 1))
        let decision = scheduler.decision(
            now: date(2026, 3, 10, 6, 0),
            schedules: [a, b],
            lastRuns: [:],
            lastAttempts: ["A": date(2026, 3, 1), "B": date(2026, 3, 1)],
            activity: .idle)
        #expect(decision == .start(destinationID: "B"))
    }

    @Test("a destination with no recorded attempt is treated as never attempted")
    func missingAttemptIsDistantPast() {
        let a = dailySchedule("A", at: 3, from: date(2026, 3, 1, 12, 0))
        let b = dailySchedule("B", at: 3, from: date(2026, 3, 1, 12, 0))
        let now = date(2026, 3, 10, 12, 0)
        // A was attempted recently; B has no entry at all, so it must win.
        let decision = scheduler.decision(
            now: now,
            schedules: [a, b],
            lastRuns: [:],
            lastAttempts: ["A": now.addingTimeInterval(-60)],
            activity: .idle)
        #expect(decision == .start(destinationID: "B"))
    }

    @Test("no schedules means idle")
    func noSchedules() {
        #expect(
            scheduler.decision(
                now: date(2026, 3, 10), schedules: [], lastRuns: [:], activity: .idle) == .idle)
    }
}

@Suite("Scheduler due schedules")
struct SchedulerDueSchedulesTests {
    private let scheduler = Scheduler(calendar: calendar())

    @Test("reports every due destination, independent of activity")
    func reportsAllDue() {
        let a = dailySchedule("A", at: 5, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 1, from: date(2026, 3, 1))
        let due = scheduler.dueSchedules(
            now: date(2026, 3, 10, 6, 0), schedules: [a, b], lastRuns: [:])
        #expect(Set(due.map(\.destinationID)) == ["A", "B"])
    }

    @Test("omits schedules that are not yet due")
    func omitsNotYetDue() {
        let a = dailySchedule("A", at: 3, from: date(2026, 3, 9, 12, 0))
        let due = scheduler.dueSchedules(
            now: date(2026, 3, 10, 2, 0), schedules: [a], lastRuns: [:])
        #expect(due.isEmpty)
    }

    @Test("omits disabled schedules")
    func omitsDisabled() {
        let a = dailySchedule("A", at: 3, enabled: false, from: date(2026, 3, 1))
        let due = scheduler.dueSchedules(
            now: date(2026, 3, 10, 12, 0), schedules: [a], lastRuns: [:])
        #expect(due.isEmpty)
    }
}

@Suite("Scheduler next wake-up")
struct SchedulerWakeTests {
    private let scheduler = Scheduler(calendar: calendar())

    @Test("returns the earliest future occurrence across all enabled schedules")
    func earliestFuture() {
        let a = dailySchedule("A", at: 5, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 2, from: date(2026, 3, 1))
        // At 03:00, A's next is 05:00 today, B's next is 02:00 tomorrow.
        let next = scheduler.nextWakeUp(
            now: date(2026, 3, 10, 3, 0), schedules: [a, b], lastRuns: [:])
        #expect(next == date(2026, 3, 10, 5, 0))
    }

    @Test("ignores disabled schedules")
    func ignoresDisabled() {
        let a = dailySchedule("A", at: 5, enabled: false, from: date(2026, 3, 1))
        let b = dailySchedule("B", at: 2, from: date(2026, 3, 1))
        let next = scheduler.nextWakeUp(
            now: date(2026, 3, 10, 3, 0), schedules: [a, b], lastRuns: [:])
        #expect(next == date(2026, 3, 11, 2, 0))
    }

    @Test("is nil when nothing is scheduled")
    func nilWhenEmpty() {
        #expect(scheduler.nextWakeUp(now: date(2026, 3, 10), schedules: [], lastRuns: [:]) == nil)
        let disabled = dailySchedule("A", at: 5, enabled: false, from: date(2026, 3, 1))
        #expect(
            scheduler.nextWakeUp(now: date(2026, 3, 10), schedules: [disabled], lastRuns: [:])
                == nil)
    }

    @Test("always looks strictly forward, even past an overdue occurrence")
    func looksForward() {
        // Overdue since yesterday, but the timer should point at the next
        // future occurrence; the overdue one is the decision function's job.
        let a = dailySchedule("A", at: 3, from: date(2026, 3, 1))
        let next = scheduler.nextWakeUp(
            now: date(2026, 3, 10, 12, 0), schedules: [a], lastRuns: ["A": date(2026, 3, 5)])
        #expect(next == date(2026, 3, 11, 3, 0))
    }
}

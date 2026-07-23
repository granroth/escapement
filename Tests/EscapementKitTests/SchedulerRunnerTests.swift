import Foundation
import Testing

@testable import EscapementKit

private func calendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Phoenix")!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    calendar().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func isFailed(_ outcome: BackupRun.Outcome) -> Bool {
    if case .failed = outcome { return true }
    return false
}

/// Builds a runner over temp-file stores with a hand-driven clock and fake TM.
private struct Harness {
    let fake = FakeTimeMachine()
    let clock: TestClock
    let config: ConfigurationStore
    let history: HistoryStore
    let runner: SchedulerRunner
    private let dir: URL

    init(now: Date) {
        clock = TestClock(now)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-runner-\(UUID().uuidString)", isDirectory: true)
        config = ConfigurationStore(url: dir.appendingPathComponent("configuration.json"))
        history = HistoryStore(url: dir.appendingPathComponent("history.json"))
        runner = SchedulerRunner(
            control: fake,
            configuration: config,
            history: history,
            scheduler: Scheduler(calendar: calendar()),
            now: clock.now)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func setDaily(_ id: String, at hour: Int, from: Date, enabled: Bool = true) throws {
        var c = try config.load()
        c.upsert(
            DestinationSchedule(
                destinationID: id, recurrence: .daily(times: [TimeOfDay(hour: hour, minute: 0)!])!,
                isEnabled: enabled, effectiveFrom: from))
        try config.save(c)
    }
}

@Suite("SchedulerRunner")
struct SchedulerRunnerTests {

    @Test("starts a due backup and records it as a scheduled run")
    func startsDueBackup() async throws {
        // "Now" is just after the 03:00 occurrence, as it would be when the
        // timer fires on time, so the run is scheduled rather than a catch-up.
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.runner.evaluate()

        #expect(await h.fake.startCalls == ["A"])
        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].destinationID == "A")
        #expect(runs[0].trigger == .scheduled)
        #expect(runs[0].outcome == .running)
    }

    @Test("does not start when a backup is already running")
    func noStartWhenBusy() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: 0.5))

        await h.runner.evaluate()

        #expect(await h.fake.startCalls.isEmpty)
        #expect(try h.history.load().isEmpty)
    }

    @Test("closes a run as completed once the backup is observed then stops")
    func completesRun() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts; fake flips to running
        await h.runner.evaluate()  // observes running -> stays open
        #expect(try h.history.load()[0].outcome == .running)

        await h.fake.setActivity(.idle)
        h.clock.advance(by: 300)
        await h.runner.evaluate()  // observes idle -> completed

        let run = try h.history.load()[0]
        #expect(run.outcome == .completed)
        #expect(run.finishedAt != nil)
    }

    @Test("does not fail a just-started run before it has had time to appear")
    func startupGrace() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        // Fake stays idle after start (backupd slow to spin up).

        await h.runner.evaluate()  // starts, activity still idle
        h.clock.advance(by: 5)
        await h.runner.evaluate()  // within grace: must not close as failed

        #expect(try h.history.load()[0].outcome == .running)
    }

    @Test("fails a run that never became active after the grace period")
    func failsRunThatNeverStarted() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.runner.evaluate()  // starts, activity stays idle
        h.clock.advance(by: 600)  // well past grace
        await h.runner.evaluate()

        #expect(isFailed(try h.history.load()[0].outcome))
    }

    @Test("records a launch failure as a failed run")
    func launchFailureRecorded() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setStartFailure(FakeError())

        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(isFailed(runs[0].outcome))
        #expect(runs[0].finishedAt != nil)
    }

    @Test("a failed destination is retried only after the cooldown, not every tick")
    func retryCooldown() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.runner.evaluate()  // attempt 1, stays idle
        h.clock.advance(by: 600)  // past startup grace, within cooldown
        await h.runner.evaluate()  // closes failed; must NOT retry yet
        #expect(await h.fake.startCalls.count == 1)
        #expect(try h.history.load().count == 1)

        h.clock.advance(by: 400)  // now past the 15-minute cooldown
        await h.runner.evaluate()  // retry permitted
        #expect(await h.fake.startCalls.count == 2)
        #expect(try h.history.load().count == 2)
    }

    @Test("an overdue occurrence is recorded as a missed catch-up")
    func missedTrigger() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        // Effective from a week ago; the 03:00 occurrence is long past.
        try h.setDaily("A", at: 3, from: date(2026, 3, 1, 12, 0))

        await h.runner.evaluate()

        #expect(try h.history.load()[0].trigger == .missed)
    }

    @Test("backUpNow starts a manual run when idle")
    func manualWhenIdle() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }

        await h.runner.backUpNow(destinationID: "A")

        #expect(await h.fake.startCalls == ["A"])
        #expect(try h.history.load()[0].trigger == .manual)
    }

    @Test("backUpNow does nothing while busy")
    func manualWhenBusy() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "X", phase: .copying, progress: 0.5))

        await h.runner.backUpNow(destinationID: "A")

        #expect(await h.fake.startCalls.isEmpty)
    }

    @Test("closes a run stranded in running across a restart")
    func closesStrandedRun() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        // A record left open by a previous process, with no in-memory memory
        // of it, and the system now idle.
        try h.history.append(
            BackupRun(
                destinationID: "A", trigger: .scheduled,
                startedAt: date(2026, 3, 10, 3, 0)))

        await h.runner.evaluate()

        #expect(isFailed(try h.history.load()[0].outcome))
    }

    @Test("nextWakeUp reflects the configured schedules")
    func nextWakeUp() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1))

        let next = await h.runner.nextWakeUp()
        #expect(next == date(2026, 3, 11, 3, 0))
    }
}

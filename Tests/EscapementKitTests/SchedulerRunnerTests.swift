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
    let state: StateStore
    let runner: SchedulerRunner
    private let dir: URL

    init(now: Date) {
        clock = TestClock(now)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-runner-\(UUID().uuidString)", isDirectory: true)
        config = ConfigurationStore(url: dir.appendingPathComponent("configuration.json"))
        history = HistoryStore(url: dir.appendingPathComponent("history.json"))
        state = StateStore(url: dir.appendingPathComponent("state.json"))
        runner = SchedulerRunner(
            control: fake,
            configuration: config,
            history: history,
            state: state,
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

    func setPaused(until: Date) throws {
        var s = try state.load()
        s.pause(until: until)
        try state.save(s)
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
        await h.fake.setActivity(
            .running(
                destinationID: "B", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.5)))

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
        await h.fake.setActivity(
            .running(
                destinationID: "X", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.5)))

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

    // MARK: - Pause

    @Test("a due backup does not start while paused")
    func pauseSuppressesScheduledFire() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        try h.setPaused(until: date(2026, 3, 10, 6, 0))

        await h.runner.evaluate()

        #expect(await h.fake.startCalls.isEmpty)
        #expect(try h.history.load().isEmpty)
    }

    @Test("the schedule fires again once the pause expires")
    func pauseExpiryResumesSchedule() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        try h.setPaused(until: date(2026, 3, 10, 6, 0))

        await h.runner.evaluate()
        #expect(await h.fake.startCalls.isEmpty)

        h.clock.set(date(2026, 3, 10, 6, 1))
        await h.runner.evaluate()

        #expect(await h.fake.startCalls == ["A"])
    }

    @Test("a manual backUpNow still runs while paused — pause suppresses the schedule, not the user")
    func pauseDoesNotBlockManual() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setPaused(until: date(2026, 3, 10, 18, 0))

        await h.runner.backUpNow(destinationID: "A")

        #expect(await h.fake.startCalls == ["A"])
        #expect(try h.history.load()[0].trigger == .manual)
    }

    @Test("an open run is still closed out while paused")
    func pauseStillReconciles() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        // A record stranded open by a previous process, with the system idle.
        try h.history.append(
            BackupRun(
                destinationID: "A", trigger: .scheduled,
                startedAt: date(2026, 3, 10, 3, 0)))
        try h.setPaused(until: date(2026, 3, 10, 18, 0))

        await h.runner.evaluate()

        // Pausing must not strand history: bookkeeping continues regardless.
        #expect(isFailed(try h.history.load()[0].outcome))
    }

    @Test("nextWakeUp returns the pause expiry so the agent resumes on its own")
    func nextWakeUpDuringPause() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1))
        try h.setPaused(until: date(2026, 3, 10, 18, 0))

        // Without this the agent would sleep past the expiry and stay dormant
        // until something else happened to wake it.
        #expect(await h.runner.nextWakeUp() == date(2026, 3, 10, 18, 0))
    }

    @Test("a long pause does not fire a burst of catch-up backups when it ends")
    func pauseDoesNotCauseCatchUpBurst() async throws {
        // Paused across three days of a daily 03:00 schedule. When it ends the
        // engine must run one backup, not one per missed occurrence.
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1))
        try h.setPaused(until: date(2026, 3, 13, 12, 0))

        // Up to but not including the expiry instant — the pause window is
        // half-open, so noon on the 13th is already resumed.
        for day in 10...12 {
            h.clock.set(date(2026, 3, day, 12, 0))
            await h.runner.evaluate()
        }
        #expect(await h.fake.startCalls.isEmpty)

        // Pause over: exactly one catch-up, and no second one on the next tick.
        h.clock.set(date(2026, 3, 13, 12, 1))
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 1)

        h.clock.advance(by: 30)
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 1)
    }

    @Test("nextWakeUp ignores a pause that has already expired")
    func nextWakeUpAfterPauseExpired() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1))
        try h.setPaused(until: date(2026, 3, 10, 9, 0))

        #expect(await h.runner.nextWakeUp() == date(2026, 3, 11, 3, 0))
    }
}

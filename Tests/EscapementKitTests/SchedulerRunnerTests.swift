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

    init(
        now: Date,
        maxRetryCooldown: TimeInterval = 12 * 60 * 60,
        stallTimeout: TimeInterval = 2 * 60 * 60
    ) {
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
            now: clock.now,
            maxRetryCooldown: maxRetryCooldown,
            stallTimeout: stallTimeout)
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

    @Test("a failure to launch the tool closes the run immediately")
    func launchFailureClosesRun() async throws {
        // Nothing reached backupd, so there is nothing to wait for.
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setStartFailure(TMUtilController.ToolError.launchFailed(underlying: "nope"))

        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].outcome == .failed(reason: "could not run tmutil: nope"))
    }

    @Test("a tmutil that stops answering leaves the run open to be confirmed")
    func timeoutLeavesRunOpen() async throws {
        // `startbackup` timing out says nothing about whether backupd took the
        // work. Closing the run as failed here would both lie and strand the
        // real backup, which would then be re-adopted as a second, external
        // record for the same physical run.
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setStartFailure(
            TMUtilController.ToolError.timedOut(arguments: ["startbackup"]))

        await h.runner.evaluate()

        let afterStart = try h.history.load()
        #expect(afterStart.count == 1)
        #expect(afterStart[0].outcome == .running)

        // The backup was in fact running all along; the next tick sees it.
        await h.fake.setStartFailure(nil)
        await h.fake.setActivity(
            .running(
                destinationID: "A", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.5)))
        h.clock.advance(by: 60)
        await h.runner.evaluate()

        // Still one record, and it is the original scheduled one — not a second
        // adopted as external.
        let running = try h.history.load()
        #expect(running.count == 1)
        #expect(running[0].id == afterStart[0].id)
        #expect(running[0].trigger == .scheduled)

        await h.fake.setActivity(.idle)
        h.clock.advance(by: 60)
        await h.runner.evaluate()

        let done = try h.history.load()
        #expect(done.count == 1)
        #expect(done[0].outcome == .completed)
    }

    @Test("a backup that never appears after a timeout is closed honestly")
    func timeoutWithNoBackupClosesAsDidNotStart() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setStartFailure(
            TMUtilController.ToolError.timedOut(arguments: ["startbackup"]))

        await h.runner.evaluate()
        await h.fake.setStartFailure(nil)

        // Past the startup grace with nothing ever showing up in tmutil status.
        h.clock.advance(by: 60 * 10)
        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].outcome == .failed(reason: "backup did not start"))
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
        let runs = try h.history.load()
        #expect(runs.count == 2)
        // The due occurrence is recorded as skipped rather than silently
        // dropped — a busy slot must leave a trace in the Activity Log.
        let a = try #require(runs.first { $0.destinationID == "A" })
        if case .skipped = a.outcome {
        } else {
            Issue.record("expected .skipped, got \(a.outcome)")
        }
        // B is a live, unattributed backup with no schedule of its own — it
        // is adopted rather than silently ignored (spec 015).
        let b = try #require(runs.first { $0.destinationID == "B" })
        #expect(b.trigger == .external)
        #expect(b.outcome == .running)
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

        let runs = try h.history.load()
        // Own runs are not adoption candidates (conditions 2 and 3 exclude
        // them throughout), so this stays a single record.
        #expect(runs.count == 1)
        let run = runs[0]
        #expect(run.trigger != .external)
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

    // MARK: - Fairness

    @Test("fairness ordering survives a restart because it is derived from history, not memory")
    func fairnessSurvivesRestart() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        // A has never completed, so its due occurrence (from effectiveFrom) is
        // far more overdue than B's. A previous process attempted A recently
        // and failed; that attempt lives only in history, not in this
        // runner's in-memory state, as it would after a restart. B has not
        // been attempted since it completed a week ago.
        try h.setDaily("A", at: 3, from: date(2026, 3, 1, 12, 0))
        try h.setDaily("B", at: 3, from: date(2026, 3, 1, 12, 0))
        try h.history.append(
            BackupRun(
                destinationID: "A", trigger: .scheduled,
                startedAt: date(2026, 3, 10, 2, 0),
                finishedAt: date(2026, 3, 10, 2, 5),
                outcome: .failed(reason: "stalled")))
        try h.history.append(
            BackupRun(
                destinationID: "B", trigger: .scheduled,
                startedAt: date(2026, 3, 3, 3, 0),
                finishedAt: date(2026, 3, 3, 3, 5),
                outcome: .completed))

        await h.runner.evaluate()

        #expect(await h.fake.startCalls == ["B"])
    }

    // MARK: - Stall watchdog

    @Test("a run that stops progressing past the stall timeout is stopped and marked stalled")
    func stallWatchdogStopsAStuckRun() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1), stallTimeout: 3600)
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts; fake flips to running
        await h.runner.evaluate()  // observes running, records the baseline snapshot

        h.clock.advance(by: 3700)  // past the stall timeout with no change at all
        await h.runner.evaluate()

        #expect(await h.fake.stopCalls == 1)
        let run = try h.history.load()[0]
        #expect(isFailed(run.outcome))
        if case .failed(let reason) = run.outcome {
            #expect(reason == "stalled")
        }
    }

    @Test("byte or file movement resets the stall clock even without a phase change")
    func progressChangeResetsStallClock() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1), stallTimeout: 3600)
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts
        await h.runner.evaluate()  // baseline recorded

        h.clock.advance(by: 3000)  // within the timeout
        await h.fake.setActivity(
            .running(
                destinationID: "A", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.2, bytesCopied: 500)))
        await h.runner.evaluate()  // progress changed -> resets the baseline

        h.clock.advance(by: 3000)  // 6000s since start, but only 3000s since the reset
        await h.runner.evaluate()

        #expect(await h.fake.stopCalls == 0)
        #expect(try h.history.load()[0].outcome == .running)
    }

    @Test("a phase change alone counts as progress even without byte movement")
    func phaseChangeAloneCountsAsProgress() async throws {
        // Guards against a false positive during a legitimate phase like
        // Thinning that reports no byte movement of its own.
        let h = Harness(now: date(2026, 3, 10, 3, 1), stallTimeout: 3600)
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts
        await h.runner.evaluate()  // baseline recorded

        h.clock.advance(by: 3000)
        await h.fake.setActivity(.running(destinationID: "A", phase: .thinning, progress: nil))
        await h.runner.evaluate()  // phase changed -> resets the baseline

        h.clock.advance(by: 3000)
        await h.runner.evaluate()

        #expect(await h.fake.stopCalls == 0)
        #expect(try h.history.load()[0].outcome == .running)
    }

    // MARK: - Backoff

    @Test("consecutive non-completing attempts lengthen the retry cooldown exponentially")
    func backoffLengthensCooldownExponentially() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        // Attempt 1 fails.
        await h.runner.evaluate()
        h.clock.advance(by: 600)
        await h.runner.evaluate()  // closes failed #1
        #expect(await h.fake.startCalls.count == 1)

        // The base cooldown (900s) has elapsed since attempt 1 started;
        // attempt 2 begins and also fails.
        h.clock.advance(by: 400)  // 1000s since attempt 1's start
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 2)
        h.clock.advance(by: 600)
        await h.runner.evaluate()  // closes failed #2

        // Two consecutive failures require 2x the base cooldown (1800s), not
        // the flat 900s that a single failure would.
        h.clock.advance(by: 900)  // 900s since attempt 2's start: still short
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 2)

        h.clock.advance(by: 901)  // 1801s since attempt 2's start: enough
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 3)
    }

    @Test("a completed run resets the consecutive-failure count")
    func completionResetsBackoff() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        // Attempt 1 fails.
        await h.runner.evaluate()
        h.clock.advance(by: 600)
        await h.runner.evaluate()

        // Attempt 2, after the base cooldown, succeeds.
        h.clock.advance(by: 901)
        await h.fake.setAutoBecomeRunning(true)
        await h.runner.evaluate()
        await h.runner.evaluate()
        await h.fake.setActivity(.idle)
        h.clock.advance(by: 60)
        await h.runner.evaluate()
        #expect(
            try h.history.load().first(where: { $0.destinationID == "A" })?.outcome == .completed)

        // A day later the schedule is due again; attempt 3 fails. If the
        // failure streak had not reset, two in a row would demand 1800s —
        // confirm the base 900s is sufficient instead.
        h.clock.advance(by: 24 * 60 * 60)
        await h.fake.setAutoBecomeRunning(false)
        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // starts attempt 3
        h.clock.advance(by: 600)
        await h.runner.evaluate()  // closes failed

        h.clock.advance(by: 901)  // base cooldown only
        await h.runner.evaluate()
        #expect(await h.fake.startCalls.count == 4)
    }

    // MARK: - Skipped occurrences

    @Test("a due destination blocked by a busy slot is recorded once as skipped, not once per tick")
    func skippedRecordedOncePerOccurrence() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))

        await h.runner.evaluate()
        h.clock.advance(by: 60)
        await h.runner.evaluate()
        h.clock.advance(by: 60)
        await h.runner.evaluate()

        let skipped = try h.history.load().filter {
            if case .skipped = $0.outcome { return true }
            return false
        }
        #expect(skipped.count == 1)
        #expect(skipped[0].destinationID == "A")
    }

    @Test("the destination that starts is not itself recorded as skipped")
    func startedDestinationNotRecordedSkipped() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.runner.evaluate()

        let skipped = try h.history.load().filter {
            if case .skipped = $0.outcome { return true }
            return false
        }
        #expect(skipped.isEmpty)
    }

    // MARK: - Waiting state

    @Test("AgentState.waiting is set while a due backup is blocked and cleared once one starts")
    func waitingStateReflectsBlocking() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        // B is live with no schedule of its own, so it is adopted (spec 015)
        // rather than being an unattributed busy slot — the destination the
        // waiting state should still name as the holder either way.
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))

        await h.runner.evaluate()

        let waiting = try h.state.load().waiting
        #expect(waiting?.blockedDestinationID == "A")
        #expect(waiting?.holderDestinationID == "B")

        await h.fake.setActivity(.idle)
        h.clock.advance(by: 10)
        await h.runner.evaluate()  // arms B's close confirmation; still blocked

        let stillWaiting = try h.state.load().waiting
        #expect(stillWaiting?.blockedDestinationID == "A")
        #expect(stillWaiting?.holderDestinationID == nil)  // idle, so no named holder

        h.clock.advance(by: 10)
        await h.runner.evaluate()  // B's second idle poll closes it; A can start

        #expect(try h.state.load().waiting == nil)
    }

    @Test("waiting.since is set once and does not reset on every blocked tick")
    func waitingSincePersistsAcrossTicks() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))

        await h.runner.evaluate()
        let firstSince = try h.state.load().waiting?.since

        h.clock.advance(by: 120)
        await h.runner.evaluate()
        let secondSince = try h.state.load().waiting?.since

        #expect(firstSince != nil)
        #expect(firstSince == secondSince)
    }

    @Test("waiting during a retry cooldown reports no holder — the slot is genuinely idle")
    func waitingDuringCooldownHasNoHolder() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.runner.evaluate()
        h.clock.advance(by: 600)
        await h.runner.evaluate()  // closes failed, still within cooldown -> blocked

        let waiting = try h.state.load().waiting
        #expect(waiting?.blockedDestinationID == "A")
        #expect(waiting?.holderDestinationID == nil)
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

@Suite("External backup detection")
struct ExternalBackupDetectionTests {

    @Test("a live external backup is adopted as an ordinary history record")
    func adoptsExternalBackup() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))

        await h.runner.evaluate()
        var runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].destinationID == "A")
        #expect(runs[0].trigger == .external)
        #expect(runs[0].outcome == .running)

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // first non-live poll only arms confirmation
        #expect(try h.history.load()[0].outcome == .running)

        await h.runner.evaluate()  // second consecutive non-live poll closes it
        runs = try h.history.load()
        #expect(runs[0].outcome == .completed)
        #expect(runs[0].finishedAt != nil)
    }

    @Test("an external backup is adopted once, not once per tick")
    func adoptsOnce() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))

        await h.runner.evaluate()
        await h.runner.evaluate()
        await h.runner.evaluate()

        #expect(try h.history.load().count == 1)
    }

    @Test("a nil destination id is never adopted")
    func nilDestinationNotAdopted() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: nil, phase: .copying, progress: nil))

        await h.runner.evaluate()
        await h.runner.evaluate()
        #expect(try h.history.load().isEmpty)

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()
        #expect(try h.history.load().isEmpty)
    }

    @Test("a backup first observed already stopping is not adopted")
    func stoppingNotAdopted() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.stopping(destinationID: "A"))

        await h.runner.evaluate()

        #expect(try h.history.load().isEmpty)
    }

    @Test("an external backup on another destination is not adopted while a run awaits its startup grace")
    func noOverlapDuringStartupGrace() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        // Fake stays idle after start (autoBecomeRunning left off), so A sits
        // inside its startup grace throughout.

        await h.runner.evaluate()  // starts A
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))
        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].destinationID == "A")
        #expect(runs[0].outcome == .running)
    }

    @Test("adopts a new external backup on the same tick a run closes")
    func adoptsOnSameTickAnotherCloses() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts A; fake flips to running(A)
        await h.runner.evaluate()  // observes A running -> stays open

        // A's own activity is replaced by B's in one step, as it would be if
        // A finished and B started between polls: this tick's reconciliation
        // must close A from a *fresh* read, not the stale pre-loop snapshot,
        // or it will wrongly refuse to adopt B.
        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))
        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 2)
        let a = try #require(runs.first { $0.destinationID == "A" })
        let b = try #require(runs.first { $0.destinationID == "B" })
        #expect(a.trigger == .scheduled)
        #expect(a.outcome == .completed)
        #expect(b.trigger == .external)
        #expect(b.outcome == .running)
    }

    @Test("a stopped external backup closes as cancelled, not completed")
    func externalCancellation() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt

        await h.fake.setActivity(.stopping(destinationID: "A"))
        await h.runner.evaluate()  // observes stopping -> observedStopping = true

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arm confirmation
        await h.runner.evaluate()  // close

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].outcome == .cancelled)
    }

    @Test("Escapement's own stopped run also closes as cancelled, not completed")
    func ownRunStoppedClosesAsCancelled() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))
        await h.fake.setAutoBecomeRunning(true)

        await h.runner.evaluate()  // starts; fake flips to running
        await h.runner.evaluate()  // observes running

        // The GUI/menu-bar Stop command calls this directly, with no
        // knowledge of which run is open — exactly what the fake models.
        try await h.fake.stopBackup()
        await h.runner.evaluate()  // observes stopping -> observedStopping = true

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // own runs close on the very next non-live poll

        #expect(try h.history.load()[0].outcome == .cancelled)
    }

    @Test("a manual Stop reaches an adopted run — it is not restricted to Escapement's own")
    func manualStopReachesAdoptedRun() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt

        try await h.fake.stopBackup()  // the menu bar / AgentCommand.stop path
        await h.runner.evaluate()

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()
        await h.runner.evaluate()

        let runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].outcome == .cancelled)
    }

    @Test("a one-poll blip to idle does not duplicate an adopted record")
    func blipDoesNotDuplicate() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()
        let id = try h.history.load()[0].id

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arms confirmation
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // the blip resolves; same open run, not a new one

        var runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].id == id)
        #expect(runs[0].outcome == .running)

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()
        await h.runner.evaluate()

        runs = try h.history.load()
        #expect(runs.count == 1)
        #expect(runs[0].outcome == .completed)
    }

    @Test("a run awaiting close confirmation holds the slot for the whole tick")
    func pendingConfirmationHoldsSlot() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt A

        // B is already overdue, so it is this tick's nominal winner — the
        // case the deferral must actually catch.
        try h.setDaily("B", at: 3, from: date(2026, 3, 1, 12, 0))

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arms A's confirmation; must not start B

        #expect(await h.fake.startCalls.isEmpty)
        var runs = try h.history.load()
        #expect(runs.first { $0.destinationID == "A" }?.outcome == .running)
        #expect(!runs.contains { $0.destinationID == "B" })

        await h.runner.evaluate()  // A closes; B starts in the same tick

        #expect(await h.fake.startCalls == ["B"])
        runs = try h.history.load()
        #expect(runs.first { $0.destinationID == "A" }?.outcome == .completed)
        #expect(runs.first { $0.destinationID == "B" }?.outcome == .running)
    }

    @Test("backUpNow also respects a pending close confirmation, not just evaluate()")
    func backUpNowRespectsPendingConfirmation() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt A

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arms A's confirmation; the idle sample is not trusted yet

        // The GUI/menu bar's own activity read is fooled by the same blip,
        // so the user can still press Back Up Now for another destination.
        await h.runner.backUpNow(destinationID: "B")

        #expect(await h.fake.startCalls.isEmpty)
        var runs = try h.history.load()
        #expect(runs.first { $0.destinationID == "A" }?.outcome == .running)
        #expect(!runs.contains { $0.destinationID == "B" })

        // Once A is genuinely confirmed closed, backUpNow works normally.
        await h.runner.evaluate()  // A's second idle poll closes it
        await h.runner.backUpNow(destinationID: "B")

        #expect(await h.fake.startCalls == ["B"])
        runs = try h.history.load()
        #expect(runs.first { $0.destinationID == "B" }?.trigger == .manual)
    }

    @Test("a completed external run advances due-ness like a completed scheduled one")
    func externalCompletionAdvancesDueness() async throws {
        let h = Harness(now: date(2026, 3, 10, 8, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1, 12, 0))

        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt at 08:00
        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arm
        await h.runner.evaluate()  // close .completed
        #expect(try h.history.load().first?.outcome == .completed)

        await h.runner.evaluate()  // A must not start again today
        #expect(await h.fake.startCalls.isEmpty)

        h.clock.set(date(2026, 3, 11, 3, 1))
        await h.runner.evaluate()  // due again at the following 03:00
        #expect(await h.fake.startCalls == ["A"])
    }

    @Test("cooldown applies after an adopted run is cancelled, same as any other")
    func cooldownAppliesAfterCancellation() async throws {
        let h = Harness(now: date(2026, 3, 10, 3, 1))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 9, 12, 0))

        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt
        await h.fake.setActivity(.stopping(destinationID: "A"))
        await h.runner.evaluate()
        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arm
        await h.runner.evaluate()  // close .cancelled

        await h.runner.evaluate()  // A is due again immediately, but cooldown applies
        #expect(await h.fake.startCalls.isEmpty)

        h.clock.advance(by: 16 * 60)  // past the default 15-minute retryCooldown
        await h.runner.evaluate()
        #expect(await h.fake.startCalls == ["A"])
    }

    @Test("an adopted run costs its destination its place in the fairness rotation")
    func adoptedRunCostsFairnessPriority() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1, 12, 0))
        try h.setDaily("B", at: 3, from: date(2026, 3, 1, 12, 0))

        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopt A
        await h.fake.setActivity(.idle)
        await h.runner.evaluate()  // arm
        await h.runner.evaluate()  // close A .completed

        await h.runner.evaluate()  // both due; B must win, since A just ran
        #expect(await h.fake.startCalls == ["B"])
    }

    @Test("the stall watchdog does not touch an adopted run")
    func watchdogExemptForExternalRuns() async throws {
        // Paired with `stallWatchdogStopsAStuckRun`: same activity shape,
        // same timeout, same held snapshot — differing only in the trigger.
        let h = Harness(now: date(2026, 3, 10, 3, 1), stallTimeout: 3600)
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))

        await h.runner.evaluate()  // adopts A
        await h.runner.evaluate()  // records the baseline snapshot

        h.clock.advance(by: 3700)  // past the stall timeout with no change at all
        await h.runner.evaluate()

        #expect(await h.fake.stopCalls == 0)
        #expect(try h.history.load()[0].outcome == .running)
    }

    @Test("adoption and close-out happen while paused; no scheduled run starts")
    func adoptionWorksWhilePaused() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        try h.setDaily("A", at: 3, from: date(2026, 3, 1, 12, 0))  // due
        try h.setPaused(until: date(2026, 3, 20, 0, 0))

        await h.fake.setActivity(.running(destinationID: "B", phase: .copying, progress: nil))
        await h.runner.evaluate()  // adopts B despite the pause

        #expect(try h.history.load().first { $0.destinationID == "B" }?.trigger == .external)
        #expect(await h.fake.startCalls.isEmpty)  // A's own due schedule stays suppressed

        await h.fake.setActivity(.idle)
        await h.runner.evaluate()
        await h.runner.evaluate()

        #expect(try h.history.load().first { $0.destinationID == "B" }?.outcome == .completed)
        #expect(await h.fake.startCalls.isEmpty)
    }

    @Test("a backup that starts and finishes between polls is never recorded")
    func betweenPollsMiss() async throws {
        let h = Harness(now: date(2026, 3, 10, 12, 0))
        defer { h.cleanup() }
        await h.fake.setActivity(.running(destinationID: "A", phase: .copying, progress: nil))
        await h.fake.setActivity(.idle)  // both changes land before any evaluate()

        await h.runner.evaluate()

        #expect(try h.history.load().isEmpty)
    }
}

import Foundation

/// The stateful coordinator that turns the pure `Scheduler`'s decisions into
/// real backups and records what happened.
///
/// An `actor` because timer ticks, wake events, activity polling, and UI
/// actions all reach it; it must never evaluate twice at once. The clock is a
/// closure so the whole loop is testable without waiting.
public actor SchedulerRunner {

    /// How long after a start to keep waiting for the backup to appear before
    /// concluding it never got going. backupd can take a little while to spin
    /// up, so a just-started run is not failed prematurely.
    private let startupGrace: TimeInterval

    /// How overdue an occurrence must be to count as a slept-through catch-up
    /// rather than an on-time run.
    private let missedGrace: TimeInterval

    /// The minimum gap between attempts on the same destination.
    ///
    /// A failed attempt does not advance the last-completed reference — we
    /// still want the backup to happen — so without this the destination would
    /// stay due and be retried on every tick, hammering an unreachable disk.
    /// The cooldown turns that into an occasional retry instead of a storm.
    private let retryCooldown: TimeInterval

    private let control: any TimeMachineControlling
    private let configuration: ConfigurationStore
    private let history: HistoryStore
    private let scheduler: Scheduler
    private let now: @Sendable () -> Date

    /// The run this runner most recently started and has not yet closed out,
    /// with whether the backup has been observed live at least once.
    private struct OpenRun {
        let id: UUID
        let destinationID: String
        var observedRunning: Bool
    }
    private var openRun: OpenRun?

    /// The last instant a backup was attempted per destination, in memory only.
    /// Reset across launches, which is acceptable: a stale attempt from before
    /// a restart should not suppress a fresh one.
    private var lastAttempt: [String: Date] = [:]

    /// Guards against actor reentrancy: an `await` inside `evaluate` could
    /// otherwise let a second `evaluate` interleave and double-start.
    private var isWorking = false

    public init(
        control: any TimeMachineControlling,
        configuration: ConfigurationStore,
        history: HistoryStore,
        scheduler: Scheduler,
        now: @escaping @Sendable () -> Date,
        startupGrace: TimeInterval = 120,
        missedGrace: TimeInterval = 15 * 60,
        retryCooldown: TimeInterval = 15 * 60
    ) {
        self.control = control
        self.configuration = configuration
        self.history = history
        self.scheduler = scheduler
        self.now = now
        self.startupGrace = startupGrace
        self.missedGrace = missedGrace
        self.retryCooldown = retryCooldown
    }

    // MARK: - The tick

    /// One evaluation: close out finished runs, then start a due backup if one
    /// is warranted and nothing is already running.
    public func evaluate() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        // If activity cannot be read, do nothing this tick rather than act on a
        // guess — starting a second backup blindly is worse than a skipped tick.
        guard let activity = try? await control.activity() else { return }

        reconcileOpenRuns(activity: activity)

        let config = (try? configuration.load()) ?? Configuration()
        let lastRuns = (try? history.lastCompletedRuns()) ?? [:]
        let decision = scheduler.decision(
            now: now(), schedules: config.schedules, lastRuns: lastRuns, activity: activity)

        guard case .start(let destinationID) = decision else { return }

        // Respect the retry cooldown so a destination that just failed is not
        // restarted on the very next tick.
        if let last = lastAttempt[destinationID],
            now().timeIntervalSince(last) < retryCooldown
        {
            return
        }

        let trigger = triggerFor(
            destinationID: destinationID, schedules: config.schedules, lastRuns: lastRuns)
        await start(destinationID: destinationID, trigger: trigger)
    }

    /// Starts a backup at the user's explicit request, if nothing is running.
    public func backUpNow(destinationID: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        guard let activity = try? await control.activity(), activity == .idle else { return }
        await start(destinationID: destinationID, trigger: .manual)
    }

    /// The earliest future instant any enabled schedule fires, for arming the
    /// caller's timer.
    public func nextWakeUp() async -> Date? {
        let config = (try? configuration.load()) ?? Configuration()
        return scheduler.nextWakeUp(now: now(), schedules: config.schedules, lastRuns: [:])
    }

    // MARK: - Starting

    private func start(destinationID: String, trigger: BackupRun.Trigger) async {
        lastAttempt[destinationID] = now()
        let run = BackupRun(destinationID: destinationID, trigger: trigger, startedAt: now())
        try? history.append(run)
        openRun = OpenRun(id: run.id, destinationID: destinationID, observedRunning: false)

        do {
            try await control.startBackup(destinationID: destinationID)
        } catch {
            // A failure to launch the tool is final: close the run now rather
            // than leave it waiting for a backup that will never appear.
            close(run: run, outcome: .failed(reason: String(describing: error)))
            openRun = nil
        }
    }

    // MARK: - Closing out runs

    /// Reconciles open `.running` records against what is actually happening.
    private func reconcileOpenRuns(activity: BackupActivity) {
        let runs = (try? history.load()) ?? []
        for run in runs where run.outcome == .running {
            if isLive(activity, forDestination: run.destinationID) {
                if run.id == openRun?.id { openRun?.observedRunning = true }
                continue
            }
            closeFinished(run: run)
        }
    }

    /// Closes a `.running` record whose backup is no longer live.
    private func closeFinished(run: BackupRun) {
        if run.id == openRun?.id {
            let open = openRun!
            if open.observedRunning {
                close(run: run, outcome: .completed)
            } else if now().timeIntervalSince(run.startedAt) < startupGrace {
                // Give a just-started backup time to appear before judging it.
                return
            } else {
                close(run: run, outcome: .failed(reason: "backup did not start"))
            }
            openRun = nil
        } else {
            // A record stranded by a previous process. We cannot confirm it
            // completed, so it is closed honestly as interrupted rather than
            // left open forever.
            close(run: run, outcome: .failed(reason: "interrupted"))
        }
    }

    private func close(run: BackupRun, outcome: BackupRun.Outcome) {
        var closed = run
        closed.finishedAt = now()
        closed.outcome = outcome
        try? history.update(closed)
    }

    private func isLive(_ activity: BackupActivity, forDestination id: String) -> Bool {
        switch activity {
        case .idle:
            return false
        case .running(let destinationID, _, _), .stopping(let destinationID):
            // A nil destination in the status means "some backup is live"; we
            // cannot attribute it elsewhere, so we treat it as ours.
            return destinationID == nil || destinationID == id
        }
    }

    // MARK: - Trigger classification

    private func triggerFor(
        destinationID: String, schedules: [DestinationSchedule], lastRuns: [String: Date]
    ) -> BackupRun.Trigger {
        guard let schedule = schedules.first(where: { $0.destinationID == destinationID }),
            let occurrence = scheduler.dueOccurrence(
                for: schedule, now: now(), lastRuns: lastRuns)
        else { return .scheduled }
        return now().timeIntervalSince(occurrence) > missedGrace ? .missed : .scheduled
    }
}

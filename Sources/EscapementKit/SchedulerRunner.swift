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

    /// The base gap between attempts on the same destination, before backoff.
    ///
    /// A failed attempt does not advance the last-completed reference — we
    /// still want the backup to happen — so without this the destination would
    /// stay due and be retried on every tick, hammering an unreachable disk.
    /// The cooldown turns that into an occasional retry instead of a storm.
    /// It doubles with each consecutive non-completing attempt, up to
    /// `maxRetryCooldown` — see `cooldown(consecutiveFailures:)`.
    private let retryCooldown: TimeInterval

    /// The ceiling `retryCooldown` backs off to for a destination that keeps
    /// failing, so it fades into the background instead of retrying forever
    /// on a schedule that never gets shorter.
    private let maxRetryCooldown: TimeInterval

    /// How long a run may report no change at all — same phase, same bytes
    /// copied, same files copied — before it is treated as stalled and the
    /// slot is reclaimed. Generous by design: a long `FindingChanges` or
    /// `Thinning` phase legitimately reports no byte movement.
    private let stallTimeout: TimeInterval

    private let control: any TimeMachineControlling
    private let configuration: ConfigurationStore
    private let history: HistoryStore
    private let state: StateStore
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
    /// a restart should not suppress a fresh one. This only gates *retry
    /// timing* for `evaluate()`'s own next attempt; it plays no part in
    /// fairness ordering between destinations, which is derived fresh from
    /// history every tick so it survives a restart — see
    /// `Scheduler.fairestDue`.
    private var lastAttempt: [String: Date] = [:]

    /// What each currently-open run last reported, and when that was last
    /// observed to change — the stall watchdog's bookkeeping. Keyed by run
    /// id rather than destination so a run adopted after a restart is timed
    /// from the moment this process first observes it, not from a history it
    /// cannot see.
    private var progressSnapshots: [UUID: ProgressSnapshot] = [:]
    private var progressSince: [UUID: Date] = [:]

    private struct ProgressSnapshot: Equatable {
        let phase: BackupActivity.Phase?
        let bytesCopied: Int64?
        let filesCopied: Int64?

        init(_ activity: BackupActivity) {
            switch activity {
            case .idle, .stopping:
                phase = nil
                bytesCopied = nil
                filesCopied = nil
            case .running(_, let phase, let progress):
                self.phase = phase
                bytesCopied = progress?.bytesCopied
                filesCopied = progress?.filesCopied
            }
        }
    }

    /// Guards against actor reentrancy: an `await` inside `evaluate` could
    /// otherwise let a second `evaluate` interleave and double-start.
    private var isWorking = false

    public init(
        control: any TimeMachineControlling,
        configuration: ConfigurationStore,
        history: HistoryStore,
        state: StateStore = StateStore(),
        scheduler: Scheduler,
        now: @escaping @Sendable () -> Date,
        startupGrace: TimeInterval = 120,
        missedGrace: TimeInterval = 15 * 60,
        retryCooldown: TimeInterval = 15 * 60,
        maxRetryCooldown: TimeInterval = 12 * 60 * 60,
        stallTimeout: TimeInterval = 2 * 60 * 60
    ) {
        self.control = control
        self.configuration = configuration
        self.history = history
        self.state = state
        self.scheduler = scheduler
        self.now = now
        self.startupGrace = startupGrace
        self.missedGrace = missedGrace
        self.retryCooldown = retryCooldown
        self.maxRetryCooldown = maxRetryCooldown
        self.stallTimeout = stallTimeout
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

        await reconcileOpenRuns(activity: activity)

        let config = (try? configuration.load()) ?? Configuration()

        // A pause suppresses *scheduled* fires only, and only from here down:
        // the reconciliation above still runs, so pausing never strands an open
        // run in history. A manual `backUpNow` is deliberately unaffected —
        // pausing suppresses the schedule, not the user.
        let currentState = (try? state.load()) ?? AgentState()
        guard !currentState.isPaused(at: now()) else {
            return
        }

        let runs = (try? history.load()) ?? []
        let lastRuns = HistoryStore.lastCompleted(in: runs)
        let lastAttempts = HistoryStore.mostRecentAttempts(in: runs)
        let due = scheduler.dueSchedules(now: now(), schedules: config.schedules, lastRuns: lastRuns)

        let decision = scheduler.decision(
            now: now(), schedules: config.schedules, lastRuns: lastRuns,
            lastAttempts: lastAttempts, activity: activity)
        let winnerID: String? = {
            if case .start(let id) = decision { return id }
            return nil
        }()

        // The tick's nominal winner is excluded from history's skip
        // bookkeeping even if a cooldown defers it below: that deferral
        // already has its own visible `.failed` record, and re-recording it
        // every blocked tick would spam history for a destination that is
        // merely backing off from its own recent failure, not one another
        // destination is starving.
        recordSkipped(
            due: due, excluding: winnerID, lastAttempts: lastAttempts, runs: runs)

        // Respect the retry cooldown so a destination that just failed is not
        // restarted on the very next tick.
        var actuallyStarting: String?
        if let destinationID = winnerID {
            if let last = lastAttempt[destinationID] {
                let wait = cooldown(
                    consecutiveFailures: Self.consecutiveFailures(for: destinationID, in: runs))
                if now().timeIntervalSince(last) >= wait {
                    actuallyStarting = destinationID
                }
            } else {
                actuallyStarting = destinationID
            }
        }

        // Unlike the history record above, the live waiting state does show a
        // destination held back by its own cooldown — there is nothing
        // spam-prone about a value that is simply recomputed every tick, and
        // "waiting" should not go silent just because the cause is
        // self-inflicted rather than another destination.
        updateWaiting(
            due: due, excluding: actuallyStarting, holderID: holder(activity),
            currentState: currentState)

        guard let destinationID = actuallyStarting else { return }

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
        let scheduled = scheduler.nextWakeUp(
            now: now(), schedules: config.schedules, lastRuns: [:])

        // While paused, nothing can happen before the pause expires, so that is
        // the next instant worth waking for — otherwise the agent would sleep
        // through the expiry and stay dormant until something else woke it. It
        // may wake to find nothing due yet and simply re-arm; one spare wake is
        // cheaper than a pause that never ends on its own.
        let currentState = (try? state.load()) ?? AgentState()
        guard let pausedUntil = currentState.pausedUntil, now() < pausedUntil else {
            return scheduled
        }
        return pausedUntil
    }

    // MARK: - Pause

    /// The current pause state, for the menu bar extra and the GUI's banner.
    public func currentState() -> AgentState {
        (try? state.load()) ?? AgentState()
    }

    /// Suppresses scheduled backups until the given instant, or indefinitely
    /// when `nil`. The runner owns this write because the agent is the sole
    /// writer of `state.json`.
    public func pause(until date: Date?) {
        try? state.mutate { current in
            if let date {
                current.pause(until: date)
            } else {
                current.pauseIndefinitely()
            }
        }
    }

    public func resume() {
        try? state.mutate { $0.resume() }
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

    /// Reconciles open `.running` records against what is actually happening,
    /// and reclaims the slot from one that is live but has stopped making
    /// progress.
    private func reconcileOpenRuns(activity: BackupActivity) async {
        let runs = (try? history.load()) ?? []
        let stillOpen = Set(runs.filter { $0.outcome == .running }.map(\.id))
        progressSnapshots = progressSnapshots.filter { stillOpen.contains($0.key) }
        progressSince = progressSince.filter { stillOpen.contains($0.key) }

        for run in runs where run.outcome == .running {
            guard isLive(activity, forDestination: run.destinationID) else {
                closeFinished(run: run)
                continue
            }
            if run.id == openRun?.id { openRun?.observedRunning = true }

            let snapshot = ProgressSnapshot(activity)
            if progressSnapshots[run.id] != snapshot {
                progressSnapshots[run.id] = snapshot
                progressSince[run.id] = now()
                continue
            }
            let since = progressSince[run.id] ?? now()
            if now().timeIntervalSince(since) >= stallTimeout {
                await stall(run: run)
            }
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

    /// A run that is live but has reported no change — same phase, same
    /// bytes, same files — for `stallTimeout`. Stopping it is safe: Time
    /// Machine's in-progress bundle is incremental, so the next attempt
    /// resumes rather than restarting from zero.
    private func stall(run: BackupRun) async {
        try? await control.stopBackup()
        close(run: run, outcome: .failed(reason: "stalled"))
        if run.id == openRun?.id { openRun = nil }
    }

    private func close(run: BackupRun, outcome: BackupRun.Outcome) {
        var closed = run
        closed.finishedAt = now()
        closed.outcome = outcome
        try? history.update(closed)
        progressSnapshots[run.id] = nil
        progressSince[run.id] = nil
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

    // MARK: - Backoff

    /// The retry gap for a destination with this many consecutive attempts
    /// that did not complete: the base cooldown, doubled per failure beyond
    /// the first, capped at `maxRetryCooldown`.
    private func cooldown(consecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return retryCooldown }
        return min(retryCooldown * pow(2, Double(failures - 1)), maxRetryCooldown)
    }

    /// How many attempts on this destination, most recent first, ended in
    /// something other than `.completed` before the streak was broken by one
    /// that did. A `.skipped` occurrence was not an attempt and does not
    /// break or extend the streak.
    private static func consecutiveFailures(for destinationID: String, in runs: [BackupRun]) -> Int
    {
        let relevant = runs.filter { $0.destinationID == destinationID }
            .sorted { $0.startedAt > $1.startedAt }
        var count = 0
        for run in relevant {
            switch run.outcome {
            case .completed: return count
            case .failed, .cancelled: count += 1
            case .running, .skipped: continue
            }
        }
        return count
    }

    // MARK: - Skipped occurrences

    /// Records one `.skipped` entry for every due destination this tick did
    /// not start, deduplicated per occurrence so a schedule blocked across
    /// many ticks yields one entry per missed backup, not one per poll.
    ///
    /// A destination already covered by `lastAttempts` at or after its due
    /// occurrence is excluded even when it is not this tick's winner: that
    /// covers a run still open and awaiting confirmation, and a run this same
    /// tick's reconciliation just closed (completed, failed, or stalled) —
    /// both were genuinely attempted, not skipped, and already have their own
    /// record of what happened.
    private func recordSkipped(
        due: [(destinationID: String, occurrence: Date)],
        excluding winnerID: String?,
        lastAttempts: [String: Date],
        runs: [BackupRun]
    ) {
        let alreadyRecorded = Set(
            runs.compactMap { run -> String? in
                guard case .skipped = run.outcome else { return nil }
                return skipKey(destinationID: run.destinationID, occurrence: run.startedAt)
            })
        for (destinationID, occurrence) in due where destinationID != winnerID {
            if let attempted = lastAttempts[destinationID], attempted >= occurrence { continue }
            let key = skipKey(destinationID: destinationID, occurrence: occurrence)
            guard !alreadyRecorded.contains(key) else { continue }
            let run = BackupRun(
                destinationID: destinationID, trigger: .scheduled, startedAt: occurrence,
                finishedAt: now(), outcome: .skipped(reason: nil))
            try? history.append(run)
        }
    }

    private func skipKey(destinationID: String, occurrence: Date) -> String {
        "\(destinationID)|\(occurrence.timeIntervalSinceReferenceDate)"
    }

    // MARK: - Waiting state

    /// Publishes why a due backup could not start, for the GUI and the menu
    /// bar extra, and clears it the instant one does. Unlike `recordSkipped`,
    /// this excludes only what is actually starting this tick — a
    /// destination held back by its own retry cooldown still shows as
    /// blocked here, because there is no history to spam and the UI should
    /// not go silent just because the cause is self-inflicted. `since` is
    /// carried forward across ticks rather than reset, so the UI can show how
    /// long the block has lasted.
    private func updateWaiting(
        due: [(destinationID: String, occurrence: Date)],
        excluding startingID: String?,
        holderID: String?,
        currentState: AgentState
    ) {
        let blocked = due.filter { $0.destinationID != startingID }
            .min { $0.occurrence < $1.occurrence }

        guard let blocked else {
            if currentState.waiting != nil { try? state.mutate { $0.setWaiting(nil) } }
            return
        }

        let since =
            if let previous = currentState.waiting,
                previous.blockedDestinationID == blocked.destinationID
            {
                previous.since
            } else {
                now()
            }
        let waiting = AgentState.Waiting(
            blockedDestinationID: blocked.destinationID, holderDestinationID: holderID,
            since: since)
        if currentState.waiting != waiting {
            try? state.mutate { $0.setWaiting(waiting) }
        }
    }

    private func holder(_ activity: BackupActivity) -> String? {
        switch activity {
        case .idle: return nil
        case .running(let destinationID, _, _), .stopping(let destinationID):
            return destinationID
        }
    }
}

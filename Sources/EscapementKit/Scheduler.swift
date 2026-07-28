import Foundation

/// The decision the agent should act on at a given instant.
public enum SchedulerDecision: Hashable, Sendable {
    case idle
    case start(destinationID: String)
}

/// The pure heart of the agent: given the world's current state, decide
/// whether to start a backup and compute when next to wake. No clock, no
/// timer, no I/O — every input is a parameter, so the whole thing is
/// exhaustively testable.
public struct Scheduler: Sendable {

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Whether and what to start right now.
    ///
    /// - Parameters:
    ///   - now: the current instant.
    ///   - schedules: the configured schedules.
    ///   - lastRuns: the last completed run per destination id.
    ///   - lastAttempts: the last *attempted* run per destination id — every
    ///     outcome except a skipped occurrence — used to order between
    ///     several due destinations. A destination absent from this map is
    ///     treated as never attempted.
    ///   - activity: what backupd is doing right now.
    public func decision(
        now: Date,
        schedules: [DestinationSchedule],
        lastRuns: [String: Date],
        lastAttempts: [String: Date] = [:],
        activity: BackupActivity
    ) -> SchedulerDecision {
        // Rule 1: one backup at a time. Anything but idle means wait.
        guard activity == .idle else { return .idle }

        guard
            let winner = fairestDue(
                now: now, schedules: schedules, lastRuns: lastRuns, lastAttempts: lastAttempts)
        else { return .idle }
        return .start(destinationID: winner.destinationID)
    }

    /// The due schedule that has waited longest since its last attempt —
    /// least-recently-attempted wins, not most-overdue. A destination that
    /// never completes stays due forever, so ordering by overdue-ness alone
    /// lets it monopolise the slot: it is always the most overdue schedule,
    /// so it reclaims the slot the instant it is free, ahead of destinations
    /// it has been starving. Ordering by last attempt instead means an
    /// attempt — successful or not — costs a destination its priority, so a
    /// failing destination cycles through the rotation rather than owning it.
    ///
    /// Ties break on the earlier due occurrence, then configuration order,
    /// preserving the original ordering when no destination has an attempt
    /// history — `min(by:)` keeps the earlier element on equal keys.
    private func fairestDue(
        now: Date,
        schedules: [DestinationSchedule],
        lastRuns: [String: Date],
        lastAttempts: [String: Date]
    ) -> (destinationID: String, due: Date)? {
        schedules
            .compactMap { schedule -> (destinationID: String, due: Date)? in
                guard let due = dueOccurrence(for: schedule, now: now, lastRuns: lastRuns) else {
                    return nil
                }
                return (schedule.destinationID, due)
            }
            .min { a, b in
                let attemptA = lastAttempts[a.destinationID] ?? .distantPast
                let attemptB = lastAttempts[b.destinationID] ?? .distantPast
                if attemptA != attemptB { return attemptA < attemptB }
                return a.due < b.due
            }
    }

    /// Every schedule that is due right now, independent of whether a backup
    /// can actually start. `SchedulerRunner` uses this to see past rule 1's
    /// single verdict: a due destination that is not `decision`'s winner —
    /// because rule 1 gave the slot to another destination, or because that
    /// winner's own retry cooldown deferred it — is recorded as skipped in
    /// history, or surfaced as the live waiting reason, or both.
    public func dueSchedules(
        now: Date,
        schedules: [DestinationSchedule],
        lastRuns: [String: Date]
    ) -> [(destinationID: String, occurrence: Date)] {
        schedules.compactMap { schedule in
            guard let due = dueOccurrence(for: schedule, now: now, lastRuns: lastRuns) else {
                return nil
            }
            return (schedule.destinationID, due)
        }
    }

    /// The earliest strictly-future occurrence across all enabled schedules,
    /// or `nil` if nothing is scheduled. Independent of last-run history:
    /// overdue occurrences are handled by `decision`, so the timer only looks
    /// forward.
    public func nextWakeUp(
        now: Date,
        schedules: [DestinationSchedule],
        lastRuns: [String: Date]
    ) -> Date? {
        schedules
            .filter(\.isEnabled)
            .compactMap {
                $0.recurrence.nextFireDate(
                    after: now, calendar: calendar, anchor: $0.effectiveFrom)
            }
            .min()
    }

    // MARK: - Due determination

    /// The occurrence that makes this schedule due now, or `nil` if it is not
    /// due. The reference is the last run, or `effectiveFrom` if it has never
    /// run — so a long outage produces one overdue occurrence, not one per
    /// missed period.
    ///
    /// Exposed within the module so `SchedulerRunner` can classify a start as
    /// on-time or a slept-through catch-up from the same occurrence the
    /// decision used.
    func dueOccurrence(
        for schedule: DestinationSchedule,
        now: Date,
        lastRuns: [String: Date]
    ) -> Date? {
        guard schedule.isEnabled else { return nil }
        let reference = lastRuns[schedule.destinationID] ?? schedule.effectiveFrom
        guard
            let occurrence = schedule.recurrence.nextFireDate(
                after: reference, calendar: calendar, anchor: schedule.effectiveFrom)
        else { return nil }
        return occurrence <= now ? occurrence : nil
    }
}

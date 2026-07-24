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
    ///   - activity: what backupd is doing right now.
    public func decision(
        now: Date,
        schedules: [DestinationSchedule],
        lastRuns: [String: Date],
        activity: BackupActivity
    ) -> SchedulerDecision {
        // Rule 1: one backup at a time. Anything but idle means wait.
        guard activity == .idle else { return .idle }

        // The most overdue due schedule wins; configuration order breaks ties
        // because `min(by:)` keeps the earlier element on equal keys.
        let mostOverdue = schedules
            .compactMap { schedule -> (schedule: DestinationSchedule, due: Date)? in
                guard let due = dueOccurrence(for: schedule, now: now, lastRuns: lastRuns) else {
                    return nil
                }
                return (schedule, due)
            }
            .min { $0.due < $1.due }

        guard let winner = mostOverdue else { return .idle }
        return .start(destinationID: winner.schedule.destinationID)
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

import Foundation

/// The whole-system summary shown at the top of the menu bar extra: what is
/// happening now, and when a backup last finished.
///
/// Distinct from `DestinationRow`, which describes one destination for the
/// list. This answers "should I care right now?" without opening the app.
public struct StatusSummary: Hashable, Sendable {
    /// What is happening, in priority order: running, else paused, else the
    /// next scheduled backup, else nothing scheduled.
    public let stateLine: String
    /// When a backup last finished, however it finished.
    public let latestLine: String
    public let isRunning: Bool
    public let isPaused: Bool

    public init(stateLine: String, latestLine: String, isRunning: Bool, isPaused: Bool) {
        self.stateLine = stateLine
        self.latestLine = latestLine
        self.isRunning = isRunning
        self.isPaused = isPaused
    }
}

/// Builds the summary. Pure and free of AppKit so the agent and the GUI cannot
/// drift into describing the same state differently.
public struct StatusSummaryBuilder: Sendable {
    let calendar: Calendar
    let locale: Locale

    public init(calendar: Calendar, locale: Locale) {
        self.calendar = calendar
        self.locale = locale
    }

    public func summary(
        destinations: [Destination],
        configuration: Configuration,
        state: AgentState,
        history: [BackupRun],
        activity: BackupActivity,
        now: Date
    ) -> StatusSummary {
        StatusSummary(
            stateLine: stateLine(
                destinations: destinations, configuration: configuration,
                state: state, activity: activity, now: now),
            latestLine: latestLine(history: history, now: now),
            isRunning: activity != .idle,
            isPaused: state.isPaused(at: now))
    }

    // MARK: - State

    private func stateLine(
        destinations: [Destination], configuration: Configuration,
        state: AgentState, activity: BackupActivity, now: Date
    ) -> String {
        // A backup in flight is the most urgent thing to say, and it is true
        // even while paused — a manual run is allowed during a pause.
        switch activity {
        case .running(_, let phase, let progress):
            if let fraction = progress?.fractionCompleted {
                return "\(phase.displayName) — \(Int(fraction * 100))%"
            }
            return phase.displayName
        case .stopping:
            return "Stopping…"
        case .idle:
            break
        }

        if state.isPaused(at: now) {
            guard !state.isPausedIndefinitely, let until = state.pausedUntil else {
                return "Paused"
            }
            return "Paused until \(timeFormatter.string(from: until))"
        }

        guard let next = nextOccurrence(destinations: destinations, configuration: configuration, now: now)
        else { return "No backups scheduled" }
        return "Next backup: \(next.name) at \(timeFormatter.string(from: next.date))"
    }

    /// The soonest enabled schedule across all destinations, with the name to
    /// show for it.
    private func nextOccurrence(
        destinations: [Destination], configuration: Configuration, now: Date
    ) -> (name: String, date: Date)? {
        configuration.schedules
            .filter(\.isEnabled)
            .compactMap { schedule -> (name: String, date: Date)? in
                guard
                    let date = schedule.recurrence.nextFireDate(
                        after: now, calendar: calendar, anchor: schedule.effectiveFrom)
                else { return nil }
                // A schedule can outlive the destination being attached. Naming
                // the bare id is more honest than dropping it and implying
                // nothing is due.
                let name =
                    destinations.first { $0.id == schedule.destinationID }?.name
                    ?? schedule.destinationID
                return (name, date)
            }
            .min { $0.date < $1.date }
    }

    // MARK: - Latest

    private func latestLine(history: [BackupRun], now: Date) -> String {
        // An in-progress run is reported by the state line, not here, and a
        // skipped occurrence never ran at all, so only finished attempts
        // that actually happened count.
        let finished = history.filter {
            switch $0.outcome {
            case .running, .skipped: return false
            case .completed, .failed, .cancelled: return true
            }
        }
        guard
            let latest = finished.max(by: {
                ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt)
            })
        else { return "Latest backup: never" }

        let when = describe(latest.finishedAt ?? latest.startedAt, relativeTo: now)
        switch latest.outcome {
        case .completed, .running:
            return "Latest backup: \(when)"
        case .failed:
            return "Latest backup: failed \(when)"
        case .cancelled:
            return "Latest backup: cancelled \(when)"
        case .skipped:
            // Excluded by the filter above; kept only for exhaustiveness.
            return "Latest backup: \(when)"
        }
    }

    // MARK: - Formatters

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    /// Names an instant relative to the given "now" — "Today at 9:30 AM".
    ///
    /// `DateFormatter.doesRelativeDateFormatting` is deliberately not used: it
    /// resolves "today" against the *system* clock, so it would ignore the
    /// injected clock and quietly disagree with the rest of the engine.
    private func describe(_ date: Date, relativeTo now: Date) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday at \(time)"
        }
        return "\(dateFormatter.string(from: date)) at \(time)"
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

extension BackupActivity.Phase {
    /// The user-facing name of a phase. Lives here rather than in the app
    /// target because the menu bar extra, which runs in the agent, needs it too.
    public var displayName: String {
        switch self {
        case .mountingDiskImage: return "Mounting backup disk"
        case .preparing: return "Preparing"
        case .findingChanges: return "Finding changes"
        case .copying: return "Copying"
        case .thinning: return "Cleaning up"
        case .finishing: return "Finishing"
        case .other(let raw): return raw.isEmpty ? "Backing up" : raw
        }
    }
}

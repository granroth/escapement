import EscapementKit
import Foundation

/// A destination as the status list needs to show it: the live facts joined
/// with the configured schedule and the recent history, pre-formatted so the
/// view layer stays dumb.
struct DestinationRow {
    let destination: Destination
    let hasSchedule: Bool
    let isEnabled: Bool
    let scheduleSummary: String
    let statusText: String
    let progress: Double?
    let isBusy: Bool
    let lastRunText: String
    let nextRunText: String
}

/// Turns the app's raw state into rows. Pure and `@MainActor`-free so it can be
/// reasoned about (and, later, tested) without the UI.
struct RowBuilder {
    let calendar: Calendar
    let locale: Locale

    private var recurrenceFormatter: RecurrenceFormatter {
        RecurrenceFormatter(calendar: calendar, locale: locale)
    }

    func rows(
        destinations: [Destination],
        configuration: Configuration,
        history: [BackupRun],
        activity: BackupActivity,
        now: Date
    ) -> [DestinationRow] {
        destinations.map { destination in
            let schedule = configuration.schedule(for: destination.id)
            return DestinationRow(
                destination: destination,
                hasSchedule: schedule != nil,
                isEnabled: schedule?.isEnabled ?? false,
                scheduleSummary: scheduleSummary(schedule),
                statusText: statusText(for: destination.id, activity: activity),
                progress: progress(for: destination.id, activity: activity),
                isBusy: isBusy(for: destination.id, activity: activity),
                lastRunText: lastRunText(for: destination.id, history: history, now: now),
                nextRunText: nextRunText(schedule, now: now))
        }
    }

    private func scheduleSummary(_ schedule: DestinationSchedule?) -> String {
        guard let schedule else { return "No schedule" }
        let summary = recurrenceFormatter.summary(schedule.recurrence)
        return schedule.isEnabled ? summary : "\(summary) (paused)"
    }

    private func statusText(for id: String, activity: BackupActivity) -> String {
        switch activity {
        case .idle:
            return "Idle"
        case .running(let destinationID, let phase, let progress):
            guard destinationID == nil || destinationID == id else { return "Idle" }
            if let progress {
                return "\(phase.displayName) — \(Int(progress * 100))%"
            }
            return phase.displayName
        case .stopping(let destinationID):
            guard destinationID == nil || destinationID == id else { return "Idle" }
            return "Stopping…"
        }
    }

    private func progress(for id: String, activity: BackupActivity) -> Double? {
        if case .running(let destinationID, _, let progress) = activity,
            destinationID == nil || destinationID == id
        {
            return progress
        }
        return nil
    }

    private func isBusy(for id: String, activity: BackupActivity) -> Bool {
        switch activity {
        case .idle: return false
        case .running(let destinationID, _, _), .stopping(let destinationID):
            return destinationID == nil || destinationID == id
        }
    }

    private func lastRunText(for id: String, history: [BackupRun], now: Date) -> String {
        // The "last run" is the most recent *finished* attempt; an in-progress
        // one is conveyed by the status column, not here.
        guard
            let run = history.first(where: {
                $0.destinationID == id && $0.outcome != .running
            })
        else { return "Never" }
        let when = run.finishedAt ?? run.startedAt
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        let ago = relative.localizedString(for: when, relativeTo: now)
        switch run.outcome {
        case .completed, .running: return ago
        case .cancelled: return "Cancelled \(ago)"
        case .failed: return "Failed \(ago)"
        }
    }

    private func nextRunText(_ schedule: DestinationSchedule?, now: Date) -> String {
        guard let schedule, schedule.isEnabled,
            let next = schedule.recurrence.nextFireDate(
                after: now, calendar: calendar, anchor: schedule.effectiveFrom)
        else { return "—" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: next)
    }
}

// `BackupActivity.Phase.displayName` moved to EscapementKit when the agent's
// menu bar extra needed the same wording.

extension Destination.Kind {
    var displayName: String {
        switch self {
        case .local: return "Local disk"
        case .network: return "Network share"
        }
    }
}

import Foundation

/// One recorded backup attempt, for the status view and the detailed log.
public struct BackupRun: Codable, Hashable, Sendable, Identifiable {

    public enum Trigger: Codable, Hashable, Sendable {
        /// Started at its scheduled time.
        case scheduled
        /// Started by the user pressing "Back Up Now".
        case manual
        /// Started as catch-up for an occurrence the machine slept through.
        case missed
    }

    public enum Outcome: Codable, Hashable, Sendable {
        case running
        case completed
        /// Ended in failure; the string is a best-effort reason where one is
        /// known.
        case failed(reason: String?)
        case cancelled
    }

    public let id: UUID
    public let destinationID: String
    public let trigger: Trigger
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: Outcome

    public init(
        id: UUID = UUID(),
        destinationID: String,
        trigger: Trigger,
        startedAt: Date,
        finishedAt: Date? = nil,
        outcome: Outcome = .running
    ) {
        self.id = id
        self.destinationID = destinationID
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
    }
}

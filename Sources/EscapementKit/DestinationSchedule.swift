import Foundation

/// A user's schedule for one destination.
public struct DestinationSchedule: Codable, Hashable, Sendable, Identifiable {

    /// The destination this schedule drives. Also the stable identity of the
    /// schedule, since a destination has at most one.
    public let destinationID: String
    public var recurrence: Recurrence
    public var isEnabled: Bool

    /// The instant from which occurrences count. Set to "now" when the
    /// schedule is created or its recurrence changed, so that configuring a
    /// schedule never triggers an immediate backup, and used as the catch-up
    /// baseline for a destination that has not yet run.
    public var effectiveFrom: Date

    public var id: String { destinationID }

    public init(
        destinationID: String, recurrence: Recurrence, isEnabled: Bool, effectiveFrom: Date
    ) {
        self.destinationID = destinationID
        self.recurrence = recurrence
        self.isEnabled = isEnabled
        self.effectiveFrom = effectiveFrom
    }
}

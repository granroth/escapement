import Foundation

/// The persisted set of per-destination schedules.
public struct Configuration: Codable, Hashable, Sendable {

    /// The current on-disk format version. Bumped only on a breaking change.
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var schedules: [DestinationSchedule]

    public init(schedules: [DestinationSchedule] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.schedules = schedules
    }

    /// The schedule for a destination, if one exists.
    public func schedule(for destinationID: String) -> DestinationSchedule? {
        schedules.first { $0.destinationID == destinationID }
    }

    /// Inserts or replaces the schedule for its destination, preserving the
    /// position of an existing entry so the user's ordering is stable.
    public mutating func upsert(_ schedule: DestinationSchedule) {
        if let index = schedules.firstIndex(where: { $0.destinationID == schedule.destinationID }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    /// Removes the schedule for a destination, if present.
    public mutating func removeSchedule(for destinationID: String) {
        schedules.removeAll { $0.destinationID == destinationID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case schedules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A file predating versioning decodes as version 1 rather than failing.
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        schedules = try container.decode([DestinationSchedule].self, forKey: .schedules)
    }
}

import Foundation

/// The persisted schedules and the GUI-owned preferences that go with them.
///
/// The GUI is the sole writer of this file (see `ARCHITECTURE.md`): the file
/// lock in `JSONFileStore` is per-process and cannot serialise the two
/// processes, so anything the *agent* needs to write lives in `AgentState`
/// instead.
public struct Configuration: Codable, Hashable, Sendable {

    /// The current on-disk format version. Bumped only on a breaking change.
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var schedules: [DestinationSchedule]

    /// Whether the agent shows its menu bar extra.
    ///
    /// A GUI-owned preference living in the GUI-owned file, so the single-writer
    /// rule holds; the agent watches the support directory and picks the change
    /// up on its next tick. A menu bar item the user cannot hide would be
    /// un-Mac-like, and Settings is the only place left to bring it back.
    public var showsMenuBarIcon: Bool

    /// Whether the agent posts a notification when a backup fails. Off by
    /// default: a background thing that starts talking uninvited is worse than
    /// one the user turns on deliberately.
    public var notifiesOnFailure: Bool

    public init(
        schedules: [DestinationSchedule] = [],
        showsMenuBarIcon: Bool = true,
        notifiesOnFailure: Bool = false
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.schedules = schedules
        self.showsMenuBarIcon = showsMenuBarIcon
        self.notifiesOnFailure = notifiesOnFailure
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
        case showsMenuBarIcon
        case notifiesOnFailure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A file predating versioning decodes as version 1 rather than failing.
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        schedules = try container.decode([DestinationSchedule].self, forKey: .schedules)
        // A file predating the preference decodes as showing the icon, which is
        // the default for a fresh install too. No schema bump: an older build
        // simply ignores the key.
        showsMenuBarIcon =
            try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarIcon) ?? true
        notifiesOnFailure =
            try container.decodeIfPresent(Bool.self, forKey: .notifiesOnFailure) ?? false
    }
}

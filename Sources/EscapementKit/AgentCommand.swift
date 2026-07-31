import Foundation

/// A one-shot instruction from the GUI to the background agent, exchanged
/// through `command.json`. The GUI never invokes `tmutil` write verbs itself;
/// it asks the agent to, so the agent stays the single owner of firing and of
/// the run history.
public enum AgentCommand: Codable, Hashable, Sendable {
    case backUpNow(destinationID: String)
    case stop
    /// Suppress scheduled backups until the given instant. A `nil` date means
    /// indefinitely — until the user resumes.
    ///
    /// Pause is a command rather than a configuration edit because the agent is
    /// the sole writer of the pause state: its own menu bar extra can pause too,
    /// and two processes writing one file would race.
    case pause(until: Date?)
    case resume
    /// Check for a newer release immediately, ignoring the configured
    /// interval and when the last check happened — the Settings "Check Now"
    /// button.
    case checkForUpdatesNow
}

/// Reads and writes the pending manual command.
///
/// Not a persistent value like the configuration: the file is present only when
/// a command is waiting. `take` reads and removes it, so a command is acted on
/// exactly once, and a malformed file is discarded rather than left to wedge the
/// agent.
public struct CommandStore: Sendable {
    private let url: URL

    public init(url: URL = EscapementPaths.commandURL()) {
        self.url = url
    }

    /// Writes a command, replacing any unprocessed one. Atomic, so the agent
    /// never reads a half-written file.
    public func post(_ command: AgentCommand) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(command)
        try data.write(to: url, options: .atomic)
    }

    /// Returns the pending command and removes it, or `nil` if none is waiting.
    /// A file that cannot be decoded is removed and reported as no command, so
    /// a corrupt write cannot stall the agent.
    ///
    /// The file is claimed by renaming it aside before reading, so a command the
    /// GUI posts in the instant between read and delete lands as a fresh
    /// `command.json` that is not clobbered — closing the read-then-delete race.
    public func take() throws -> AgentCommand? {
        let claimed = url.deletingLastPathComponent()
            .appendingPathComponent(".command.\(UUID().uuidString).claimed")
        do {
            try FileManager.default.moveItem(at: url, to: claimed)
        } catch {
            return nil  // nothing waiting
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed) else { return nil }
        return try? JSONDecoder().decode(AgentCommand.self, from: data)
    }

    /// Discards any pending command. Used when enabling or disabling the agent
    /// so a command that has been waiting through a disabled period does not
    /// fire unexpectedly when the agent next runs.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

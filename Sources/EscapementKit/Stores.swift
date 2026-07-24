import Foundation

/// The on-disk locations Escapement uses, all under Application Support so the
/// app and the agent agree without hard-coding paths in two places.
public enum EscapementPaths {

    /// `~/Library/Application Support/Escapement`, created lazily by the stores
    /// when first written.
    public static func supportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Escapement", isDirectory: true)
    }

    public static func configurationURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("configuration.json")
    }

    public static func historyURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("history.json")
    }

    /// The pending manual command from the GUI to the agent.
    public static func commandURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("command.json")
    }
}

/// Reads and writes the user's schedules.
public struct ConfigurationStore: Sendable {
    private let store: JSONFileStore<Configuration>

    public init(url: URL = EscapementPaths.configurationURL()) {
        store = JSONFileStore(url: url, default: Configuration())
    }

    public func load() throws -> Configuration { try store.load() }
    public func save(_ configuration: Configuration) throws { try store.save(configuration) }
}

/// Reads and writes the run history, newest first, capped so the file cannot
/// grow without bound.
public struct HistoryStore: Sendable {

    /// How many runs to retain. Generous enough for a meaningful log, bounded
    /// so an always-on Mac backing up several times a day does not grow the
    /// file forever.
    public static let retentionLimit = 500

    private let store: JSONFileStore<[BackupRun]>
    private let limit: Int

    public init(url: URL = EscapementPaths.historyURL(), retentionLimit: Int = retentionLimit) {
        store = JSONFileStore(url: url, default: [])
        limit = retentionLimit
    }

    /// All retained runs, newest first.
    public func load() throws -> [BackupRun] { try store.load() }

    /// Records a new run at the front, trimming the oldest beyond the limit.
    /// The read-modify-write runs under the store's file lock so concurrent
    /// appends cannot drop each other's entries.
    public func append(_ run: BackupRun) throws {
        try store.mutate { runs in
            runs.insert(run, at: 0)
            if runs.count > limit { runs.removeLast(runs.count - limit) }
        }
    }

    /// Replaces a run with the same id — used to move a run from `.running` to
    /// its final outcome. A no-op if the id is not present. Atomic against
    /// concurrent writers, as with `append`.
    public func update(_ run: BackupRun) throws {
        try store.mutate { runs in
            guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
            runs[index] = run
        }
    }

    /// The most recent completed run per destination, for the scheduler's
    /// last-run reference. Only `.completed` runs count: a failed or cancelled
    /// attempt did not back anything up, so it must not suppress the next
    /// scheduled attempt.
    public func lastCompletedRuns() throws -> [String: Date] {
        var result: [String: Date] = [:]
        for run in try load() where run.outcome == .completed {
            let when = run.finishedAt ?? run.startedAt
            if let existing = result[run.destinationID], existing >= when { continue }
            result[run.destinationID] = when
        }
        return result
    }
}

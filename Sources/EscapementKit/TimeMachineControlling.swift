import Foundation

/// The seam between Escapement and Time Machine.
///
/// Everything that touches `tmutil` lives behind this protocol so the
/// scheduling logic can be driven by a fake in tests, with no destination and
/// no live backup.
public protocol TimeMachineControlling: Sendable {

    /// The configured destinations. An empty array is a normal result: it is
    /// what a Mac with Time Machine never set up looks like.
    func destinations() async throws -> [Destination]

    /// Whether macOS's own scheduler is running. Never throws: an inability to
    /// read the flag resolves to `.unknown`, not an error, because the flag
    /// lives behind Full Disk Access that Escapement does not require.
    func automaticBackupState() async -> AutomaticBackupState

    /// What backupd is doing right now.
    func activity() async throws -> BackupActivity

    /// Requests a backup to the given destination.
    ///
    /// - Important: Returning without throwing means only that the *request*
    ///   was dispatched. It is **not** a success signal: `tmutil` exits zero
    ///   even when backupd refuses the work outright. Confirmation comes only
    ///   from a subsequent `activity()` showing the backup running. Callers
    ///   must not treat a clean return as "the backup happened".
    func startBackup(destinationID: String) async throws

    /// Requests cancellation of any backup in progress. As with `startBackup`,
    /// this dispatches a request; the transition is observed via `activity()`
    /// and may sit in `.stopping` for some time.
    func stopBackup() async throws
}

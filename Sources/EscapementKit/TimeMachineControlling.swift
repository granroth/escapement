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

/// A control error that may have taken effect despite failing.
///
/// `startbackup` hands work to `backupd` and returns; the two are not the same
/// event. An error raised *after* the request was dispatched — a timeout, most
/// obviously — says nothing about whether the backup is now starting. Callers
/// must not record such a run as failed on the strength of the error alone,
/// because doing so both lies about the outcome and leaves the real backup to
/// be re-adopted later as a second, unrelated history record.
///
/// A failure to *launch the tool at all* is the opposite case: nothing was
/// dispatched, and closing the run immediately is correct.
public protocol PossiblyDispatchedError: Error {
    /// True when the request may already have reached `backupd`.
    var mayHaveDispatched: Bool { get }
}

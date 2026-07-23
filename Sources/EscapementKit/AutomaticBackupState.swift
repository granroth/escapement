import Foundation

/// Whether macOS's own backup scheduler is running.
///
/// Escapement requires it to be off ("Manually" in System Settings), because
/// backup frequency is a single system-wide setting with no per-destination
/// equivalent: if Apple's scheduler is also running, both it and Escapement
/// start backups and neither is in charge.
///
/// `unknown` is a first-class outcome, not an error. The authoritative flag
/// lives in a preferences file that requires Full Disk Access to read, and
/// Escapement declines to demand that. When the state cannot be determined the
/// UI shows a softer caution and still allows scheduling — it never blocks the
/// user solely because it could not read the flag.
public enum AutomaticBackupState: Hashable, Sendable {
    /// macOS is backing up on its own schedule. Conflicts with Escapement.
    case automatic
    /// Set to "Manually"; the field is clear for Escapement.
    case manual
    /// Could not be determined without privileges Escapement does not require.
    case unknown
}

import Foundation

/// What backupd is doing right now, distilled from `tmutil status`.
///
/// Modelled as a sum type rather than a bag of optionals so that impossible
/// combinations — a progress value while idle, a phase while stopped — cannot
/// be represented.
public enum BackupActivity: Hashable, Sendable {
    case idle
    case running(destinationID: String?, phase: Phase, progress: Double?)
    /// A cancellation is in flight. Observed to persist for tens of seconds on
    /// network destinations, so it is a state in its own right, not a blink
    /// between running and idle.
    case stopping(destinationID: String?)

    /// The named phase of a running backup. `tmutil` reports these as bare
    /// strings; the common ones are typed, and anything unrecognised is
    /// preserved verbatim rather than discarded so the UI can still show it.
    public enum Phase: Hashable, Sendable {
        case mountingDiskImage
        case preparing
        case findingChanges
        case copying
        case thinning
        case finishing
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "MountingDiskImage": self = .mountingDiskImage
            case "PreparingSourceVolumes", "Preparing", "FindingBackupVol": self = .preparing
            case "FindingChanges": self = .findingChanges
            case "Copying": self = .copying
            case "ThinningPreBackup", "ThinningPostBackup", "Thinning": self = .thinning
            case "Finishing": self = .finishing
            default: self = .other(rawValue)
            }
        }
    }
}

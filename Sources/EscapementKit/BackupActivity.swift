import Foundation

/// What backupd is doing right now, distilled from `tmutil status`.
///
/// Modelled as a sum type rather than a bag of optionals so that impossible
/// combinations — a progress value while idle, a phase while stopped — cannot
/// be represented.
public enum BackupActivity: Hashable, Sendable {
    case idle
    case running(destinationID: String?, phase: Phase, progress: BackupProgress?)
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

/// Time Machine's current estimate for a running backup. Every field is
/// optional because backupd learns them at different phases and may revise or
/// withdraw an estimate while a run is in progress.
public struct BackupProgress: Hashable, Sendable {
    public let fractionCompleted: Double?
    public let bytesCopied: Int64?
    public let totalBytes: Int64?
    public let filesCopied: Int64?
    public let totalFiles: Int64?
    public let timeRemaining: TimeInterval?

    public init(
        fractionCompleted: Double? = nil,
        bytesCopied: Int64? = nil,
        totalBytes: Int64? = nil,
        filesCopied: Int64? = nil,
        totalFiles: Int64? = nil,
        timeRemaining: TimeInterval? = nil
    ) {
        self.fractionCompleted = Self.fraction(fractionCompleted)
        self.bytesCopied = Self.nonnegative(bytesCopied)
        self.totalBytes = Self.nonnegative(totalBytes)
        self.filesCopied = Self.nonnegative(filesCopied)
        self.totalFiles = Self.nonnegative(totalFiles)
        self.timeRemaining =
            if let timeRemaining, timeRemaining.isFinite, timeRemaining >= 0 {
                timeRemaining
            } else {
                nil
            }
    }

    public var isEmpty: Bool {
        fractionCompleted == nil
            && bytesCopied == nil
            && totalBytes == nil
            && filesCopied == nil
            && totalFiles == nil
            && timeRemaining == nil
    }

    private static func fraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 1)
    }

    private static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

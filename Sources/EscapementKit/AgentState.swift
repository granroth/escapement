import Foundation

/// State the agent owns and publishes for the GUI to read, in `state.json`.
///
/// Separate from `Configuration` on purpose. The file lock in `JSONFileStore` is
/// per-process, so it cannot serialise the GUI against the agent; the only thing
/// keeping the two from clobbering each other is the single-writer rule from
/// `ARCHITECTURE.md`. Pause has to be writable from the agent's own menu bar
/// extra, so it cannot live in the GUI-owned configuration file — a pause and a
/// schedule edit would race on the same read-modify-write and one would be lost.
/// The GUI asks for a pause through `AgentCommand` instead.
public struct AgentState: Codable, Hashable, Sendable {

    /// When set, scheduled backups are suppressed until this instant. `nil`
    /// means running normally.
    ///
    /// Pause is the *soft* stop, deliberately distinct from disabling the agent:
    /// unregistering tears down the Login Items registration and may need
    /// re-approval to undo, which is far too heavy for "not for the next two
    /// hours". Persisting it means a pause survives restart and login.
    public private(set) var pausedUntil: Date?

    /// Set while a due schedule cannot start because another destination
    /// holds the slot or a retry cooldown is in effect, and cleared the
    /// instant something starts. Without this a starved schedule is
    /// indistinguishable from a dead agent: a blocked tick otherwise leaves
    /// no trace anywhere the GUI can read.
    public private(set) var waiting: Waiting?

    /// One destination the scheduler could not start this tick, and — when
    /// known — the destination currently holding the slot.
    public struct Waiting: Codable, Hashable, Sendable {
        public let blockedDestinationID: String?
        public let holderDestinationID: String?
        /// When this destination first became blocked, so the UI can show
        /// "waiting since 10:00" rather than resetting every tick.
        public let since: Date

        public init(blockedDestinationID: String?, holderDestinationID: String?, since: Date) {
            self.blockedDestinationID = blockedDestinationID
            self.holderDestinationID = holderDestinationID
            self.since = since
        }
    }

    /// When the agent last checked for a newer release, regardless of
    /// outcome. `nil` means never.
    public private(set) var lastUpdateCheck: Date?

    /// The newer release found by the most recent successful check, if any.
    /// Cleared by a successful check that finds nothing newer; left alone by
    /// a failed one, so a transient network outage can't erase a real result.
    public private(set) var availableUpdate: AvailableUpdate?

    /// Whether macOS is suppressing the menu bar item, so the GUI can explain
    /// a ticked "Show Escapement in the menu bar" box with no icon beside it.
    ///
    /// Optional rather than defaulting to `false` so a `state.json` written by
    /// an agent that predates the field still decodes: a missing key would
    /// otherwise throw and discard every other value in the file, including the
    /// pause. `nil` means no agent has reported either way.
    public private(set) var menuBarIconSuppressed: Bool?

    public init(pausedUntil: Date? = nil, waiting: Waiting? = nil) {
        self.pausedUntil = pausedUntil
        self.waiting = waiting
    }

    /// Whether scheduled backups are suppressed at the given instant.
    ///
    /// The window is half-open, so a one-hour pause ends exactly an hour later
    /// rather than a tick after.
    public func isPaused(at date: Date) -> Bool {
        guard let pausedUntil else { return false }
        return date < pausedUntil
    }

    /// Whether the pause is the open-ended kind, which reads differently in the
    /// UI: "until I resume" rather than a countdown to a time.
    public var isPausedIndefinitely: Bool { pausedUntil == .distantFuture }

    public mutating func pause(until date: Date) {
        pausedUntil = date
    }

    /// Pauses with no scheduled end. `.distantFuture` is the sentinel rather
    /// than a separate flag, so every pause stays one comparison against a date.
    public mutating func pauseIndefinitely() {
        pausedUntil = .distantFuture
    }

    public mutating func resume() {
        pausedUntil = nil
    }

    public mutating func setMenuBarIconSuppressed(_ suppressed: Bool) {
        menuBarIconSuppressed = suppressed
    }

    public mutating func setWaiting(_ waiting: Waiting?) {
        self.waiting = waiting
    }

    /// Records a completed check. Always overwrites `availableUpdate`,
    /// including to `nil` — a check that finds nothing newer means any
    /// previously known update has since been installed or withdrawn.
    public mutating func recordUpdateCheck(at date: Date, availableUpdate: AvailableUpdate?) {
        self.lastUpdateCheck = date
        self.availableUpdate = availableUpdate
    }

    /// Records a check that could not complete (e.g. no network). Only the
    /// timestamp moves, so the schedule doesn't retry every tick; a
    /// previously known update is left in place rather than guessed away.
    public mutating func recordFailedUpdateCheck(at date: Date) {
        lastUpdateCheck = date
    }
}

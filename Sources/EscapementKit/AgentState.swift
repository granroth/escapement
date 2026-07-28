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

    public mutating func setWaiting(_ waiting: Waiting?) {
        self.waiting = waiting
    }
}

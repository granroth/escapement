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

    public init(pausedUntil: Date? = nil) {
        self.pausedUntil = pausedUntil
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
}

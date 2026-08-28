import Foundation

/// What the agent can see about its menu bar item's placement on screen.
public enum MenuBarItemPlacement: Sendable, Equatable {
    /// No item exists — the user's preference asks for no icon.
    case absent
    /// The item exists but macOS has not positioned it yet. Reported for about
    /// a tick after creation, and says nothing either way.
    case settling
    /// The item's window belongs to a screen: macOS is showing it.
    case placed
    /// The item's window belongs to no screen: macOS is suppressing it.
    case unplaced
}

/// Decides whether macOS is suppressing the menu bar item, from the agent's
/// per-tick observation of where the item's window ended up.
///
/// The observation exists because `NSStatusItem.isVisible` cannot answer this.
/// When the user denies Escapement in System Settings → Menu Bar the item is
/// suppressed above the application: `isVisible` reads and writes `true`, the
/// button and its window still exist, and setting `isVisible` again changes
/// nothing. The one thing that does move is the window's screen membership —
/// a permitted item's window belongs to a screen, a suppressed one's does not.
/// Measured on macOS 27; see `docs/specs/019-menu-bar-visibility-sync.md`.
///
/// The verdict starts *unknown* rather than "not suppressed", and stays unknown
/// until the readings support an answer. That distinction matters across an
/// agent restart: a fresh item reports `settling` first, and treating that as
/// evidence of nothing being wrong would publish a confident "not suppressed"
/// over a correct "suppressed" left by the previous run, un-explaining a hidden
/// icon for a tick or two before correcting itself.
public struct MenuBarSuppression: Sendable, Equatable {

    /// Consecutive unplaced readings required before believing the item is
    /// suppressed. One would very likely do; two is cheap and this area has
    /// produced more than one confident wrong answer.
    public static let threshold = 2

    private var consecutiveUnplaced = 0

    /// Whether macOS is suppressing the item: `true` yes, `false` no, `nil` not
    /// yet established. Callers must not treat `nil` as `false` — publishing on
    /// an unknown verdict is the bug this type exists to avoid.
    public private(set) var verdict: Bool?

    public init() {}

    public mutating func observe(_ placement: MenuBarItemPlacement) {
        switch placement {
        case .absent:
            // The user asked for no icon. Its absence is their doing and must
            // never be reported to them as macOS interfering.
            consecutiveUnplaced = 0
            verdict = false
        case .settling:
            // No evidence either way. Deliberately leaves the verdict alone,
            // including leaving it unknown.
            break
        case .placed:
            consecutiveUnplaced = 0
            verdict = false
        case .unplaced:
            consecutiveUnplaced += 1
            if consecutiveUnplaced >= Self.threshold { verdict = true }
        }
    }
}

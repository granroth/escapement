import Foundation

/// The pause durations offered in the menu bar extra.
///
/// The arithmetic lives here rather than in the menu so it can be tested
/// against a fixed clock — "until tomorrow" in particular is easy to get subtly
/// wrong around midnight.
public enum PauseOption: Hashable, Sendable, CaseIterable {
    case oneHour
    case fourHours
    case untilTomorrow
    case indefinitely

    /// The hour "until tomorrow" resumes at: early enough to be back before a
    /// working day, late enough not to fire overnight.
    public static let morningHour = 8

    public var title: String {
        switch self {
        case .oneHour: return "For 1 Hour"
        case .fourHours: return "For 4 Hours"
        case .untilTomorrow: return "Until Tomorrow Morning"
        case .indefinitely: return "Until I Resume"
        }
    }

    /// When the pause ends. `nil` means open-ended, and **only**
    /// `.indefinitely` ever returns it.
    ///
    /// That exclusivity matters: callers treat `nil` as "pause until the user
    /// resumes", so a timed option that failed to compute a date would silently
    /// become a permanent pause and backups would never start again. If the
    /// calendar cannot land on the morning hour — an unrepresentable local time
    /// around a DST transition — this falls back to a plain 24 hours rather
    /// than surrendering the expiry.
    ///
    /// "Until tomorrow morning" is the next 8am strictly after now, so choosing
    /// it at 2am resumes six hours later rather than thirty.
    public func expiry(from now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .fourHours:
            return now.addingTimeInterval(4 * 3600)
        case .untilTomorrow:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: Self.morningHour, minute: 0, second: 0),
                matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(24 * 3600)
        case .indefinitely:
            return nil
        }
    }
}

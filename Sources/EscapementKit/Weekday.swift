import Foundation

/// A day of the week, numbered to match `Calendar`'s 1-based, Sunday-first
/// `weekday` component so no translation layer is needed when talking to
/// Foundation.
///
/// Note that the *display* order of weekdays is a locale question — many
/// locales start the week on Monday — and belongs to the UI, not here.
public enum Weekday: Int, Codable, Hashable, Sendable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
}

import Foundation

/// How often a destination should be backed up.
///
/// Construction goes through the failable factories rather than the memberwise
/// initialiser so that the engine below may assume a well-formed value: times
/// non-empty, sorted and unique; selections within range.
public struct Recurrence: Codable, Hashable, Sendable {

    public enum Kind: Codable, Hashable, Sendable {
        /// Every `everyHours` hours at `minute` past, anchored to midnight.
        case hourly(everyHours: Int, minute: Int)
        case daily
        case weekly(weekdays: Set<Weekday>)
        /// Days of the month, 1...31. A day that a month does not have is
        /// skipped rather than clamped.
        case monthly(days: Set<Int>)
    }

    public let kind: Kind

    /// The daily firing points, sorted and unique. Empty for `.hourly`, whose
    /// firing points are derived from the interval instead.
    public let times: [TimeOfDay]

    private init(kind: Kind, times: [TimeOfDay]) {
        self.kind = kind
        self.times = times
    }

    // MARK: - Construction

    public static func hourly(everyHours: Int, minute: Int) -> Recurrence? {
        guard (1...12).contains(everyHours), (0...59).contains(minute) else { return nil }
        return Recurrence(kind: .hourly(everyHours: everyHours, minute: minute), times: [])
    }

    public static func daily(times: [TimeOfDay]) -> Recurrence? {
        guard let times = normalised(times) else { return nil }
        return Recurrence(kind: .daily, times: times)
    }

    public static func weekly(weekdays: Set<Weekday>, times: [TimeOfDay]) -> Recurrence? {
        guard !weekdays.isEmpty, let times = normalised(times) else { return nil }
        return Recurrence(kind: .weekly(weekdays: weekdays), times: times)
    }

    public static func monthly(days: Set<Int>, times: [TimeOfDay]) -> Recurrence? {
        guard !days.isEmpty, days.allSatisfy({ (1...31).contains($0) }),
            let times = normalised(times)
        else { return nil }
        return Recurrence(kind: .monthly(days: days), times: times)
    }

    private static func normalised(_ times: [TimeOfDay]) -> [TimeOfDay]? {
        guard !times.isEmpty else { return nil }
        return Set(times).sorted()
    }

    /// Rebuilds a value through the factories, so that any route into the type
    /// is subject to the same validation.
    private static func make(kind: Kind, times: [TimeOfDay]) -> Recurrence? {
        switch kind {
        case .hourly(let everyHours, let minute):
            // An hourly recurrence derives its firing points from the interval,
            // so carrying times as well means the two disagree about when to
            // fire. Reject rather than silently pick one.
            guard times.isEmpty else { return nil }
            return hourly(everyHours: everyHours, minute: minute)
        case .daily:
            return daily(times: times)
        case .weekly(let weekdays):
            return weekly(weekdays: weekdays, times: times)
        case .monthly(let days):
            return monthly(days: days, times: times)
        }
    }

    /// Decoding is written by hand for the same reason as `TimeOfDay`'s: the
    /// synthesised conformance would bypass the factories entirely.
    ///
    /// This matters more here than it looks. Schedules are read from a JSON
    /// file that the agent loads at launch, so a truncated write or a
    /// hand-edit is a realistic input — and an unvalidated one previously
    /// crashed the agent on every launch thereafter, since the bad file
    /// persists.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let times = try container.decode([TimeOfDay].self, forKey: .times)
        guard let value = Recurrence.make(kind: kind, times: times) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(kind) with \(times.count) time(s) is not a valid schedule"))
        }
        self = value
    }
}

// MARK: - The next-fire engine

extension Recurrence {

    /// How far ahead the engine will look before giving up. Generous enough for
    /// a February-29th monthly schedule (which can be four years out) to still
    /// resolve within a couple of calls, and bounded so an unsatisfiable
    /// recurrence terminates instead of spinning.
    private static let searchLimitDays = 400 * 4

    /// The next instant this recurrence fires, strictly after `reference`.
    ///
    /// Returns `nil` only if nothing falls within the search window, which in
    /// practice means the recurrence cannot be satisfied at all.
    public func nextFireDate(after reference: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: reference)

        for _ in 0...Self.searchLimitDays {
            for candidate in firingPoints(on: day, calendar: calendar) where candidate > reference {
                return candidate
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }
        return nil
    }

    /// Every instant this recurrence fires on the given day, in ascending
    /// order. Empty if the day does not match the recurrence at all.
    ///
    /// Because the caller walks real days, a monthly schedule on the 31st
    /// simply never sees a 31st in February — the skip-don't-clamp rule falls
    /// out of the iteration rather than needing to be special-cased.
    private func firingPoints(on day: Date, calendar: Calendar) -> [Date] {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)

        switch kind {
        case .hourly(let everyHours, let minute):
            // Validation already guarantees 1...12, but `stride(by:)` *traps*
            // on a zero step rather than returning an empty sequence. A
            // scheduling agent must not have a crash one invariant slip away,
            // so the guard stays as a second line of defence.
            guard everyHours > 0 else { return [] }
            return stride(from: 0, to: 24, by: everyHours).compactMap {
                instant(on: components, hour: $0, minute: minute, calendar: calendar)
            }
            .sorted()

        case .daily:
            break

        case .weekly(let weekdays):
            guard let weekday = components.weekday.flatMap(Weekday.init(rawValue:)),
                weekdays.contains(weekday)
            else { return [] }

        case .monthly(let days):
            guard let dayOfMonth = components.day, days.contains(dayOfMonth) else { return [] }
        }

        return times.compactMap {
            instant(on: components, hour: $0.hour, minute: $0.minute, calendar: calendar)
        }
        .sorted()
    }

    /// Resolves a wall-clock time on a given day to an instant.
    ///
    /// All arithmetic goes through `Calendar`, so daylight-saving transitions
    /// are handled by Foundation: a time inside a spring-forward gap resolves
    /// to the shifted instant, and a time that occurs twice on a fall-back day
    /// resolves to the first of the two. The caller's strictly-greater-than
    /// test then ensures the repeated hour does not fire twice.
    private func instant(
        on day: DateComponents, hour: Int, minute: Int, calendar: Calendar
    ) -> Date? {
        calendar.date(
            from: DateComponents(
                year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))
    }
}

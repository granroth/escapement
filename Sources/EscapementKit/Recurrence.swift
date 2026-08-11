import Foundation

/// A window of the day, inclusive of both ends, used to restrict which hourly
/// firing points run. `start <= end` is a same-day window; `start > end`
/// crosses midnight (e.g. 11:00 PM to 4:00 AM). Every pair of `TimeOfDay`
/// values is well-formed, so construction cannot fail.
public struct TimeWindow: Hashable, Sendable, Codable {
    public let start: TimeOfDay
    public let end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// Whether this window crosses midnight. Strictly `>`, never `>=`: equal
    /// endpoints stay a same-day window selecting a single instant, matching
    /// spec 006's deliberate choice to admit `start == end` rather than treat
    /// it as "all day".
    public var isOvernight: Bool { start > end }

    public func contains(_ time: TimeOfDay) -> Bool {
        isOvernight ? (time >= start || time <= end) : (start <= time && time <= end)
    }
}

/// How often a destination should be backed up.
///
/// Construction goes through the failable factories rather than the memberwise
/// initialiser so that the engine below may assume a well-formed value: times
/// non-empty, sorted and unique; selections within range.
public struct Recurrence: Codable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// Every `everyHours` hours at `minute` past, optionally restricted to
        /// a window of the day (`nil` means all day). Anchored to midnight
        /// with no window; anchored to the window's start hour when there is
        /// one, so the window's own start is on the grid. See spec 017.
        case hourly(everyHours: Int, minute: Int, window: TimeWindow?)
        /// Every `everyDays` days (1 = every day), counted from the schedule's
        /// anchor. See `nextFireDate(after:calendar:anchor:)`.
        case daily(everyDays: Int)
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

    public static func hourly(everyHours: Int, minute: Int, window: TimeWindow? = nil) -> Recurrence?
    {
        guard (1...12).contains(everyHours), (0...59).contains(minute) else { return nil }
        return Recurrence(
            kind: .hourly(everyHours: everyHours, minute: minute, window: window), times: [])
    }

    public static func daily(everyDays: Int = 1, times: [TimeOfDay]) -> Recurrence? {
        guard (1...366).contains(everyDays), let times = normalised(times) else { return nil }
        return Recurrence(kind: .daily(everyDays: everyDays), times: times)
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
        case .hourly(let everyHours, let minute, let window):
            // An hourly recurrence derives its firing points from the interval,
            // so carrying times as well means the two disagree about when to
            // fire. Reject rather than silently pick one.
            guard times.isEmpty else { return nil }
            return hourly(everyHours: everyHours, minute: minute, window: window)
        case .daily(let everyDays):
            return daily(everyDays: everyDays, times: times)
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

// MARK: - Kind coding (backward-compatible)

extension Recurrence.Kind: Codable {
    private enum CaseKey: String, CodingKey { case hourly, daily, weekly, monthly }
    private enum HourlyKey: String, CodingKey { case everyHours, minute, window }
    private enum DailyKey: String, CodingKey { case everyDays }
    private enum WeeklyKey: String, CodingKey { case weekdays }
    private enum MonthlyKey: String, CodingKey { case days }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        // Written by hand so first-cut files decode: a missing `everyDays`
        // means every day, and a missing `window` means all day.
        if container.contains(.hourly) {
            let hourly = try container.nestedContainer(keyedBy: HourlyKey.self, forKey: .hourly)
            self = .hourly(
                everyHours: try hourly.decode(Int.self, forKey: .everyHours),
                minute: try hourly.decode(Int.self, forKey: .minute),
                window: try hourly.decodeIfPresent(TimeWindow.self, forKey: .window))
        } else if container.contains(.daily) {
            let daily = try container.nestedContainer(keyedBy: DailyKey.self, forKey: .daily)
            self = .daily(everyDays: try daily.decodeIfPresent(Int.self, forKey: .everyDays) ?? 1)
        } else if container.contains(.weekly) {
            let weekly = try container.nestedContainer(keyedBy: WeeklyKey.self, forKey: .weekly)
            self = .weekly(weekdays: try weekly.decode(Set<Weekday>.self, forKey: .weekdays))
        } else if container.contains(.monthly) {
            let monthly = try container.nestedContainer(keyedBy: MonthlyKey.self, forKey: .monthly)
            self = .monthly(days: try monthly.decode(Set<Int>.self, forKey: .days))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown recurrence kind"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .hourly(let everyHours, let minute, let window):
            var hourly = container.nestedContainer(keyedBy: HourlyKey.self, forKey: .hourly)
            try hourly.encode(everyHours, forKey: .everyHours)
            try hourly.encode(minute, forKey: .minute)
            try hourly.encodeIfPresent(window, forKey: .window)
        case .daily(let everyDays):
            var daily = container.nestedContainer(keyedBy: DailyKey.self, forKey: .daily)
            try daily.encode(everyDays, forKey: .everyDays)
        case .weekly(let weekdays):
            var weekly = container.nestedContainer(keyedBy: WeeklyKey.self, forKey: .weekly)
            try weekly.encode(weekdays, forKey: .weekdays)
        case .monthly(let days):
            var monthly = container.nestedContainer(keyedBy: MonthlyKey.self, forKey: .monthly)
            try monthly.encode(days, forKey: .days)
        }
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
    /// - Parameter anchor: the parity origin for `daily(everyDays:)`. Callers
    ///   that own a schedule pass its `effectiveFrom`; the interval is counted
    ///   in whole days from that day. Ignored by every other kind, so the
    ///   default (a fixed reference date) is harmless for them and for
    ///   `everyDays == 1`.
    ///
    /// Returns `nil` only if nothing falls within the search window, which in
    /// practice means the recurrence cannot be satisfied at all.
    public func nextFireDate(
        after reference: Date, calendar: Calendar,
        anchor: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> Date? {
        var day = calendar.startOfDay(for: reference)

        for _ in 0...Self.searchLimitDays {
            for candidate in firingPoints(on: day, calendar: calendar, anchor: anchor)
            where candidate > reference {
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
    private func firingPoints(on day: Date, calendar: Calendar, anchor: Date) -> [Date] {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)

        switch kind {
        case .hourly(let everyHours, let minute, let window):
            // Validation already guarantees 1...12, but `stride(by:)` *traps*
            // on a zero step rather than returning an empty sequence. A
            // scheduling agent must not have a crash one invariant slip away,
            // so the guard stays as a second line of defence.
            guard everyHours > 0 else { return [] }
            // A window's own start reads, to a user, as when the schedule
            // begins — not as an offset into a midnight-anchored grid they
            // never typed. So the grid's phase comes from the window's start
            // hour when there is one; with no window this is `0 % everyHours
            // == 0`, the same midnight anchor as always. See spec 017. Only
            // the hour is used: the window's minute, like the recurrence's
            // own `minute` below, keeps its independent meaning rather than
            // being folded into the anchor.
            let phase = (window?.start.hour ?? 0) % everyHours
            return stride(from: phase, to: 24, by: everyHours).compactMap { hour -> Date? in
                let time = TimeOfDay(hour: hour, minute: minute)!
                guard window?.contains(time) ?? true else { return nil }
                return instant(on: components, hour: hour, minute: minute, calendar: calendar)
            }
            .sorted()

        case .daily(let everyDays):
            // Every `everyDays` days counted in whole days from the anchor. The
            // parity is consistent in both directions, so a schedule whose
            // reference precedes its anchor still lands on the right days.
            if everyDays > 1 {
                let anchorDay = calendar.startOfDay(for: anchor)
                guard let offset = calendar.dateComponents([.day], from: anchorDay, to: day).day,
                    offset % everyDays == 0
                else { return [] }
            }

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

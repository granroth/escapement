import Foundation

/// A wall-clock time within a day, independent of any particular date.
///
/// Deliberately not a `Date`: a schedule of "03:00" means three in the
/// morning on whatever day it lands, including days that are 23 or 25 hours
/// long. Resolving it to an instant is the calendar's job, not this type's.
public struct TimeOfDay: Codable, Hashable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// Decoding is written by hand because the synthesised conformance assigns
    /// stored properties directly, which would let a corrupted file produce an
    /// hour of 99 — a value `init(hour:minute:)` cannot create.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        guard let value = TimeOfDay(hour: hour, minute: minute) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(hour):\(minute) is not a valid time of day"))
        }
        self = value
    }
}

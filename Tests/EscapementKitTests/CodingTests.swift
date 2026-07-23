import Foundation
import Testing

@testable import EscapementKit

/// Decoding is the one path by which a value can enter the program without
/// passing through a failable initialiser. Because the agent reads its
/// schedules from a JSON file on disk, a corrupted or hand-edited file is a
/// realistic input, and every invariant the engine relies on has to survive it.
@Suite("Coding")
struct CodingTests {

    private func decodeRecurrence(_ json: String) throws -> Recurrence {
        try JSONDecoder().decode(Recurrence.self, from: Data(json.utf8))
    }

    private func decodeTimeOfDay(_ json: String) throws -> TimeOfDay {
        try JSONDecoder().decode(TimeOfDay.self, from: Data(json.utf8))
    }

    // MARK: - Round trips

    @Test(
        "every recurrence kind survives a round trip",
        arguments: [
            Recurrence.hourly(everyHours: 4, minute: 30)!,
            Recurrence.hourly(everyHours: 1, minute: 0)!,
            Recurrence.daily(times: [TimeOfDay(hour: 2, minute: 15)!])!,
            Recurrence.daily(times: [
                TimeOfDay(hour: 2, minute: 15)!, TimeOfDay(hour: 14, minute: 0)!,
            ])!,
            Recurrence.weekly(
                weekdays: [.monday, .friday], times: [TimeOfDay(hour: 3, minute: 0)!])!,
            Recurrence.monthly(days: [1, 15, 31], times: [TimeOfDay(hour: 5, minute: 45)!])!,
        ])
    func roundTrip(recurrence: Recurrence) throws {
        let data = try JSONEncoder().encode(recurrence)
        let decoded = try JSONDecoder().decode(Recurrence.self, from: data)
        #expect(decoded == recurrence)
    }

    @Test("TimeOfDay survives a round trip")
    func timeOfDayRoundTrip() throws {
        let value = TimeOfDay(hour: 23, minute: 59)!
        let decoded = try JSONDecoder().decode(TimeOfDay.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    // MARK: - Rejecting corrupted input

    /// The specific value that previously crashed the process: an hourly
    /// interval of zero reached `stride(by:)`, which traps on a zero stride.
    @Test("an hourly interval of zero is rejected rather than trapping")
    func zeroHourlyIntervalRejected() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(#"{"kind":{"hourly":{"everyHours":0,"minute":0}},"times":[]}"#)
        }
    }

    @Test(
        "out-of-range hourly intervals are rejected",
        arguments: [-3, 0, 13, 999])
    func hourlyIntervalRejected(everyHours: Int) {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"hourly":{"everyHours":\#(everyHours),"minute":0}},"times":[]}"#)
        }
    }

    @Test("an out-of-range hourly minute is rejected", arguments: [-1, 60, 100])
    func hourlyMinuteRejected(minute: Int) {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"hourly":{"everyHours":4,"minute":\#(minute)}},"times":[]}"#)
        }
    }

    @Test("an empty time list is rejected for recurrences that require one")
    func emptyTimesRejected() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(#"{"kind":{"daily":{}},"times":[]}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(#"{"kind":{"weekly":{"weekdays":[2]}},"times":[]}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(#"{"kind":{"monthly":{"days":[1]}},"times":[]}"#)
        }
    }

    @Test("an empty weekday selection is rejected")
    func emptyWeekdaysRejected() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"weekly":{"weekdays":[]}},"times":[{"hour":3,"minute":0}]}"#)
        }
    }

    @Test("out-of-range days of the month are rejected", arguments: [0, 32, 99, -1])
    func monthlyDaysRejected(day: Int) {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"monthly":{"days":[\#(day)]}},"times":[{"hour":3,"minute":0}]}"#)
        }
    }

    @Test("an empty day-of-month selection is rejected")
    func emptyMonthlyDaysRejected() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"monthly":{"days":[]}},"times":[{"hour":3,"minute":0}]}"#)
        }
    }

    @Test("an hourly recurrence carrying times is rejected as inconsistent")
    func hourlyWithTimesRejected() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(
                #"{"kind":{"hourly":{"everyHours":4,"minute":0}},"times":[{"hour":3,"minute":0}]}"#)
        }
    }

    @Test("an out-of-range TimeOfDay is rejected")
    func timeOfDayRejected() {
        #expect(throws: DecodingError.self) { try decodeTimeOfDay(#"{"hour":99,"minute":0}"#) }
        #expect(throws: DecodingError.self) { try decodeTimeOfDay(#"{"hour":0,"minute":200}"#) }
        #expect(throws: DecodingError.self) { try decodeTimeOfDay(#"{"hour":-1,"minute":0}"#) }
        #expect(throws: DecodingError.self) { try decodeTimeOfDay(#"{"hour":24,"minute":0}"#) }
    }

    /// Raw-value enum synthesis already routes through `init?(rawValue:)`, so
    /// this holds today. It is pinned so a later hand-written conformance
    /// cannot quietly lose it.
    @Test("an out-of-range weekday is rejected")
    func weekdayRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Weekday.self, from: Data("9".utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Weekday.self, from: Data("0".utf8))
        }
    }

    // MARK: - Nested corruption

    @Test("a corrupted time inside an otherwise valid recurrence is rejected")
    func corruptedNestedTime() {
        #expect(throws: DecodingError.self) {
            try decodeRecurrence(#"{"kind":{"daily":{}},"times":[{"hour":25,"minute":0}]}"#)
        }
    }

    @Test("every value that survives decoding can be scheduled without trapping")
    func decodedValuesAreSafeToSchedule() throws {
        // A decoded recurrence must be indistinguishable from a constructed
        // one: usable immediately, with no separate validation step required
        // of the caller.
        let json = #"{"kind":{"hourly":{"everyHours":6,"minute":30}},"times":[]}"#
        let recurrence = try decodeRecurrence(json)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        let next = recurrence.nextFireDate(after: Date(timeIntervalSince1970: 0), calendar: cal)
        #expect(next != nil)
    }
}

import Foundation
import Testing

@testable import EscapementKit

/// `ReleaseVersion` parses the "vMAJOR.MINOR.PATCH" tags the release pipeline
/// produces (see `RELEASING.md`) — and, since the running app's own
/// `CFBundleShortVersionString` has no "v" prefix, the bare form too.
@Suite("ReleaseVersion parsing")
struct ReleaseVersionParsingTests {

    @Test("parses a tag with a v prefix")
    func parsesWithPrefix() {
        let version = ReleaseVersion(parsing: "v1.2.3")
        #expect(version?.major == 1)
        #expect(version?.minor == 2)
        #expect(version?.patch == 3)
    }

    @Test("parses a bare version with no prefix")
    func parsesWithoutPrefix() {
        let version = ReleaseVersion(parsing: "0.4.0")
        #expect(version?.major == 0)
        #expect(version?.minor == 4)
        #expect(version?.patch == 0)
    }

    @Test(
        "rejects malformed strings rather than trapping",
        arguments: ["", "v", "1.2", "1.2.3.4", "1.2.x", "v-1.2.3", "vv1.2.3", "1..3"])
    func rejectsMalformed(string: String) {
        #expect(ReleaseVersion(parsing: string) == nil)
    }

    @Test("orders by major, then minor, then patch")
    func ordering() {
        #expect(ReleaseVersion(parsing: "1.0.0")! < ReleaseVersion(parsing: "2.0.0")!)
        #expect(ReleaseVersion(parsing: "1.0.0")! < ReleaseVersion(parsing: "1.1.0")!)
        #expect(ReleaseVersion(parsing: "1.1.0")! < ReleaseVersion(parsing: "1.1.1")!)
        #expect(!(ReleaseVersion(parsing: "1.1.1")! < ReleaseVersion(parsing: "1.1.1")!))
        #expect(!(ReleaseVersion(parsing: "2.0.0")! < ReleaseVersion(parsing: "1.9.9")!))
    }
}

/// `UpdateChecker` is the pure orchestration layer: given an `UpdateSource` —
/// faked here, backed by a real `URLSession` in `EscapementAgent` — it decides
/// whether the latest release is actually newer than what is running.
@Suite("UpdateChecker")
struct UpdateCheckerTests {

    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(tagName: tag, releaseURL: URL(string: "https://example.com/\(tag)")!)
    }

    @Test("a newer release produces an available update")
    func newerReleaseAvailable() async throws {
        let checker = UpdateChecker(source: FakeUpdateSource(release: release("v1.1.0")))
        let result = try await checker.checkForUpdate(currentVersion: "1.0.0")
        #expect(result?.version == "1.1.0")
        #expect(result?.releaseURL == URL(string: "https://example.com/v1.1.0")!)
    }

    @Test("the same version is not reported as available")
    func sameVersionNotAvailable() async throws {
        let checker = UpdateChecker(source: FakeUpdateSource(release: release("v1.0.0")))
        let result = try await checker.checkForUpdate(currentVersion: "1.0.0")
        #expect(result == nil)
    }

    @Test("an older release is not reported as available")
    func olderReleaseNotAvailable() async throws {
        // Can happen if a user builds from a pre-release checkout.
        let checker = UpdateChecker(source: FakeUpdateSource(release: release("v0.9.0")))
        let result = try await checker.checkForUpdate(currentVersion: "1.0.0")
        #expect(result == nil)
    }

    @Test("an unparseable release tag is not reported as available")
    func unparseableTagIgnored() async throws {
        let checker = UpdateChecker(source: FakeUpdateSource(release: release("not-a-version")))
        let result = try await checker.checkForUpdate(currentVersion: "1.0.0")
        #expect(result == nil)
    }

    @Test("a source failure propagates rather than being swallowed")
    func sourceFailurePropagates() async {
        let checker = UpdateChecker(source: FakeUpdateSource(error: FakeError()))
        await #expect(throws: FakeError.self) {
            try await checker.checkForUpdate(currentVersion: "1.0.0")
        }
    }
}

/// The "is a check due" math is pure and calendar-independent (monthly is
/// approximated as 30 days — see spec 014), so it is tested with fixed dates
/// rather than a live clock.
@Suite("UpdateCheckScheduling")
struct UpdateCheckSchedulingTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("never and onStartup are never due from elapsed time")
    func neverAndOnStartupNotDue() {
        #expect(!UpdateCheckScheduling.isDue(interval: .never, lastCheckedAt: nil, now: now))
        #expect(!UpdateCheckScheduling.isDue(interval: .onStartup, lastCheckedAt: nil, now: now))
        #expect(
            !UpdateCheckScheduling.isDue(
                interval: .never, lastCheckedAt: now.addingTimeInterval(-999_999_999), now: now))
    }

    @Test(
        "a never-checked state is immediately due for every timed interval",
        arguments: [UpdateCheckInterval.daily, .weekly, .monthly])
    func neverCheckedIsDue(interval: UpdateCheckInterval) {
        #expect(UpdateCheckScheduling.isDue(interval: interval, lastCheckedAt: nil, now: now))
    }

    @Test("daily is not due before 24 hours and due at or after")
    func dailyWindow() {
        let almostADayAgo = now.addingTimeInterval(-86_400 + 1)
        let exactlyADayAgo = now.addingTimeInterval(-86_400)
        #expect(!UpdateCheckScheduling.isDue(interval: .daily, lastCheckedAt: almostADayAgo, now: now))
        #expect(UpdateCheckScheduling.isDue(interval: .daily, lastCheckedAt: exactlyADayAgo, now: now))
    }

    @Test("weekly is not due before 7 days and due at or after")
    func weeklyWindow() {
        let almost = now.addingTimeInterval(-7 * 86_400 + 1)
        let exactly = now.addingTimeInterval(-7 * 86_400)
        #expect(!UpdateCheckScheduling.isDue(interval: .weekly, lastCheckedAt: almost, now: now))
        #expect(UpdateCheckScheduling.isDue(interval: .weekly, lastCheckedAt: exactly, now: now))
    }

    @Test("monthly is not due before 30 days and due at or after")
    func monthlyWindow() {
        let almost = now.addingTimeInterval(-30 * 86_400 + 1)
        let exactly = now.addingTimeInterval(-30 * 86_400)
        #expect(!UpdateCheckScheduling.isDue(interval: .monthly, lastCheckedAt: almost, now: now))
        #expect(UpdateCheckScheduling.isDue(interval: .monthly, lastCheckedAt: exactly, now: now))
    }
}

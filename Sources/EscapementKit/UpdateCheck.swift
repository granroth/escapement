import Foundation

/// A parsed `MAJOR.MINOR.PATCH` version, accepting an optional leading "v" so
/// it reads both a GitHub release tag (`v1.2.0`) and the bare
/// `CFBundleShortVersionString` the running app carries.
public struct ReleaseVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(parsing string: String) {
        var remainder = Substring(string)
        if remainder.hasPrefix("v") { remainder.removeFirst() }
        let parts = remainder.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A release newer than the one running, named the way spec 014's Settings
/// status line and update notification both display it. Persisted on
/// `AgentState.availableUpdate`.
public struct AvailableUpdate: Codable, Hashable, Sendable {
    public let version: String
    public let releaseURL: URL

    public init(version: String, releaseURL: URL) {
        self.version = version
        self.releaseURL = releaseURL
    }
}

/// The one fact `UpdateSource` reports: the latest published release's tag
/// and the page to send the user to. Nothing else about it is ever read.
public struct ReleaseInfo: Sendable, Equatable {
    public let tagName: String
    public let releaseURL: URL

    public init(tagName: String, releaseURL: URL) {
        self.tagName = tagName
        self.releaseURL = releaseURL
    }
}

/// Fronts the one network call Escapement ever makes. Faked in
/// `EscapementKitTests`; the real implementation — an actual `URLSession`
/// request — lives in `EscapementAgent`, the only place in the app that
/// touches the network, and is verified by tracing and by driving the real
/// agent rather than by unit test (see spec 014).
public protocol UpdateSource: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Compares the latest published release against the running version. Pure
/// orchestration: no I/O of its own, so it is fully covered by
/// `EscapementKitTests` against a fake `UpdateSource`.
public struct UpdateChecker: Sendable {
    private let source: any UpdateSource

    public init(source: any UpdateSource) {
        self.source = source
    }

    /// The newer release, or `nil` when the running version is already
    /// current or either version string can't be parsed. Propagates a
    /// failure from the source (e.g. no network) rather than swallowing it —
    /// the caller decides how to record that.
    public func checkForUpdate(currentVersion: String) async throws -> AvailableUpdate? {
        let release = try await source.latestRelease()
        guard let latest = ReleaseVersion(parsing: release.tagName),
            let current = ReleaseVersion(parsing: currentVersion),
            current < latest
        else { return nil }
        return AvailableUpdate(
            version: "\(latest.major).\(latest.minor).\(latest.patch)",
            releaseURL: release.releaseURL)
    }
}

/// How often `Configuration.updateCheckInterval` asks the agent to check.
/// `.onStartup` is handled by the agent unconditionally once per process
/// launch rather than through `isDue` — the GUI opening is not guaranteed,
/// which is the entire reason this feature lives in the agent.
public enum UpdateCheckInterval: String, Codable, CaseIterable, Sendable {
    case never
    case onStartup
    case daily
    case weekly
    case monthly
}

/// The "is a check due" math, kept pure and calendar-independent so it is
/// unit-testable with fixed dates. Monthly is approximated as 30 days —
/// precision doesn't matter for a background check this infrequent.
public enum UpdateCheckScheduling {
    public static func isDue(
        interval: UpdateCheckInterval, lastCheckedAt: Date?, now: Date = Date()
    ) -> Bool {
        switch interval {
        case .never, .onStartup: return false
        case .daily: return isOverdue(lastCheckedAt, now, 86_400)
        case .weekly: return isOverdue(lastCheckedAt, now, 7 * 86_400)
        case .monthly: return isOverdue(lastCheckedAt, now, 30 * 86_400)
        }
    }

    private static func isOverdue(_ last: Date?, _ now: Date, _ seconds: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= seconds
    }
}

import Foundation

@testable import EscapementKit

/// A hand-driven `TimeMachineControlling` for exercising the run loop without a
/// real backup: set what `activity()` should report, and inspect what the
/// runner asked it to do.
actor FakeTimeMachine: TimeMachineControlling {
    var currentActivity: BackupActivity = .idle
    var currentDestinations: [Destination] = []
    var currentAutomaticState: AutomaticBackupState = .manual

    private(set) var startCalls: [String] = []
    private(set) var stopCalls = 0

    /// When set, `startBackup` throws this instead of recording a call —
    /// models a failure to launch the tool.
    var startFailure: (any Error)?
    /// When set, `startBackup` also flips `currentActivity` to running for the
    /// requested destination, imitating backupd spinning up promptly.
    var autoBecomeRunning = false

    func setActivity(_ activity: BackupActivity) { currentActivity = activity }
    func setDestinations(_ destinations: [Destination]) { currentDestinations = destinations }
    func setAutomaticState(_ state: AutomaticBackupState) { currentAutomaticState = state }
    func setStartFailure(_ error: (any Error)?) { startFailure = error }
    func setAutoBecomeRunning(_ value: Bool) { autoBecomeRunning = value }

    func destinations() async throws -> [Destination] { currentDestinations }
    func activity() async throws -> BackupActivity { currentActivity }
    func automaticBackupState() async -> AutomaticBackupState { currentAutomaticState }

    func startBackup(destinationID: String) async throws {
        if let startFailure { throw startFailure }
        startCalls.append(destinationID)
        if autoBecomeRunning {
            currentActivity = .running(
                destinationID: destinationID, phase: .copying, progress: 0.1)
        }
    }

    func stopBackup() async throws {
        stopCalls += 1
        currentActivity = .stopping(destinationID: nil)
    }
}

struct FakeError: Error {}

/// A clock the tests advance by hand, so time-dependent behaviour is
/// deterministic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current.addTimeInterval(interval)
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}

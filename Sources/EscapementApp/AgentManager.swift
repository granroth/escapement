import AppKit
import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for the bundled background LaunchAgent.
/// Registering it makes launchd run the agent at login; the app reflects the
/// service's status and never fires backups itself.
@MainActor
struct AgentManager {
    /// Must match the LaunchAgent plist bundled at
    /// `Contents/Library/LaunchAgents/`.
    static let plistName = "com.granroth.Escapement.Agent.plist"

    private let service = SMAppService.agent(plistName: plistName)

    var status: SMAppService.Status { service.status }

    /// Registers the agent (enables background backups). May leave the service
    /// in `.requiresApproval` if the user must approve it in Login Items.
    func enable() throws {
        try service.register()
    }

    func disable() async throws {
        try await service.unregister()
    }

    /// Whether the agent process is actually alive, as opposed to merely
    /// registered. The two differ exactly when a registration has gone stale.
    ///
    /// Matched on executable name rather than bundle identifier: the agent is a
    /// nested helper app, and matching the name keeps this working regardless
    /// of how the two bundles' identifiers are arranged.
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.executableURL?.lastPathComponent == "EscapementAgent"
        }
    }

    /// Rebuilds a stale registration.
    ///
    /// Two behaviours here were established on real hardware, and both are easy
    /// to get wrong:
    ///
    /// 1. `register()` alone is not enough, and is actively harmful on a healthy
    ///    service: it re-submits the job, terminating the running agent, without
    ///    re-triggering `RunAtLoad` — so the agent stays stopped.
    /// 2. Unregistering does not take effect immediately. Registering again in
    ///    the same breath is a no-op against a record that still reads
    ///    `.enabled`, which leaves the service wedged: `SMAppService` reports it
    ///    enabled while launchd has no such job at all. So wait for the
    ///    deregistration to actually land before re-submitting.
    func reregister() async throws {
        try? await service.unregister()
        for _ in 0..<20 where service.status == .enabled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try service.register()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

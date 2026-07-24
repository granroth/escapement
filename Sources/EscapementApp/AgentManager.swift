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

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

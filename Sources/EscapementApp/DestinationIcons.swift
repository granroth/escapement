import AppKit
import EscapementKit

/// Distinct SF Symbols for the two kinds of destination, so a local disk and a
/// network share read differently at a glance.
enum DestinationIcons {
    static func image(for kind: Destination.Kind) -> NSImage? {
        let name: String
        let description: String
        switch kind {
        case .local:
            name = "externaldrive.fill"
            description = "Local disk"
        case .network:
            name = "externaldrive.connected.to.line.below.fill"
            description = "Network share"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        return image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
    }
}

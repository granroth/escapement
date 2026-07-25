import AppKit

@MainActor
enum AppIcon {

    /// Installs the free-form escape wheel as the running app's icon.
    ///
    /// Escapement ships two icons. The bundle icon (`Escapement.icns`) is
    /// drawn full-bleed on a near-black ground because macOS clips every app
    /// icon to its own rounded-rect: art with a transparent background is
    /// rescaled into a fixed inner box and dropped on a generated grey plate,
    /// and there is no way to opt out. Drawing our own ground means the clip
    /// lands inside it and the wheel survives at full size.
    ///
    /// An icon set at runtime is exempt from that clip, so the Dock tile and
    /// the ⌘-Tab switcher can show the wheel's real silhouette. Call this
    /// before `NSApplication.run()` so the tile is correct from the first
    /// frame rather than flipping shape after launch.
    ///
    /// Falls back to the bundle icon if the resource is missing, which only
    /// happens in a malformed bundle; `scripts/build-app.sh` checks for it.
    static func installFreeformDockIcon() {
        guard let freeform else { return }

        NSApplication.shared.applicationIconImage = freeform
    }

    /// The free-form mark, loaded once. `nil` only in a malformed bundle.
    ///
    /// Surfaces that draw the icon themselves rather than asking the system
    /// for it — the About panel, say — should use this, since anything that
    /// resolves the *bundle* icon gets the full-bleed one instead.
    static let freeform: NSImage? = {
        guard let url = Bundle.main.url(forResource: "EscapementFreeform", withExtension: "icns")
        else { return nil }

        return NSImage(contentsOf: url)
    }()
}

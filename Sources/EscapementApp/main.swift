import AppKit

// SwiftPM executable entry point. The app is assembled into a signed .app
// bundle by scripts/build-app.sh; there is no storyboard or xib — the whole
// interface is built in code.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

import AppKit

@MainActor
private func launchTrellisHUD() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

launchTrellisHUD()

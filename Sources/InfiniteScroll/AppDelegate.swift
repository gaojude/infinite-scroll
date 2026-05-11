import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Resolve tmux on a background queue so that the first terminal mount
        // doesn't block the main thread inside SwiftUI's layout pass.
        TmuxManager.prewarm()
        // Defer the first-run install prompt so the main window is up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            CLIInstaller.showFirstRunPromptIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

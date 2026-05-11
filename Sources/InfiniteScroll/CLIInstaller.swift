import AppKit
import Foundation

/// Handles installing/uninstalling the `infinite-scroll` shell command symlink.
enum CLIInstaller {
    static let installTarget = "/usr/local/bin/infinite-scroll"
    private static let firstRunKey = "infinite-scroll.cli.install.prompted"

    /// Returns the absolute path to the bundled CLI binary, or nil if not found.
    static func bundledCLIPath() -> String? {
        let fm = FileManager.default

        // 1) Production: inside the .app bundle, alongside the main executable
        if let exe = Bundle.main.executableURL {
            let candidate = exe.deletingLastPathComponent()
                .appendingPathComponent("infinite-scroll").path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
            // Or in Resources
            let resCandidate = exe.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/infinite-scroll").path
            if fm.isExecutableFile(atPath: resCandidate) {
                return resCandidate
            }
        }

        // 2) Dev: swift build output sits next to the main binary
        if let exe = Bundle.main.executableURL {
            let dev = exe.deletingLastPathComponent()
                .appendingPathComponent("infinite-scroll").path
            if fm.isExecutableFile(atPath: dev) { return dev }
        }

        return nil
    }

    /// True if /usr/local/bin/infinite-scroll exists and points at our bundled binary.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard let source = bundledCLIPath() else { return false }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: installTarget) {
            return dest == source
        }
        return false
    }

    /// True if anything (symlink or file) currently lives at the install target.
    static func somethingAtInstallTarget() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: installTarget) { return true }
        if (try? fm.destinationOfSymbolicLink(atPath: installTarget)) != nil { return true }
        return false
    }

    /// Try to install. Returns true on success. Prompts for admin password if needed.
    @discardableResult
    static func install() -> Bool {
        guard let source = bundledCLIPath() else {
            NSLog("[CLIInstaller] bundled CLI binary not found")
            return false
        }
        let dir = (installTarget as NSString).deletingLastPathComponent

        // Direct attempt first (works if user has write access to /usr/local/bin)
        if directInstall(source: source, target: installTarget) {
            return true
        }

        // Admin install
        let cmd = "mkdir -p '\(shellEscape(dir))' && ln -sfn '\(shellEscape(source))' '\(shellEscape(installTarget))'"
        let script = "do shell script \"\(escapedForAppleScript(cmd))\" with administrator privileges"
        return runAppleScript(script)
    }

    @discardableResult
    static func uninstall() -> Bool {
        let fm = FileManager.default
        guard somethingAtInstallTarget() else { return true }
        if (try? fm.removeItem(atPath: installTarget)) != nil { return true }
        let cmd = "rm -f '\(shellEscape(installTarget))'"
        let script = "do shell script \"\(escapedForAppleScript(cmd))\" with administrator privileges"
        return runAppleScript(script)
    }

    /// Show the first-run install prompt if it hasn't been shown yet.
    static func showFirstRunPromptIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: firstRunKey) { return }
        guard bundledCLIPath() != nil else { return }
        if isInstalled() {
            defaults.set(true, forKey: firstRunKey)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install 'infinite-scroll' command?"
        alert.informativeText = """
            Install a shell command at /usr/local/bin/infinite-scroll so AI agents \
            (or you) can read and manipulate cells from the terminal.

            You can install or uninstall this later from Settings.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        let response = alert.runModal()
        defaults.set(true, forKey: firstRunKey)
        if response == .alertFirstButtonReturn {
            if !install() {
                let failAlert = NSAlert()
                failAlert.messageText = "Install failed"
                failAlert.informativeText = "Could not install the shell command. You can try again from Settings."
                failAlert.runModal()
            }
        }
    }

    // MARK: - Helpers

    private static func directInstall(source: String, target: String) -> Bool {
        let fm = FileManager.default
        let dir = (target as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else {
                return false
            }
        }
        if somethingAtInstallTarget() {
            guard (try? fm.removeItem(atPath: target)) != nil else { return false }
        }
        return (try? fm.createSymbolicLink(atPath: target, withDestinationPath: source)) != nil
    }

    private static func runAppleScript(_ source: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func escapedForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

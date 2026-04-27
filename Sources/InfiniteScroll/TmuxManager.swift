import Foundation

enum TmuxManager {
    static let prefix = "is-"
    private static let cacheLock = NSLock()
    private static var _cachedPath: String?
    private static var _checked = false

    /// Resolve the tmux path on a background queue and cache it. Safe to call
    /// from anywhere (idempotent, locked). Call early in app launch so that
    /// `cachedTmuxPath()` returns a value by the time a terminal is mounted.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = findTmux()
        }
    }

    /// Non-blocking accessor — returns the cached path if resolved, else nil.
    /// Use this on the main thread (e.g. inside `makeNSView`) to avoid
    /// spinning a nested run loop during SwiftUI layout.
    static func cachedTmuxPath() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _checked ? _cachedPath : nil
    }

    /// Find a working tmux binary — verifies it actually runs.
    /// Blocks the calling thread; do not call from the main thread.
    @discardableResult
    static func findTmux() -> String? {
        cacheLock.lock()
        if _checked {
            let cached = _cachedPath
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        var searchPaths = candidates
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("tmux").path {
            searchPaths.append(bundlePath)
        }

        var resolved: String?
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) && verifyTmux(path) {
                resolved = path
                break
            }
        }

        cacheLock.lock()
        _cachedPath = resolved
        _checked = true
        cacheLock.unlock()
        return resolved
    }

    /// Actually run `tmux -V` to verify it works (dylibs load, etc.)
    private static func verifyTmux(_ path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-V"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func sessionName(for id: UUID) -> String {
        "\(prefix)\(id.uuidString)"
    }

    static func sessionExists(_ name: String) -> Bool {
        guard let tmux = findTmux() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["has-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func killSession(_ name: String) {
        guard let tmux = findTmux() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["kill-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    static func listSessions() -> [String] {
        guard let tmux = findTmux() else { return [] }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["list-sessions", "-F", "#{session_name}"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n")
            .filter { $0.hasPrefix(prefix) }
    }

    static func paneCwd(session: String) -> String? {
        guard let tmux = findTmux() else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["display-message", "-p", "-t", session, "-F", "#{pane_current_path}"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        return output
    }

    /// Run a tmux command (fire-and-forget)
    @discardableResult
    static func run(_ args: [String]) -> Bool {
        guard let tmux = findTmux() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private static var _configuredGlobals = false

    /// Configure global tmux settings (mouse, extended keys). Idempotent.
    static func configureGlobals() {
        guard !_configuredGlobals else { return }
        _configuredGlobals = true
        run(["set-option", "-g", "mouse", "on"])
        run(["set-option", "-g", "extended-keys", "on"])
        run(["set-option", "-g", "extended-keys-format", "csi-u"])
        // Propagate TERM_PROGRAM into sessions on (re)attach
        run(["set-option", "-g", "update-environment", "TERM_PROGRAM"])
    }

    /// Send literal keys into a tmux pane, bypassing tmux's input parsing.
    static func sendKeys(_ session: String, keys: [String]) {
        guard let tmux = findTmux() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["send-keys", "-t", session] + keys
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        // Fire-and-forget — don't block the main thread
    }

    static func cleanupOrphans(activeCellIDs: Set<UUID>) {
        let activeNames = Set(activeCellIDs.map { sessionName(for: $0) })
        for session in listSessions() {
            if !activeNames.contains(session) {
                killSession(session)
            }
        }
    }
}

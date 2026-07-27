import Foundation

enum TmuxManager {
    static let prefix = "is-"
    /// Native and tmux scrollback use one bounded limit. A finite buffer keeps
    /// long-running Codex sessions scrollable without unbounded memory growth.
    static let historyLimit = 10_000
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

        let systemCandidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        var searchPaths: [String] = []
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("tmux").path {
            searchPaths.append(bundlePath)
        }
        searchPaths.append(contentsOf: systemCandidates)

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

    /// Capture a pane's visible contents plus, when requested, its retained
    /// scrollback. This must run off the main thread because it launches tmux
    /// and waits for its output.
    static func capturePane(session: String, scrollback: Int? = nil) -> Data? {
        let startLine = scrollback.flatMap { $0 > 0 ? "-\($0)" : nil }
        return capturePane(session: session, startLine: startLine, endLine: nil)
    }

    /// Capture only the history portion of a pane. Line zero is the top of the
    /// visible pane in tmux, so ending at -1 deliberately leaves the current
    /// screen for the attaching client to redraw instead of duplicating it.
    static func capturePaneHistory(session: String, limit: Int = historyLimit) -> Data? {
        guard limit > 0 else { return nil }
        return capturePane(session: session, startLine: "-\(limit)", endLine: "-1")
    }

    /// Reads the currently visible pane only. Callers must treat the returned
    /// text as ephemeral: it is suitable for local status inference, never for
    /// persistence or diagnostics.
    static func visiblePaneText(session: String) -> String? {
        guard let data = capturePane(
            session: session,
            startLine: nil,
            endLine: nil,
            joinWrappedLines: true
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func capturePane(
        session: String,
        startLine: String?,
        endLine: String?,
        joinWrappedLines: Bool = false
    ) -> Data? {
        guard let tmux = findTmux() else { return nil }
        var args = ["capture-pane", "-p"]
        if joinWrappedLines {
            args.append("-J")
        }
        args += ["-t", session]
        if let startLine {
            args += ["-S", startLine]
        }
        if let endLine {
            args += ["-E", endLine]
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Read before waiting so a large scrollback cannot fill the pipe
            // and deadlock the child process.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
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

    /// Configure global tmux input settings. Mouse handling is configured per
    /// Infinite Scroll session so unrelated tmux sessions keep their own setup.
    static func configureGlobals() {
        guard !_configuredGlobals else { return }
        _configuredGlobals = true
        run(["set-option", "-g", "extended-keys", "on"])
        run(["set-option", "-g", "extended-keys-format", "csi-u"])
        // Propagate TERM_PROGRAM into sessions on (re)attach
        run(["set-option", "-g", "update-environment", "TERM_PROGRAM"])
    }

    /// Keep app-managed panes in SwiftTerm's local scrollback and remove tmux
    /// chrome that is not useful inside the app. These are session options, so
    /// they do not alter the user's other tmux sessions.
    static func configureSession(_ session: String) {
        // LocalProcessTerminalView starts `tmux new-session` asynchronously.
        // Wait briefly for a newly-created session so it cannot miss this
        // configuration and inherit an older global `mouse on` setting.
        for attempt in 0..<20 {
            if configureExistingSession(session) {
                return
            }
            if attempt < 19 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Apply pane settings immediately when reattaching to a session that
    /// already exists. Returns false for new sessions so callers can avoid the
    /// retry loop used by `configureSession`.
    @discardableResult
    static func configureExistingSession(_ session: String) -> Bool {
        guard sessionExists(session) else { return false }
        _ = run(["set-option", "-q", "-t", session, "history-limit", "\(historyLimit)"])
        _ = run(["set-option", "-q", "-t", session, "mouse", "off"])
        _ = run(["set-option", "-q", "-t", session, "status", "off"])
        _ = run(["send-keys", "-t", session, "-X", "cancel"])
        return true
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

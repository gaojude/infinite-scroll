import AppKit
import SwiftUI
import SwiftTerm

// MARK: - Shift+Enter fix for Kitty keyboard protocol

enum ShiftEnterMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36,
                  event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control) else {
                return event
            }
            // Walk up the responder/view chain to find a LocalProcessTerminalView
            guard let firstResponder = event.window?.firstResponder as? NSView else {
                return event
            }
            var current: NSView? = firstResponder
            while let view = current {
                if let termView = view as? LocalProcessTerminalView {
                    // CSI-u sequence for Shift+Enter: ESC[13;2u
                    let sequence: [UInt8] = [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]

                    if let session = TerminalViewRegistry.shared.tmuxSession(for: termView) {
                        // tmux-backed: use send-keys to bypass tmux's input parsing
                        DispatchQueue.global(qos: .userInteractive).async {
                            TmuxManager.sendKeys(session, keys: ["Escape", "[13;2u"])
                        }
                    } else {
                        termView.send(data: ArraySlice(sequence))
                    }
                    return nil
                }
                current = view.superview
            }
            return event
        }
    }
}

// MARK: - Cmd+Backspace → Ctrl+U (kill to beginning of line)

enum CmdBackspaceMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51,                       // Backspace
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.control) else {
                return event
            }
            guard let firstResponder = event.window?.firstResponder as? NSView else {
                return event
            }
            var current: NSView? = firstResponder
            while let view = current {
                if let termView = view as? LocalProcessTerminalView {
                    let ctrlU: [UInt8] = [0x15]

                    if let session = TerminalViewRegistry.shared.tmuxSession(for: termView) {
                        DispatchQueue.global(qos: .userInteractive).async {
                            TmuxManager.sendKeys(session, keys: ["C-u"])
                        }
                    } else {
                        termView.send(data: ArraySlice(ctrlU))
                    }
                    return nil
                }
                current = view.superview
            }
            return event
        }
    }
}

// MARK: - TerminalWrapper

struct TerminalWrapper: NSViewRepresentable {
    let terminalID: UUID
    let initialDirectory: String
    let fontSize: CGFloat
    let fontName: String
    let onExit: (Int32) -> Void
    let onCwdChange: (String) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // SwiftTerm defaults to 500 lines. Keep the same bounded history as
        // the app-managed tmux pane so native scrolling can reach the complete
        // retained terminal history without using tmux copy-mode.
        termView.terminal.changeScrollback(TmuxManager.historyLimit)
        // Disable SwiftTerm's mouse reporting so click+drag does text selection.
        termView.allowMouseReporting = false

        let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        let fgColor = NSColor(red: 0.85, green: 0.85, blue: 0.88, alpha: 1.0)
        termView.nativeBackgroundColor = bgColor
        termView.nativeForegroundColor = fgColor

        termView.font = NSFont(name: fontName, size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        context.coordinator.termView = termView
        termView.processDelegate = context.coordinator

        let env = ProcessLocator.shellEnvironment()
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Use tmux if available for session persistence. Prewarming normally
        // resolves this off-main, but the first terminal can be created before
        // that finishes; resolve once here rather than silently falling back to
        // a non-persistent shell on first launch.
        let sessionName = TmuxManager.sessionName(for: terminalID)
        if let tmuxPath = TmuxManager.cachedTmuxPath() ?? TmuxManager.findTmux() {
            // -A: attach if exists, create if not. -c is honored only on create.
            // -D: detach other clients (from previous app run).
            let args = ["new-session", "-A", "-D", "-s", sessionName, "-c", initialDirectory]
            let coordinator = context.coordinator
            coordinator.isTmux = true
            TerminalViewRegistry.shared.register(id: terminalID, view: termView, tmuxSession: sessionName)

            // Let SwiftUI complete the first layout pass before importing the
            // saved history. That keeps captured lines aligned with the final
            // terminal width instead of the temporary 800x600 construction size.
            DispatchQueue.main.async { [weak coordinator] in
                DispatchQueue.global(qos: .userInitiated).async {
                    TmuxManager.configureGlobals()
                    _ = TmuxManager.configureExistingSession(sessionName)
                    let history = TmuxManager.capturePaneHistory(session: sessionName)
                    DispatchQueue.main.async { [weak coordinator] in
                        coordinator?.startTmuxClient(
                            executable: tmuxPath,
                            args: args,
                            environment: envPairs,
                            session: sessionName,
                            history: history
                        )
                    }
                }
            }

            // A stalled tmux server must not leave a new terminal blank. In
            // the normal case the history capture wins this race; otherwise we
            // start promptly and discard the late snapshot to keep input live.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak coordinator] in
                coordinator?.startTmuxClient(
                    executable: tmuxPath,
                    args: args,
                    environment: envPairs,
                    session: sessionName,
                    history: nil
                )
            }
        } else {
            // Fallback: plain zsh
            termView.startProcess(
                executable: "/bin/zsh",
                args: ["-l"],
                environment: envPairs,
                execName: "zsh",
                currentDirectory: initialDirectory
            )
            TerminalViewRegistry.shared.register(id: terminalID, view: termView)
        }

        context.coordinator.startCwdPolling()
        ShiftEnterMonitor.install()
        CmdBackspaceMonitor.install()

        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if nsView.font.pointSize != fontSize || nsView.font.fontName != font.fontName {
            nsView.font = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalID: terminalID, initialDirectory: initialDirectory, onExit: onExit, onCwdChange: onCwdChange)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.invalidate()
        coordinator.stopCwdPolling()
        TerminalViewRegistry.shared.unregister(id: coordinator.terminalID)
        if coordinator.isTmux {
            // Detach from tmux (don't kill the session — it persists). Ctrl+B, d.
            let detachSeq: [UInt8] = [0x02, 0x64]
            nsView.send(data: ArraySlice(detachSeq))
        }
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let terminalID: UUID
        let onExit: (Int32) -> Void
        let onCwdChange: (String) -> Void
        weak var termView: LocalProcessTerminalView?
        private var cwdTimer: Timer?
        private var lastKnownCwd: String?
        private var oscWorking = false
        var isTmux = false
        private var isActive = true
        private var tmuxLaunchStarted = false

        init(terminalID: UUID, initialDirectory: String, onExit: @escaping (Int32) -> Void, onCwdChange: @escaping (String) -> Void) {
            self.terminalID = terminalID
            self.lastKnownCwd = initialDirectory
            self.onExit = onExit
            self.onCwdChange = onCwdChange
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            if let dir = directory {
                let cleaned = dir.hasPrefix("file://") ? URL(string: dir)?.path ?? dir : dir
                updateCwd(cleaned)
                // OSC 7 is working — disable expensive lsof polling
                if !oscWorking {
                    oscWorking = true
                    stopCwdPolling()
                }
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            stopCwdPolling()
            DispatchQueue.main.async { [self] in
                onExit(exitCode ?? -1)
            }
        }

        func invalidate() {
            isActive = false
        }

        /// Restore retained tmux history into SwiftTerm's normal buffer before
        /// the client attaches. The client then redraws only the current pane,
        /// leaving the restored history available to native trackpad scrolling.
        func startTmuxClient(
            executable: String,
            args: [String],
            environment: [String],
            session: String,
            history: Data?
        ) {
            guard isActive,
                  !tmuxLaunchStarted,
                  let termView,
                  let registeredView = TerminalViewRegistry.shared.view(for: terminalID),
                  registeredView === termView else {
                return
            }
            tmuxLaunchStarted = true

            let launchProcess = { [weak self, weak termView] in
                guard let self,
                      self.isActive,
                      let termView,
                      let registeredView = TerminalViewRegistry.shared.view(for: self.terminalID),
                      registeredView === termView else {
                    return
                }
                termView.startProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    execName: "tmux"
                )
                DispatchQueue.global(qos: .userInitiated).async {
                    TmuxManager.configureSession(session)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak termView] in
                    guard let self,
                          self.isActive,
                          let termView,
                          let registeredView = TerminalViewRegistry.shared.view(for: self.terminalID),
                          registeredView === termView else {
                        return
                    }
                    termView.send(data: ArraySlice<UInt8>([0x0c])) // Ctrl+L
                }
            }

            guard let history, !history.isEmpty else {
                launchProcess()
                return
            }
            hydrate(history: history, into: termView, then: launchProcess)
        }

        /// tmux capture-pane uses LF-only output. A terminal LF does not reset
        /// the column, so convert it to CRLF and feed bounded chunks on the
        /// main run loop rather than blocking interface events on large panes.
        private func hydrate(history: Data, into termView: LocalProcessTerminalView, then completion: @escaping () -> Void) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(history.count + history.count / 80)
            var previous: UInt8?
            for byte in history {
                if byte == 0x0A, previous != 0x0D {
                    bytes.append(0x0D)
                }
                bytes.append(byte)
                previous = byte
            }

            guard !bytes.isEmpty else {
                completion()
                return
            }

            let chunkSize = 16 * 1024
            var offset = 0
            func feedNextChunk() {
                guard isActive,
                      let registeredView = TerminalViewRegistry.shared.view(for: terminalID),
                      registeredView === termView else {
                    return
                }
                guard offset < bytes.count else {
                    completion()
                    return
                }
                let end = min(offset + chunkSize, bytes.count)
                termView.feed(byteArray: bytes[offset..<end])
                offset = end
                DispatchQueue.main.async(execute: feedNextChunk)
            }
            feedNextChunk()
        }

        func startCwdPolling() {
            cwdTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.pollCwd()
            }
        }

        func stopCwdPolling() {
            cwdTimer?.invalidate()
            cwdTimer = nil
        }

        private func pollCwd() {
            guard let termView = termView else { return }
            let pid = termView.process.shellPid
            guard pid > 0 else { return }

            let termID = terminalID
            let usingTmux = isTmux

            DispatchQueue.global(qos: .utility).async { [weak self] in
                if usingTmux {
                    // Use tmux to get the pane's actual working directory
                    let sessionName = TmuxManager.sessionName(for: termID)
                    if let cwd = TmuxManager.paneCwd(session: sessionName) {
                        DispatchQueue.main.async {
                            self?.updateCwd(cwd)
                        }
                    }
                    return
                }

                let task = Process()
                let pipe = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                task.arguments = ["-p", "\(pid)", "-d", "cwd", "-Fn"]
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch { return }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: "\n")
                    for line in lines where line.hasPrefix("n") && line.count > 1 {
                        let cwd = String(line.dropFirst())
                        DispatchQueue.main.async {
                            self?.updateCwd(cwd)
                        }
                        break
                    }
                }
            }
        }

        private func updateCwd(_ cwd: String) {
            guard cwd != "/", cwd != lastKnownCwd else { return }
            lastKnownCwd = cwd
            onCwdChange(cwd)
        }
    }
}

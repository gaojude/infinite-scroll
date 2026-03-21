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
            guard let firstResponder = event.window?.firstResponder,
                  firstResponder is LocalProcessTerminalView,
                  let termView = firstResponder as? LocalProcessTerminalView else {
                return event
            }
            let sequence: [UInt8] = [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]
            termView.send(data: ArraySlice(sequence))
            return nil
        }
    }
}

// MARK: - TerminalWrapper

struct TerminalWrapper: NSViewRepresentable {
    let terminalID: UUID
    let initialDirectory: String
    let fontSize: CGFloat
    let onExit: (Int32) -> Void
    let onCwdChange: (String) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        let fgColor = NSColor(red: 0.85, green: 0.85, blue: 0.88, alpha: 1.0)
        termView.nativeBackgroundColor = bgColor
        termView.nativeForegroundColor = fgColor

        if let font = NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) as NSFont? {
            termView.font = font
        }

        TerminalViewRegistry.shared.register(id: terminalID, view: termView)

        context.coordinator.termView = termView
        termView.processDelegate = context.coordinator

        let env = ProcessLocator.shellEnvironment()
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Use tmux if available for session persistence
        let sessionName = TmuxManager.sessionName(for: terminalID)
        if let tmuxPath = TmuxManager.findTmux() {
            let sessionExists = TmuxManager.sessionExists(sessionName)
            // `new-session -A` attaches if exists, creates if not
            // `-c dir` sets the working directory for new sessions only
            // -A: attach if exists, create if not
            // -D: detach other clients (from previous app run)
            var args = ["new-session", "-A", "-D", "-s", sessionName]
            if !sessionExists {
                args += ["-c", initialDirectory]
            }
            context.coordinator.isTmux = true
            termView.startProcess(
                executable: tmuxPath,
                args: args,
                environment: envPairs,
                execName: "tmux"
            )
            // Force tmux to redraw after reattach — fixes display corruption
            if sessionExists {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Send Ctrl+L to clear/redraw, then clear the screen properly
                    termView.send(data: ArraySlice<UInt8>([0x0c])) // Ctrl+L
                }
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
        }

        context.coordinator.startCwdPolling()
        ShiftEnterMonitor.install()

        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        let font = NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if nsView.font.pointSize != fontSize {
            nsView.font = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalID: terminalID, initialDirectory: initialDirectory, onExit: onExit, onCwdChange: onCwdChange)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stopCwdPolling()
        TerminalViewRegistry.shared.unregister(id: coordinator.terminalID)
        // Detach from tmux (don't kill the session — it persists)
        // Send tmux detach: Ctrl+B, d
        let detachSeq: [UInt8] = [0x02, 0x64] // Ctrl+B, d
        nsView.send(data: ArraySlice(detachSeq))
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

            DispatchQueue.global(qos: .utility).async { [weak self] in
                // For tmux, we need the child shell's PID, not tmux's
                // Get the foreground process group of the tmux client
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

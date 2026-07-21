import AppKit
import SwiftUI
import SwiftTerm

// MARK: - Tmux-aware terminal input

/// tmux renders its client in the terminal's alternate screen, so SwiftTerm's
/// local scrollback is unavailable while a tmux session is attached. Keep the
/// tmux copy-mode commands serial, then leave copy-mode before forwarding the
/// user's next input so browsing history never leaves a cell looking frozen.
final class TmuxTerminalView: LocalProcessTerminalView {
    private enum CopyModeState: Equatable {
        case inactive
        case browsing
        case exiting
    }

    private let tmuxCommandQueue = DispatchQueue(
        label: "com.judegao.infinite-scroll.tmux-scroll",
        qos: .userInitiated
    )
    private var tmuxSession: String?
    private var copyModeState: CopyModeState = .inactive
    private var pendingInput: [() -> Void] = []

    var isBrowsingTmuxHistory: Bool {
        copyModeState != .inactive
    }

    func configureTmux(session: String) {
        tmuxSession = session
    }

    /// Returns true when this terminal is tmux-backed and has consumed the
    /// scroll gesture. Commands are serialized so a fast two-finger gesture
    /// cannot send scroll commands before copy-mode is entered.
    @discardableResult
    func scrollTmux(delta: CGFloat) -> Bool {
        guard let session = tmuxSession, delta != 0 else { return false }
        guard copyModeState != .exiting else { return true }

        let lines = max(1, Int(abs(delta) / 12))
        let command = delta > 0 ? "scroll-up" : "scroll-down"
        let shouldEnterCopyMode = copyModeState == .inactive
        copyModeState = .browsing

        tmuxCommandQueue.async {
            if shouldEnterCopyMode {
                _ = TmuxManager.run(["copy-mode", "-t", session])
            }
            for _ in 0..<lines {
                _ = TmuxManager.run(["send-keys", "-t", session, "-X", command])
            }
        }
        return true
    }

    /// Run a user input action after queued scrolling has left tmux copy-mode.
    /// Multiple keystrokes are preserved and forwarded in order once cancel
    /// completes, rather than allowing the first key to be swallowed by tmux.
    func exitCopyModeIfNeeded(then forward: @escaping () -> Void) {
        guard let session = tmuxSession, copyModeState != .inactive else {
            forward()
            return
        }

        pendingInput.append(forward)
        guard copyModeState == .browsing else { return }
        copyModeState = .exiting

        tmuxCommandQueue.async { [weak self] in
            _ = TmuxManager.run(["send-keys", "-t", session, "-X", "cancel"])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.copyModeState = .inactive
                let input = self.pendingInput
                self.pendingInput.removeAll()
                input.forEach { $0() }
            }
        }
    }
}

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

                    let sendShiftEnter = {
                        if let session = TerminalViewRegistry.shared.tmuxSession(for: termView) {
                            // tmux-backed: use send-keys to bypass tmux's input parsing
                            DispatchQueue.global(qos: .userInteractive).async {
                                TmuxManager.sendKeys(session, keys: ["Escape", "[13;2u"])
                            }
                        } else {
                            termView.send(data: ArraySlice(sequence))
                        }
                    }
                    if let tmuxTermView = termView as? TmuxTerminalView {
                        tmuxTermView.exitCopyModeIfNeeded(then: sendShiftEnter)
                    } else {
                        sendShiftEnter()
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

                    let sendCtrlU = {
                        if let session = TerminalViewRegistry.shared.tmuxSession(for: termView) {
                            DispatchQueue.global(qos: .userInteractive).async {
                                TmuxManager.sendKeys(session, keys: ["C-u"])
                            }
                        } else {
                            termView.send(data: ArraySlice(ctrlU))
                        }
                    }
                    if let tmuxTermView = termView as? TmuxTerminalView {
                        tmuxTermView.exitCopyModeIfNeeded(then: sendCtrlU)
                    } else {
                        sendCtrlU()
                    }
                    return nil
                }
                current = view.superview
            }
            return event
        }
    }
}

// MARK: - Leave tmux copy-mode before normal terminal input

enum TmuxCopyModeMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let firstResponder = event.window?.firstResponder as? NSView else {
                return event
            }

            var current: NSView? = firstResponder
            while let view = current {
                if let termView = view as? TmuxTerminalView {
                    guard termView.isBrowsingTmuxHistory else { return event }
                    termView.exitCopyModeIfNeeded {
                        // The local monitor consumes this event. Forward it only
                        // after tmux has processed `cancel`, so the first key is
                        // delivered to the shell instead of the copy-mode table.
                        termView.keyDown(with: event)
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
        let termView = TmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
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

        // Use tmux if available for session persistence
        let sessionName = TmuxManager.sessionName(for: terminalID)
        if let tmuxPath = TmuxManager.cachedTmuxPath() {
            // -A: attach if exists, create if not. -c is honored only on create.
            // -D: detach other clients (from previous app run).
            let args = ["new-session", "-A", "-D", "-s", sessionName, "-c", initialDirectory]
            context.coordinator.isTmux = true
            termView.configureTmux(session: sessionName)
            termView.startProcess(
                executable: tmuxPath,
                args: args,
                environment: envPairs,
                execName: "tmux"
            )
            DispatchQueue.global(qos: .userInitiated).async {
                TmuxManager.configureGlobals()
                TmuxManager.configureSession(sessionName)
            }
            TerminalViewRegistry.shared.register(id: terminalID, view: termView, tmuxSession: sessionName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                termView.send(data: ArraySlice<UInt8>([0x0c])) // Ctrl+L
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
        TmuxCopyModeMonitor.install()

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

import AppKit
import Combine
import Darwin
import Foundation
import InfiniteScrollProtocol

final class CLIServer {
    private weak var store: PanelStore?
    private let serverQueue = DispatchQueue(label: "infinite-scroll.cli.server")
    private var listenFD: Int32 = -1
    private var watchers: [Int32] = []
    private let watchersLock = NSLock()
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    init(store: PanelStore) {
        self.store = store
    }

    func start() {
        guard !started else { return }
        started = true
        serverQueue.async { [weak self] in self?.run() }
        // Watch store changes on main thread and broadcast snapshots
        DispatchQueue.main.async { [weak self] in self?.subscribeToStore() }
    }

    private func subscribeToStore() {
        guard let store = store else { return }
        // Re-emit on any change. Debounce to coalesce typing bursts.
        let changed = Publishers.Merge3(
            store.$panels.map { _ in () },
            store.$focusedCellID.map { _ in () },
            store.objectWillChange.map { _ in () }
        )
        changed
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.broadcastEvent(kind: "changed") }
            .store(in: &cancellables)
    }

    // MARK: - Socket setup

    private func run() {
        let path = CLISocket.path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = path.withCString { unlink($0) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[CLIServer] socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        // Don't let child processes (tmux, shells) inherit the listen FD — they'd
        // keep the socket "alive" after the app exits, breaking future runs.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= pathMax else {
            NSLog("[CLIServer] socket path too long: \(path)")
            close(fd); return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathMax) { cptr in
                pathBytes.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { srcChars in
                        memcpy(cptr, srcChars, pathBytes.count)
                    }
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[CLIServer] bind() failed: \(String(cString: strerror(errno)))")
            close(fd); return
        }
        _ = path.withCString { chmod($0, 0o600) }

        guard listen(fd, 8) == 0 else {
            NSLog("[CLIServer] listen() failed: \(String(cString: strerror(errno)))")
            close(fd); return
        }
        listenFD = fd
        NSLog("[CLIServer] listening on \(path)")

        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                NSLog("[CLIServer] accept() failed: \(String(cString: strerror(errno)))")
                break
            }
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            let connQueue = DispatchQueue(label: "infinite-scroll.cli.client.\(clientFD)")
            connQueue.async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client handling

    private func handleClient(fd: Int32) {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        var alive = true
        while alive {
            let n = tmp.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let stay = processRequest(line: line, fd: fd)
                if !stay { alive = false; break }
            }
        }
        watchersLock.lock()
        watchers.removeAll { $0 == fd }
        watchersLock.unlock()
        close(fd)
    }

    /// Returns true if the connection should stay open (watch mode).
    private func processRequest(line: Data, fd: Int32) -> Bool {
        guard let req = try? JSONDecoder().decode(CLIRequest.self, from: line) else {
            writeResponse(.failure("invalid request JSON"), to: fd)
            return false
        }
        if req.kind == "watch" {
            // Send initial snapshot, then keep connection open
            let rows = DispatchQueue.main.sync { self.store?.cliVisibleSnapshot() ?? [] }
            writeResponse(CLIResponse(ok: true, rows: rows), to: fd)
            watchersLock.lock()
            watchers.append(fd)
            watchersLock.unlock()
            return true
        }
        // capture/send spawn tmux subprocesses that can block for seconds.
        // Run them on the connection queue (off-main) and only hop to main
        // for the brief state lookup. Everything else stays on main.
        let response: CLIResponse
        switch req.kind {
        case "capture": response = handleCaptureOffMain(req)
        case "send":    response = handleSendOffMain(req)
        default:        response = DispatchQueue.main.sync { handle(req) }
        }
        writeResponse(response, to: fd)
        return false
    }

    // MARK: - Off-main handlers (subprocess-spawning)

    /// "capture": resolve the cell on main, then run `tmux capture-pane`
    /// on the calling (background) queue so the main thread stays free.
    private func handleCaptureOffMain(_ req: CLIRequest) -> CLIResponse {
        let plan: CapturePlan = DispatchQueue.main.sync {
            guard let store = store else { return .fail("store unavailable") }
            switch resolveCellForCLI(req.cell, store: store) {
            case .failure(let msg):
                return .fail(msg)
            case .found(let r, let c):
                guard let (cell, _) = store.cliCellAt(rowIdx: r, cellIdx: c) else {
                    return .fail("cell not found: \(req.cell ?? "")")
                }
                if cell.type == .notes {
                    return .notes(cell.text)
                }
                return .terminal(
                    session: TmuxManager.sessionName(for: cell.id),
                    scrollback: req.scrollback
                )
            }
        }
        switch plan {
        case .fail(let msg):
            return .failure(msg)
        case .notes(let text):
            return CLIResponse(ok: true, text: text)
        case .terminal(let session, let scrollback):
            let text = TmuxCapture.capture(session: session, scrollback: scrollback)
            return CLIResponse(ok: true, text: text)
        }
    }

    /// "send": resolve the cell on main, then invoke tmux off-main. The
    /// previous code held the main thread inside `Process.waitUntilExit()`
    /// for the duration of `send-keys -l <text>`, which froze the UI for
    /// tens of seconds with large payloads.
    private func handleSendOffMain(_ req: CLIRequest) -> CLIResponse {
        let plan: SendPlan = DispatchQueue.main.sync {
            guard let store = store else { return .fail("store unavailable") }
            switch resolveCellForCLI(req.cell, store: store) {
            case .failure(let msg):
                return .fail(msg)
            case .found(let r, let c):
                guard let (cell, _) = store.cliCellAt(rowIdx: r, cellIdx: c) else {
                    return .fail("cell not found: \(req.cell ?? "")")
                }
                guard cell.type == .terminal else {
                    return .fail("cannot send keys to non-terminal cell")
                }
                return .send(session: TmuxManager.sessionName(for: cell.id))
            }
        }
        switch plan {
        case .fail(let msg):
            return .failure(msg)
        case .send(let session):
            // A pane can be in tmux copy-mode (for example, from its own key
            // bindings). In that state `send-keys` dispatches to the copy-mode
            // key table instead of the shell, so cancel it first. `-X cancel`
            // is a no-op when the pane is not in copy-mode.
            _ = TmuxManager.run(["send-keys", "-t", session, "-X", "cancel"])
            if let keys = req.keys, !keys.isEmpty {
                TmuxManager.sendKeys(session, keys: keys)
            }
            if let text = req.text, !text.isEmpty {
                // -l for literal text (no key parsing)
                _ = TmuxManager.run(["send-keys", "-t", session, "-l", text])
            }
            return .okEmpty()
        }
    }

    private func writeResponse(_ response: CLIResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), remaining)
                if n <= 0 { return }
                offset += n
                remaining -= n
            }
        }
    }

    private func broadcastEvent(kind: String) {
        guard let store = store else { return }
        let rows = store.cliVisibleSnapshot()
        let resp = CLIResponse(
            ok: true,
            rows: rows,
            event: EventInfo(kind: kind)
        )
        watchersLock.lock()
        let fds = watchers
        watchersLock.unlock()
        for fd in fds {
            writeResponse(resp, to: fd)
        }
    }

    // MARK: - Handlers (main thread)

    private func handle(_ req: CLIRequest) -> CLIResponse {
        guard let store = store else { return .failure("store unavailable") }
        switch req.kind {
        case "ping":
            return CLIResponse(ok: true, text: "pong")
        case "list":
            return CLIResponse(ok: true, rows: store.cliVisibleSnapshot())
        case "focus":
            return resolveCellForCLI(req.cell, store: store).flatMap { r, c in
                store.cliFocusCell(rowIdx: r, cellIdx: c)
                return .okEmpty()
            }
        // "capture" and "send" are handled off-main by processRequest
        // (see handleCaptureOffMain / handleSendOffMain) to avoid blocking
        // the main thread on tmux subprocesses.
        case "notes-read":
            return resolveCellForCLI(req.cell, store: store).flatMap { r, c in
                guard let text = store.cliReadNotes(rowIdx: r, cellIdx: c) else {
                    return .failure("notes cell not found: \(req.cell ?? "")")
                }
                return CLIResponse(ok: true, text: text)
            }
        case "notes-write":
            return resolveCellForCLI(req.cell, store: store).flatMap { r, c in
                let ok = store.cliWriteNotes(rowIdx: r, cellIdx: c, text: req.text ?? "")
                return ok ? .okEmpty() : .failure("not a notes cell")
            }
        case "new-row":
            let id = store.cliAddRow()
            let info = store.cliVisibleSnapshot().first(where: { $0.id == id.uuidString })
            return CLIResponse(ok: true, rows: info.map { [$0] })
        case "new-cell":
            let rowIdx: Int
            if let row = req.row, let resolved = store.resolveRow(row) {
                rowIdx = resolved
            } else {
                rowIdx = store.focusedRow
            }
            // Master row is off-limits to the CLI.
            if store.isMasterCell(rowIdx: rowIdx, cellIdx: 0) {
                return .failure("row 0 is reserved (master row)")
            }
            let type: CellType = (req.cellType == "notes") ? .notes : .terminal
            guard let newID = store.cliAddCell(rowIdx: rowIdx, type: type) else {
                return .failure("could not add cell")
            }
            let info = store.cliVisibleSnapshot()
                .first(where: { $0.index == rowIdx })?
                .cells.first(where: { $0.id == newID.uuidString })
            return CLIResponse(ok: true, cell: info)
        case "close":
            return resolveCellForCLI(req.cell, store: store).flatMap { r, c in
                store.cliCloseCell(rowIdx: r, cellIdx: c)
                return .okEmpty()
            }
        default:
            return .failure("unknown command: \(req.kind)")
        }
    }

    /// Resolves a CLI-supplied cell reference, rejecting any reference to the master row.
    private func resolveCellForCLI(_ ref: String?, store: PanelStore) -> CellLookup {
        guard let ref = ref, let (r, c) = store.resolveCell(ref) else {
            return .failure("cell not found: \(ref ?? "")")
        }
        if store.isMasterCell(rowIdx: r, cellIdx: c) {
            return .failure("row 0 is reserved (master row)")
        }
        return .found(r, c)
    }
}

/// Result of resolving a CLI cell reference.
private enum CellLookup {
    case found(Int, Int)
    case failure(String)

    func flatMap(_ body: (Int, Int) -> CLIResponse) -> CLIResponse {
        switch self {
        case .found(let r, let c): return body(r, c)
        case .failure(let msg): return CLIResponse.failure(msg)
        }
    }
}

/// Plan produced on the main thread for a "capture" request, executed off-main.
private enum CapturePlan {
    case fail(String)
    case notes(String)
    case terminal(session: String, scrollback: Int?)
}

/// Plan produced on the main thread for a "send" request, executed off-main.
private enum SendPlan {
    case fail(String)
    case send(session: String)
}

// MARK: - tmux capture-pane helper

enum TmuxCapture {
    static func capture(session: String, scrollback: Int?) -> String {
        guard let data = TmuxManager.capturePane(session: session, scrollback: scrollback) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

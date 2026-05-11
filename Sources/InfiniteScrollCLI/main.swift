import Darwin
import Foundation
import InfiniteScrollProtocol

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.first == "-h" || args.first == "--help" {
    printHelp()
    exit(0)
}

if args.first == "--version" || args.first == "-v" {
    print("infinite-scroll CLI CLI_VERSION_PLACEHOLDER")
    exit(0)
}

let command = args[0]
let rest = Array(args.dropFirst())

switch command {
case "list", "ls":
    cmdList(rest)
case "capture", "read":
    cmdCapture(rest)
case "send":
    cmdSend(rest)
case "focus":
    cmdFocus(rest)
case "notes":
    cmdNotes(rest)
case "new-row":
    cmdNewRow(rest)
case "new-cell":
    cmdNewCell(rest)
case "close":
    cmdClose(rest)
case "watch":
    cmdWatch(rest)
case "ping":
    cmdPing()
case "install":
    cmdInstall(rest)
case "uninstall":
    cmdUninstall()
case "socket-path":
    print(CLISocket.path)
default:
    fputs("infinite-scroll: unknown command '\(command)'\n", stderr)
    fputs("Run 'infinite-scroll --help' for usage.\n", stderr)
    exit(2)
}

// MARK: - Commands

func cmdList(_ args: [String]) {
    let json = args.contains("--json")
    let resp = sendOne(CLIRequest(kind: "list"))
    guard resp.ok, let rows = resp.rows else { fail(resp); return }
    if json {
        printJSON(rows)
        return
    }
    if rows.isEmpty { print("(empty)"); return }
    for row in rows {
        let focus = row.focused ? "*" : " "
        print("\(focus) Row \(row.index)  [\(row.id)]  \(row.title)")
        for cell in row.cells {
            let cellFocus = cell.focused ? "*" : " "
            var line = "  \(cellFocus) \(cell.ref)  [\(cell.id)]  \(cell.type)"
            if let cwd = cell.cwd { line += "  \(cwd)" }
            if cell.isRunning == false { line += "  (exited)" }
            print(line)
        }
    }
}

func cmdCapture(_ args: [String]) {
    guard let cell = args.first else {
        fputs("usage: infinite-scroll capture <cell> [--scrollback N]\n", stderr)
        exit(2)
    }
    var scrollback: Int?
    if let idx = args.firstIndex(of: "--scrollback"), idx + 1 < args.count {
        scrollback = Int(args[idx + 1])
    }
    let resp = sendOne(CLIRequest(kind: "capture", cell: cell, scrollback: scrollback))
    guard resp.ok else { fail(resp); return }
    if let text = resp.text { Swift.print(text, terminator: "") }
}

func cmdSend(_ args: [String]) {
    guard let cell = args.first else {
        fputs("usage: infinite-scroll send <cell> [--text \"text\"] [--keys Enter ...]\n", stderr)
        fputs("       infinite-scroll send <cell> \"text to send\"\n", stderr)
        exit(2)
    }
    let after = Array(args.dropFirst())
    var text: String?
    var keys: [String] = []
    var i = 0
    var positional: [String] = []
    while i < after.count {
        let a = after[i]
        switch a {
        case "--text":
            i += 1
            if i < after.count { text = after[i] }
        case "--keys":
            i += 1
            while i < after.count && !after[i].hasPrefix("--") {
                keys.append(after[i])
                i += 1
            }
            continue
        case "--enter":
            keys.append("Enter")
        default:
            positional.append(a)
        }
        i += 1
    }
    if text == nil && !positional.isEmpty {
        text = positional.joined(separator: " ")
    }
    let resp = sendOne(CLIRequest(
        kind: "send",
        cell: cell,
        text: text,
        keys: keys.isEmpty ? nil : keys
    ))
    guard resp.ok else { fail(resp); return }
}

func cmdFocus(_ args: [String]) {
    guard let cell = args.first else {
        fputs("usage: infinite-scroll focus <cell>\n", stderr)
        exit(2)
    }
    let resp = sendOne(CLIRequest(kind: "focus", cell: cell))
    guard resp.ok else { fail(resp); return }
}

func cmdNotes(_ args: [String]) {
    guard let cell = args.first else {
        fputs("usage: infinite-scroll notes <cell> [--write \"text\"]\n", stderr)
        exit(2)
    }
    if let idx = args.firstIndex(of: "--write"), idx + 1 < args.count {
        let text = args[(idx + 1)...].joined(separator: " ")
        let resp = sendOne(CLIRequest(kind: "notes-write", cell: cell, text: text))
        guard resp.ok else { fail(resp); return }
        return
    }
    let resp = sendOne(CLIRequest(kind: "notes-read", cell: cell))
    guard resp.ok else { fail(resp); return }
    if let t = resp.text { Swift.print(t, terminator: "") }
}

func cmdNewRow(_ args: [String]) {
    let resp = sendOne(CLIRequest(kind: "new-row"))
    guard resp.ok else { fail(resp); return }
    if let row = resp.rows?.first {
        print(row.id)
    }
}

func cmdNewCell(_ args: [String]) {
    var row: String?
    var type: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--row": i += 1; if i < args.count { row = args[i] }
        case "--type": i += 1; if i < args.count { type = args[i] }
        default: break
        }
        i += 1
    }
    let resp = sendOne(CLIRequest(kind: "new-cell", row: row, cellType: type))
    guard resp.ok else { fail(resp); return }
    if let cell = resp.cell {
        print(cell.id)
    }
}

func cmdClose(_ args: [String]) {
    guard let cell = args.first else {
        fputs("usage: infinite-scroll close <cell>\n", stderr)
        exit(2)
    }
    let resp = sendOne(CLIRequest(kind: "close", cell: cell))
    guard resp.ok else { fail(resp); return }
}

func cmdWatch(_ args: [String]) {
    let json = args.contains("--json") || true  // watch only makes sense as JSON
    _ = json
    let fd = connectOrExit()
    let req = CLIRequest(kind: "watch")
    writeLine(fd, req)
    while let line = readLine(fd) {
        guard let data = line.data(using: .utf8),
              let resp = try? JSONDecoder().decode(CLIResponse.self, from: data) else {
            continue
        }
        if let encoded = try? JSONEncoder().encode(resp),
           let out = String(data: encoded, encoding: .utf8) {
            print(out)
            fflush(stdout)
        }
        if !resp.ok {
            exit(1)
        }
    }
}

func cmdPing() {
    let resp = sendOne(CLIRequest(kind: "ping"))
    if resp.ok, let text = resp.text {
        print(text)
    } else {
        fail(resp)
    }
}

// MARK: - Install / uninstall

let installTarget = "/usr/local/bin/infinite-scroll"

func cmdInstall(_ args: [String]) {
    let target = args.first(where: { !$0.hasPrefix("--") }) ?? installTarget
    let force = args.contains("--force")
    let source = ourBundledPath()

    let fm = FileManager.default
    // If target already points to source, nothing to do
    if let existing = try? fm.destinationOfSymbolicLink(atPath: target), existing == source {
        print("Already installed at \(target)")
        return
    }

    // First try writing without privilege escalation
    if tryInstallDirect(source: source, target: target, force: force) {
        print("Installed: \(target) -> \(source)")
        return
    }

    // Fall back to AppleScript admin install
    print("Need administrator privileges to install at \(target).")
    let script = adminInstallScript(source: source, target: target)
    if runAppleScript(script) {
        print("Installed: \(target) -> \(source)")
    } else {
        fputs("install failed\n", stderr)
        exit(1)
    }
}

func cmdUninstall() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: installTarget) {
        print("Not installed at \(installTarget)")
        return
    }
    do {
        try fm.removeItem(atPath: installTarget)
        print("Removed \(installTarget)")
        return
    } catch {
        // try with privileges
        let script = "do shell script \"rm -f '\(installTarget)'\" with administrator privileges"
        if runAppleScript(script) {
            print("Removed \(installTarget)")
        } else {
            fputs("uninstall failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

func ourBundledPath() -> String {
    // Resolve the absolute path to *this* binary, following symlinks
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(buf.count)
    if _NSGetExecutablePath(&buf, &size) == 0 {
        if let p = realpath(buf, nil) {
            defer { free(p) }
            return String(cString: p)
        }
    }
    return CommandLine.arguments[0]
}

func tryInstallDirect(source: String, target: String, force: Bool) -> Bool {
    let fm = FileManager.default
    let dir = (target as NSString).deletingLastPathComponent
    if !fm.fileExists(atPath: dir) {
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch { return false }
    }
    if fm.fileExists(atPath: target) || (try? fm.destinationOfSymbolicLink(atPath: target)) != nil {
        if !force { try? fm.removeItem(atPath: target) }
        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
    }
    do {
        try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
        return true
    } catch {
        return false
    }
}

func adminInstallScript(source: String, target: String) -> String {
    let dir = (target as NSString).deletingLastPathComponent
    let cmd = "mkdir -p '\(dir)' && ln -sf '\(source)' '\(target)'"
    return "do shell script \"\(cmd)\" with administrator privileges"
}

func runAppleScript(_ source: String) -> Bool {
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

// MARK: - IPC

func connectOrExit() -> Int32 {
    let path = CLISocket.path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("socket(): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= pathMax else {
        fputs("socket path too long\n", stderr); exit(1)
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathMax) { cptr in
            bytes.withUnsafeBufferPointer { src in
                src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { srcChars in
                    memcpy(cptr, srcChars, bytes.count)
                }
            }
        }
    }
    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        fputs("Cannot reach Infinite Scroll. Is the app running?\n", stderr)
        fputs("  (socket: \(path))\n", stderr)
        exit(1)
    }
    return fd
}

/// Set a recv timeout so commands don't hang forever if the app is stuck.
func setReadTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func sendOne(_ req: CLIRequest) -> CLIResponse {
    let fd = connectOrExit()
    defer { close(fd) }
    setReadTimeout(fd, seconds: 5)
    writeLine(fd, req)
    guard let line = readLine(fd),
          let data = line.data(using: .utf8),
          let resp = try? JSONDecoder().decode(CLIResponse.self, from: data) else {
        return CLIResponse(ok: false, error: "no response from app (is it running?)")
    }
    return resp
}

func writeLine(_ fd: Int32, _ req: CLIRequest) {
    guard var data = try? JSONEncoder().encode(req) else { return }
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

func readLine(_ fd: Int32) -> String? {
    var buffer = Data()
    var tmp = [UInt8](repeating: 0, count: 4096)
    while true {
        if let nlIdx = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nlIdx)
            return String(data: line, encoding: .utf8)
        }
        let n = tmp.withUnsafeMutableBytes { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 {
            if buffer.isEmpty { return nil }
            return String(data: buffer, encoding: .utf8)
        }
        buffer.append(tmp, count: n)
    }
}

// MARK: - Utils

func fail(_ resp: CLIResponse) {
    fputs("error: \(resp.error ?? "unknown")\n", stderr)
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func printHelp() {
    let usage = """
    infinite-scroll — CLI for the Infinite Scroll app

    USAGE
      infinite-scroll <command> [args]

    Cells are referenced by "row.cell" (rows start at 1, cells at 1) or by UUID.
    Row 0 is the orchestrator's own row and is not addressable from the CLI.

    COMMANDS
      list, ls [--json]              List all rows and cells
      capture <cell> [--scrollback N]
                                     Read visible content of a cell. For terminal
                                     cells, returns the tmux screen; with --scrollback
                                     N, includes the last N lines of history.
      send <cell> [text...]          Send text into a terminal cell
        --text "..."                   Explicit text (preserves whitespace)
        --keys K1 K2 ...               Named keys: Enter, Escape, C-c, Up, ...
        --enter                        Shortcut for --keys Enter
      focus <cell>                   Focus cell and scroll window to it
      notes <cell> [--write "text"]  Read or write a notes cell's content
      new-row                        Add a new row, print its UUID
      new-cell [--row REF] [--type terminal|notes]
                                     Add a new cell, print its UUID
      close <cell>                   Close a cell (kills tmux session if terminal)
      watch                          Stream JSON snapshots on every change
      ping                           Verify the app is running
      socket-path                    Print the socket path
      install [PATH]                 Install symlink at /usr/local/bin/infinite-scroll
                                     (prompts for admin password if needed)
      uninstall                      Remove the symlink
      --version                      Print CLI version
      --help                         Show this help

    EXAMPLES
      infinite-scroll list
      infinite-scroll focus 2.1
      infinite-scroll send 1.1 "ls -la" --enter
      infinite-scroll capture 1.1 --scrollback 200
      infinite-scroll notes 2.1 --write "next: refactor auth"
      infinite-scroll watch | jq .
    """
    print(usage)
}

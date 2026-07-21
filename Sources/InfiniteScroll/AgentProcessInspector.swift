import Foundation

/// Maps app-managed tmux panes to known agent processes. This is a fallback
/// identity signal for terminals the app did not launch itself; it intentionally
/// reports process presence only, not a semantic "done" state.
enum AgentProcessInspector {
    private struct SystemProcess {
        let pid: Int32
        let parentPID: Int32
        let executable: String
    }

    static func refresh(
        cellIDs: [UUID],
        completion: @escaping ([AgentProcessObservation]) -> Void
    ) {
        guard !cellIDs.isEmpty else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let observations = inspect(cellIDs: cellIDs)
            DispatchQueue.main.async {
                completion(observations)
            }
        }
    }

    private static func inspect(cellIDs: [UUID]) -> [AgentProcessObservation] {
        guard let tmuxPath = TmuxManager.findTmux() else { return [] }

        let sessionToPID = panePIDs(tmuxPath: tmuxPath)
        guard !sessionToPID.isEmpty else { return [] }

        let processes = processTable()
        guard !processes.isEmpty else { return [] }

        var children: [Int32: [SystemProcess]] = [:]
        for process in processes.values {
            children[process.parentPID, default: []].append(process)
        }

        var rootPIDs: [UUID: Int32] = [:]
        for cellID in cellIDs {
            let sessionName = TmuxManager.sessionName(for: cellID)
            if let rootPID = sessionToPID[sessionName] {
                rootPIDs[cellID] = rootPID
            }
        }
        guard !rootPIDs.isEmpty else { return [] }

        let inspectedPIDs = Set(rootPIDs.values.flatMap {
            descendantPIDs(rootPID: $0, children: children)
        })
        let argumentsByPID = commandArguments(for: inspectedPIDs)

        return cellIDs.compactMap { cellID in
            guard let rootPID = rootPIDs[cellID],
                  let match = findAgentDescendant(
                    rootPID: rootPID,
                    processes: processes,
                    children: children,
                    argumentsByPID: argumentsByPID
                  )
            else {
                return nil
            }
            return AgentProcessObservation(
                cellID: cellID,
                provider: match.provider,
                processID: match.processID
            )
        }
    }

    private static func panePIDs(tmuxPath: String) -> [String: Int32] {
        guard let output = output(
            executable: tmuxPath,
            arguments: ["list-panes", "-a", "-F", "#{session_name}|#{pane_pid}"]
        ) else {
            return [:]
        }

        var result: [String: Int32] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                continue
            }
            result[String(parts[0])] = pid
        }
        return result
    }

    private static func processTable() -> [Int32: SystemProcess] {
        guard let output = output(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,comm="]
        ) else {
            return [:]
        }

        var result: [Int32: SystemProcess] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1])
            else {
                continue
            }
            result[pid] = SystemProcess(
                pid: pid,
                parentPID: parentPID,
                executable: String(fields[2])
            )
        }
        return result
    }

    /// `ps -axo args` exposes every process's command line. We first map the
    /// tree using only PIDs and executable paths, then request arguments only
    /// for panes owned by this workspace. That is enough to identify Node-based
    /// provider wrappers without inspecting unrelated commands.
    private static func commandArguments(for processIDs: Set<Int32>) -> [Int32: String] {
        guard !processIDs.isEmpty else { return [:] }
        let identifiers = processIDs.map(String.init).joined(separator: ",")
        guard let output = output(
            executable: "/bin/ps",
            arguments: ["-p", identifiers, "-o", "pid=,args="]
        ) else {
            return [:]
        }

        var result: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            result[pid] = String(fields[1])
        }
        return result
    }

    private static func descendantPIDs(
        rootPID: Int32,
        children: [Int32: [SystemProcess]]
    ) -> Set<Int32> {
        var pending = [rootPID]
        var result: Set<Int32> = []

        while let pid = pending.popLast() {
            guard result.insert(pid).inserted else { continue }
            pending.append(contentsOf: children[pid, default: []].map(\.pid))
        }
        return result
    }

    private static func findAgentDescendant(
        rootPID: Int32,
        processes: [Int32: SystemProcess],
        children: [Int32: [SystemProcess]],
        argumentsByPID: [Int32: String]
    ) -> (provider: AgentProvider, processID: Int32)? {
        var pending: [(pid: Int32, depth: Int)] = [(rootPID, 0)]
        var visited: Set<Int32> = []
        var bestMatch: (provider: AgentProvider, processID: Int32, depth: Int)?

        while let next = pending.popLast() {
            guard visited.insert(next.pid).inserted else { continue }

            if let process = processes[next.pid],
               let provider = AgentProvider.detect(
                executable: process.executable,
                arguments: argumentsByPID[next.pid] ?? ""
               ) {
                if bestMatch == nil || next.depth >= bestMatch!.depth {
                    bestMatch = (provider, process.pid, next.depth)
                }
            }

            for child in children[next.pid] ?? [] {
                pending.append((child.pid, next.depth + 1))
            }
        }

        return bestMatch.map { ($0.provider, $0.processID) }
    }

    private static func output(executable: String, arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

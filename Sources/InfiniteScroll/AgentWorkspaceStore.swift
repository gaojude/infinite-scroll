import AppKit
import Combine
import Foundation

/// Owns the Agent queue independently from `PanelStore`. Keeping this state in
/// its own file lets older workspaces and concurrent layout changes continue to
/// use their existing persistence schema unchanged.
final class AgentWorkspaceStore: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published private(set) var runs: [UUID: AgentRun] = [:]
    @Published var isQueueVisible: Bool = true

    private weak var panelStore: PanelStore?
    private var statusTimer: Timer?
    private var monitoringStartedAt: Date?
    private var refreshInFlight = false
    private var cancellables: Set<AnyCancellable> = []
    private var terminationObserver: Any?

    /// Process-tree observation can verify that an agent is still alive, but it
    /// cannot infer semantic task progress. Refresh this heartbeat at a modest
    /// cadence so the UI and persisted state never look frozen.
    private static let observationHeartbeatInterval: TimeInterval = 15

    init() {
        let saved = AgentWorkspacePersistence.load()
        tasks = saved?.tasks ?? []
        isQueueVisible = saved?.isQueueVisible ?? true
        for run in saved?.runs ?? [] {
            runs[run.cellID] = run
        }

        $tasks
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        $runs
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        $isQueueVisible
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancellables.removeAll()
            self?.save()
        }
    }

    deinit {
        statusTimer?.invalidate()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func attach(to store: PanelStore) {
        guard panelStore !== store else { return }
        panelStore = store
        startMonitoring()
    }

    func addTask(title: String, provider: AgentProvider) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }
        tasks.append(AgentTask(title: trimmed, provider: provider))
    }

    /// The only automatic launch path. It creates a run record before sending
    /// the command, which makes a provider started by the app "confirmed" even
    /// before process-tree scanning reports its PID.
    func startTask(_ taskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[taskIndex].state == .pending,
              !taskHasOccupyingRun(tasks[taskIndex]),
              let launchArguments = tasks[taskIndex].provider.launchArguments(for: tasks[taskIndex].title),
              let target = terminalForNewRun()
        else {
            NSSound.beep()
            return
        }

        let now = Date()
        let run = AgentRun(
            cellID: target.id,
            taskID: taskID,
            provider: tasks[taskIndex].provider,
            state: .starting,
            detectionSource: .managedLauncher,
            confidence: .confirmed,
            startedAt: now,
            lastActivityAt: now,
            statusMessage: "Launching \(tasks[taskIndex].provider.displayName)"
        )
        runs[target.id] = run

        tasks[taskIndex].state = .starting
        tasks[taskIndex].assignedCellID = target.id
        tasks[taskIndex].runID = run.id
        tasks[taskIndex].statusMessage = "Starting \(tasks[taskIndex].provider.displayName)"
        tasks[taskIndex].updatedAt = now

        let shellCommand = "cd -- \(shellQuote(target.cwd)) && \(launchArguments.map(shellQuote).joined(separator: " "))"
        sendLaunchCommand(
            session: TmuxManager.sessionName(for: target.id),
            runID: run.id,
            taskID: taskID,
            command: shellCommand,
            attempt: 0
        )
    }

    func retryTask(_ taskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let previousCellID = tasks[taskIndex].assignedCellID
        if taskHasOccupyingRun(tasks[taskIndex]) {
            tasks[taskIndex].state = .blocked
            tasks[taskIndex].statusMessage = "Agent process is still running; focus it before retrying"
            tasks[taskIndex].updatedAt = Date()
            return
        }
        tasks[taskIndex].state = .pending
        tasks[taskIndex].assignedCellID = nil
        tasks[taskIndex].runID = nil
        tasks[taskIndex].statusMessage = nil
        tasks[taskIndex].updatedAt = Date()
        if let previousCellID,
           runs[previousCellID]?.taskID == taskID,
           runs[previousCellID]?.state.occupiesTerminal != true {
            runs.removeValue(forKey: previousCellID)
        }
    }

    func updateTask(_ taskID: UUID, state: AgentTaskState) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[taskIndex].state = state
        tasks[taskIndex].updatedAt = Date()

        switch state {
        case .waiting:
            tasks[taskIndex].statusMessage = "Waiting for input or a dependency"
            updateRun(for: tasks[taskIndex], state: .waitingForUser)
        case .blocked:
            tasks[taskIndex].statusMessage = "Blocked — needs review"
            updateRun(for: tasks[taskIndex], state: .waitingForApproval)
        case .completed:
            tasks[taskIndex].statusMessage = "Marked complete"
        case .failed:
            tasks[taskIndex].statusMessage = "Marked failed"
            updateRun(for: tasks[taskIndex], state: .failed)
        case .cancelled:
            tasks[taskIndex].statusMessage = "Cancelled"
        case .pending, .starting, .running:
            tasks[taskIndex].statusMessage = nil
        }
    }

    func removeTask(_ taskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let cellID = tasks[taskIndex].assignedCellID
        tasks.remove(at: taskIndex)
        if let cellID,
           runs[cellID]?.taskID == taskID,
           runs[cellID]?.state.occupiesTerminal != true {
            runs.removeValue(forKey: cellID)
        }
    }

    func overrideProvider(for taskID: UUID, provider: AgentProvider) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[taskIndex].provider = provider
        tasks[taskIndex].updatedAt = Date()

        guard let cellID = tasks[taskIndex].assignedCellID,
              var run = runs[cellID]
        else { return }
        run.provider = provider
        run.detectionSource = .manual
        run.confidence = .confirmed
        run.lastActivityAt = Date()
        runs[cellID] = run
    }

    func focus(task: AgentTask) {
        guard let cellID = task.assignedCellID else { return }
        focus(cellID: cellID)
    }

    func focus(run: AgentRun) {
        focus(cellID: run.cellID)
    }

    /// Returns the live working directory of the terminal associated with a
    /// run. The queue deliberately stores only a cell ID, so the path always
    /// follows a terminal after the user changes directory.
    func workingDirectory(for run: AgentRun) -> String? {
        guard let panelStore else { return nil }
        for panel in panelStore.panels {
            if let cell = panel.cells.first(where: { $0.id == run.cellID }) {
                return cell.cwd
            }
        }
        return nil
    }

    // MARK: - Managed launch

    private func terminalForNewRun() -> CellModel? {
        guard let store = panelStore else { return nil }
        // A process being present does not prove that an existing terminal is
        // at a shell prompt. Always create a dedicated worker so a launch can
        // never type into a user's editor, REPL, or unrelated long-running job.
        store.addPanel()
        guard store.focusedRow < store.panels.count else { return nil }
        return store.panels[store.focusedRow].cells.first(where: { $0.type == .terminal })
    }

    private func sendLaunchCommand(
        session: String,
        runID: UUID,
        taskID: UUID,
        command: String,
        attempt: Int
    ) {
        let delay: TimeInterval = attempt == 0 ? 0.4 : 0.6
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            _ = TmuxManager.run(["send-keys", "-t", session, "-X", "cancel"])
            let sentText = TmuxManager.run(["send-keys", "-t", session, "-l", command])
            let sentEnter = sentText && TmuxManager.run(["send-keys", "-t", session, "Enter"])

            DispatchQueue.main.async {
                guard let self,
                      let cellID = self.runs.first(where: { $0.value.id == runID })?.key,
                      self.runs[cellID]?.taskID == taskID
                else { return }

                if sentEnter {
                    var run = self.runs[cellID]!
                    run.statusMessage = "Command sent; waiting for process"
                    run.lastActivityAt = Date()
                    self.runs[cellID] = run
                    if let taskIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                        self.tasks[taskIndex].statusMessage = "Command sent; waiting for process"
                        self.tasks[taskIndex].updatedAt = Date()
                    }
                } else if attempt < 4 {
                    self.sendLaunchCommand(
                        session: session,
                        runID: runID,
                        taskID: taskID,
                        command: command,
                        attempt: attempt + 1
                    )
                } else {
                    self.markLaunchFailure(
                        runID: runID,
                        taskID: taskID,
                        message: "Could not reach the tmux pane"
                    )
                }
            }
        }
    }

    // MARK: - Process observation

    private func startMonitoring() {
        guard statusTimer == nil else { return }
        monitoringStartedAt = Date()
        refreshStatuses()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshStatuses() {
        guard !refreshInFlight, let panelStore else { return }
        let terminalIDs = panelStore.panels.flatMap { panel in
            panel.cells.compactMap { $0.type == .terminal ? $0.id : nil }
        }
        refreshInFlight = true
        AgentProcessInspector.refresh(cellIDs: terminalIDs) { [weak self] observations in
            guard let self else { return }
            self.refreshInFlight = false
            self.apply(observations: observations, terminalIDs: Set(terminalIDs))
        }
    }

    private func apply(observations: [AgentProcessObservation], terminalIDs: Set<UUID>) {
        let byCell = Dictionary(uniqueKeysWithValues: observations.map { ($0.cellID, $0) })
        let now = Date()

        for observation in observations {
            if var run = runs[observation.cellID] {
                // Preserve an explicit manual correction over a best-effort scan.
                guard run.detectionSource != .manual || run.provider == observation.provider else {
                    continue
                }
                let acceptsDetectedState = run.detectionSource != .manual
                let stateChanged = acceptsDetectedState && run.state != observation.state
                let processChanged = run.provider != observation.provider ||
                    run.processID != observation.processID ||
                    stateChanged
                let shouldRefreshHeartbeat = run.state.occupiesTerminal &&
                    now.timeIntervalSince(run.lastActivityAt) >= Self.observationHeartbeatInterval
                if processChanged || shouldRefreshHeartbeat {
                    run.provider = observation.provider
                    run.processID = observation.processID
                    if acceptsDetectedState {
                        run.state = observation.state
                        run.statusMessage = observation.statusMessage
                    }
                    run.lastActivityAt = now
                    if run.detectionSource == .processTree {
                        run.confidence = .likely
                    }
                    runs[observation.cellID] = run
                }
                switch acceptsDetectedState ? observation.state : run.state {
                case .waitingForUser, .waitingForApproval:
                    markTaskWaitingIfNeeded(runID: run.id, message: observation.statusMessage)
                default:
                    markTaskRunningIfNeeded(runID: run.id, message: observation.statusMessage)
                }
            } else {
                runs[observation.cellID] = AgentRun(
                    cellID: observation.cellID,
                    provider: observation.provider,
                    state: observation.state,
                    detectionSource: .processTree,
                    confidence: .likely,
                    processID: observation.processID,
                    statusMessage: observation.statusMessage
                )
            }
        }

        for (cellID, run) in Array(runs) where terminalIDs.contains(cellID) && byCell[cellID] == nil {
            guard run.state.occupiesTerminal else { continue }
            if let monitoringStartedAt, now.timeIntervalSince(monitoringStartedAt) < 8 {
                continue
            }
            if run.state == .starting, now.timeIntervalSince(run.startedAt) < 10 {
                continue
            }

            var ended = run
            ended.state = run.detectionSource == .managedLauncher ? .failed : .stopped
            ended.processID = nil
            ended.lastActivityAt = now
            ended.statusMessage = "Agent process is no longer present"
            runs[cellID] = ended

            if let taskID = ended.taskID {
                markTaskBlockedIfActive(
                    taskID,
                    message: "Agent process ended; confirm the result before completing"
                )
            }
        }

        for (cellID, run) in Array(runs) where !terminalIDs.contains(cellID) {
            runs.removeValue(forKey: cellID)
            if let taskID = run.taskID {
                markTaskBlockedIfActive(taskID, message: "Assigned terminal was closed")
            }
        }
    }

    private func markLaunchFailure(runID: UUID, taskID: UUID, message: String) {
        guard let cellID = runs.first(where: { $0.value.id == runID })?.key,
              var run = runs[cellID]
        else { return }
        run.state = .failed
        run.statusMessage = message
        run.lastActivityAt = Date()
        runs[cellID] = run
        markTaskBlockedIfActive(taskID, message: message)
    }

    private func markTaskRunningIfNeeded(runID: UUID, message: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.runID == runID }),
              tasks[taskIndex].state == .starting ||
                tasks[taskIndex].state == .pending ||
                tasks[taskIndex].state == .blocked ||
                tasks[taskIndex].state == .waiting
        else { return }
        tasks[taskIndex].state = .running
        tasks[taskIndex].statusMessage = message
        tasks[taskIndex].updatedAt = Date()
    }

    private func markTaskWaitingIfNeeded(runID: UUID, message: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.runID == runID }),
              !tasks[taskIndex].state.isTerminal
        else { return }
        guard tasks[taskIndex].state != .waiting || tasks[taskIndex].statusMessage != message else {
            return
        }
        tasks[taskIndex].state = .waiting
        tasks[taskIndex].statusMessage = message
        tasks[taskIndex].updatedAt = Date()
    }

    private func markTaskBlockedIfActive(_ taskID: UUID, message: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              !tasks[taskIndex].state.isTerminal
        else { return }
        tasks[taskIndex].state = .blocked
        tasks[taskIndex].statusMessage = message
        tasks[taskIndex].updatedAt = Date()
    }

    private func updateRun(for task: AgentTask, state: AgentRunState) {
        guard let cellID = task.assignedCellID, var run = runs[cellID] else { return }
        run.state = state
        run.lastActivityAt = Date()
        runs[cellID] = run
    }

    private func taskHasOccupyingRun(_ task: AgentTask) -> Bool {
        guard let cellID = task.assignedCellID,
              let run = runs[cellID],
              run.taskID == task.id
        else { return false }
        return run.state.occupiesTerminal
    }

    private func focus(cellID: UUID) {
        guard let panelStore else { return }
        for (rowIndex, panel) in panelStore.panels.enumerated() {
            if let cellIndex = panel.cells.firstIndex(where: { $0.id == cellID }) {
                panelStore.focusedRow = rowIndex
                panelStore.focusedCell = cellIndex
                panelStore.cliFocusCell(rowIdx: rowIndex, cellIdx: cellIndex)
                return
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func save() {
        AgentWorkspacePersistence.save(
            AgentWorkspaceState(
                tasks: tasks,
                runs: Array(runs.values),
                isQueueVisible: isQueueVisible
            )
        )
    }
}

private struct AgentWorkspaceState: Codable {
    let tasks: [AgentTask]
    let runs: [AgentRun]
    let isQueueVisible: Bool
}

private enum AgentWorkspacePersistence {
    private static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".infinite-scroll")
    private static let fileURL = directoryURL.appendingPathComponent("agent-state.json")

    static func load() -> AgentWorkspaceState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AgentWorkspaceState.self, from: data)
    }

    static func save(_ state: AgentWorkspaceState) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[AgentWorkspaceStore] failed to save: \(error)")
        }
    }
}

import SwiftUI

struct AgentQueueView: View {
    @ObservedObject var agentStore: AgentWorkspaceStore
    @State private var newTaskTitle = ""
    @State private var newTaskProvider: AgentProvider = .codex

    private var activeTasks: [AgentTask] {
        agentStore.tasks
            .filter { !$0.state.isTerminal }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var finishedTasks: [AgentTask] {
        agentStore.tasks
            .filter(\.state.isTerminal)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var unassignedRuns: [AgentRun] {
        agentStore.runs.values
            .filter { $0.taskID == nil }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            composer
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    taskSection("In progress", tasks: activeTasks)

                    if !unassignedRuns.isEmpty {
                        runSection
                    }

                    if !finishedTasks.isEmpty {
                        taskSection("Recent", tasks: finishedTasks)
                    }

                    if activeTasks.isEmpty && unassignedRuns.isEmpty && finishedTasks.isEmpty {
                        emptyState
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.panelBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.accent)

            Text("Agent Queue")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)

            if activeRunCount > 0 {
                Text("\(activeRunCount)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }

            Spacer()

            Button {
                agentStore.isQueueVisible = false
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Hide Agent Queue")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a task…", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit(addTask)

                Button(action: addTask) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.addButton)
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add pending task")
            }

            Picker("Provider", selection: $newTaskProvider) {
                ForEach(AgentProvider.launchable) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .font(.system(size: 10, design: .monospaced))
        }
        .padding(12)
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [AgentTask]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)

                ForEach(tasks) { task in
                    AgentTaskRow(task: task, agentStore: agentStore)
                }
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("DETECTED AGENTS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            ForEach(unassignedRuns) { run in
                Button {
                    agentStore.focus(run: run)
                } label: {
                    HStack(spacing: 8) {
                        AgentStatusBadge(run: run, compact: true)
                        Spacer()
                        Text(run.confidence.rawValue)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(9)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Focus detected agent")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 22))
                .foregroundColor(Theme.textSecondary)
            Text("Queue work, then start it in a worker terminal.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var activeRunCount: Int {
        agentStore.runs.values.filter(\.state.occupiesTerminal).count
    }

    private func addTask() {
        let title = newTaskTitle
        agentStore.addTask(title: title, provider: newTaskProvider)
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newTaskTitle = ""
        }
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask
    @ObservedObject var agentStore: AgentWorkspaceStore

    private var assignedRun: AgentRun? {
        task.assignedCellID.flatMap { agentStore.runs[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(AgentVisuals.color(for: task.state))
                    .frame(width: 7, height: 7)

                Text(task.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Menu {
                    Menu("Provider") {
                        ForEach(AgentProvider.launchable) { provider in
                            Button(provider.displayName) {
                                agentStore.overrideProvider(for: task.id, provider: provider)
                            }
                        }
                    }

                    if !task.state.isTerminal {
                        Button("Mark waiting") {
                            agentStore.updateTask(task.id, state: .waiting)
                        }
                        Button("Mark blocked") {
                            agentStore.updateTask(task.id, state: .blocked)
                        }
                        Button("Mark complete") {
                            agentStore.updateTask(task.id, state: .completed)
                        }
                        Divider()
                        Button("Cancel task") {
                            agentStore.updateTask(task.id, state: .cancelled)
                        }
                    } else {
                        Button("Retry") {
                            agentStore.retryTask(task.id)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            agentStore.removeTask(task.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text(task.provider.displayName)
                Text("·")
                Text(task.state.displayName)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(AgentVisuals.color(for: task.state))

            if let message = task.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                taskAction
                if task.assignedCellID != nil {
                    Button("Focus") {
                        agentStore.focus(task: task)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.accent)
                }
            }
        }
        .padding(9)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var taskAction: some View {
        switch task.state {
        case .pending:
            Button("Start") {
                agentStore.startTask(task.id)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.addButton)
        case .blocked:
            if assignedRun?.state.occupiesTerminal == true {
                EmptyView()
            } else {
                Button("Retry") {
                    agentStore.retryTask(task.id)
                    agentStore.startTask(task.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.addButton)
            }
        case .failed:
            if assignedRun?.state.occupiesTerminal == true {
                EmptyView()
            } else {
                Button("Retry") {
                    agentStore.retryTask(task.id)
                    agentStore.startTask(task.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.addButton)
            }
        case .starting, .running, .waiting, .completed, .cancelled:
            EmptyView()
        }
    }
}

struct AgentStatusBadge: View {
    let run: AgentRun
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(AgentVisuals.color(for: run.state))
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(run.provider.displayName)
            if !compact {
                Text("·")
                Text(run.state.displayName)
            }
        }
        .font(.system(size: compact ? 10 : 9, weight: .semibold, design: .monospaced))
        .foregroundColor(compact ? Theme.text : .white.opacity(0.92))
        .padding(.horizontal, compact ? 0 : 7)
        .padding(.vertical, compact ? 0 : 4)
        .background {
            if !compact {
                Color.black.opacity(0.74)
                    .clipShape(Capsule())
            }
        }
        .help("\(run.provider.displayName) · \(run.state.displayName) · \(run.confidence.rawValue)")
    }
}

enum AgentVisuals {
    static func color(for state: AgentRunState) -> Color {
        switch state {
        case .starting: Theme.accent
        case .working: Theme.addButton
        case .waitingForUser, .waitingForApproval: .orange
        case .idle, .unknown: Theme.textSecondary
        case .stopped: .gray
        case .failed: Theme.closeButton
        }
    }

    static func color(for state: AgentTaskState) -> Color {
        switch state {
        case .pending: Theme.textSecondary
        case .starting: Theme.accent
        case .running: Theme.addButton
        case .waiting, .blocked: .orange
        case .completed: .green
        case .failed: Theme.closeButton
        case .cancelled: .gray
        }
    }
}

import Foundation

// MARK: - Agent identity

/// The coding-agent executables Infinite Scroll can launch or recognize from a
/// tmux pane's process tree. `unknown` is deliberately kept separate from a
/// shell: an unrecognized process is not evidence that it is idle or finished.
enum AgentProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case codex
    case claude
    case gemini
    case aider
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .aider: "Aider"
        case .unknown: "Unknown"
        }
    }

    /// Only known providers appear in the new-task launcher picker.
    static let launchable: [AgentProvider] = [.codex, .claude, .gemini, .aider]

    /// Arguments for an interactive provider launch. Aider is the exception:
    /// its positional arguments are file paths, so a queue task must use its
    /// documented one-shot message flag instead.
    func launchArguments(for task: String) -> [String]? {
        switch self {
        case .codex: ["codex", task]
        case .claude: ["claude", task]
        case .gemini: ["gemini", task]
        case .aider: ["aider", "--no-auto-commits", "--message", task]
        case .unknown: nil
        }
    }

    /// Detect only the executable or well-known package path. We intentionally
    /// do not search arbitrary task text, terminal output, or process
    /// environments because those are both unreliable and privacy-sensitive.
    static func detect(executable: String, arguments: String) -> AgentProvider? {
        let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let normalizedArgs = arguments.lowercased()

        if executableName == "codex" || executableName == "codex-cli" ||
            normalizedArgs.contains("@openai/codex") || normalizedArgs.contains("/codex-cli/") {
            return .codex
        }
        if executableName == "claude" || executableName == "claude-code" ||
            normalizedArgs.contains("@anthropic-ai/claude-code") || normalizedArgs.contains("/claude-code/") {
            return .claude
        }
        if executableName == "gemini" || executableName == "gemini-cli" ||
            normalizedArgs.contains("@google/gemini-cli") || normalizedArgs.contains("/gemini-cli/") {
            return .gemini
        }
        if executableName == "aider" || executableName == "aider-chat" ||
            normalizedArgs.contains("/aider/") || normalizedArgs.contains("/aider-chat") {
            return .aider
        }
        return nil
    }
}

enum AgentRunState: String, Codable, CaseIterable {
    case starting
    case working
    case waitingForUser
    case waitingForApproval
    case idle
    case stopped
    case failed
    case unknown

    var displayName: String {
        switch self {
        case .starting: "Starting"
        case .working: "Running"
        case .waitingForUser: "Asking"
        case .waitingForApproval: "Approval"
        case .idle: "Idle"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }

    var occupiesTerminal: Bool {
        switch self {
        case .starting, .working, .waitingForUser, .waitingForApproval:
            true
        case .idle, .stopped, .failed, .unknown:
            false
        }
    }
}

enum AgentDetectionSource: String, Codable {
    case managedLauncher
    case processTree
    case manual
}

enum AgentDetectionConfidence: String, Codable {
    case confirmed
    case likely
    case unknown
}

// MARK: - Task queue

enum AgentTaskState: String, Codable, CaseIterable {
    case pending
    case starting
    case running
    case waiting
    case blocked
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .starting: "Starting"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .pending, .starting, .running, .waiting, .blocked:
            false
        }
    }
}

struct AgentTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var provider: AgentProvider
    var state: AgentTaskState
    var assignedCellID: UUID?
    var runID: UUID?
    var statusMessage: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        provider: AgentProvider,
        state: AgentTaskState = .pending,
        assignedCellID: UUID? = nil,
        runID: UUID? = nil,
        statusMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.state = state
        self.assignedCellID = assignedCellID
        self.runID = runID
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AgentRun: Identifiable, Codable, Equatable {
    let id: UUID
    var cellID: UUID
    var taskID: UUID?
    var provider: AgentProvider
    var state: AgentRunState
    var detectionSource: AgentDetectionSource
    var confidence: AgentDetectionConfidence
    var processID: Int32?
    let startedAt: Date
    var lastActivityAt: Date
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        cellID: UUID,
        taskID: UUID? = nil,
        provider: AgentProvider,
        state: AgentRunState,
        detectionSource: AgentDetectionSource,
        confidence: AgentDetectionConfidence,
        processID: Int32? = nil,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        statusMessage: String? = nil
    ) {
        self.id = id
        self.cellID = cellID
        self.taskID = taskID
        self.provider = provider
        self.state = state
        self.detectionSource = detectionSource
        self.confidence = confidence
        self.processID = processID
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.statusMessage = statusMessage
    }
}

/// A deliberately small, privacy-preserving process observation. It retains a
/// derived state and message, never the command, terminal output, prompt, or
/// environment variable used to infer them.
struct AgentProcessObservation: Equatable {
    let cellID: UUID
    let provider: AgentProvider
    let processID: Int32
    let state: AgentRunState
    let statusMessage: String
}

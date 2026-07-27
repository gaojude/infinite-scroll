import AppKit
import SwiftUI

struct AgentQueueView: View {
    @ObservedObject var agentStore: AgentWorkspaceStore
    private static let recentStoppedRunInterval: TimeInterval = 10 * 60

    /// Keep attention-requiring and active agents first. Stopped agents are
    /// retained briefly for context, then naturally leave this live view.
    private var visibleRuns: [AgentRun] {
        let recentCutoff = Date().addingTimeInterval(-Self.recentStoppedRunInterval)
        return agentStore.runs.values
            .filter { $0.state != .stopped || $0.lastActivityAt >= recentCutoff }
            .sorted { lhs, rhs in
                let lhsPriority = Self.priority(for: lhs.state)
                let rhsPriority = Self.priority(for: rhs.state)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !visibleRuns.isEmpty {
                        runSection
                    } else {
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

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("AGENT ACTIVITY")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            ForEach(visibleRuns) { run in
                AgentRunRow(run: run, agentStore: agentStore)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 22))
                .foregroundColor(Theme.textSecondary)
            Text("No agents detected in this workspace.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Start an agent in any terminal and it will appear here automatically.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var activeRunCount: Int {
        agentStore.runs.values.filter(\.state.occupiesTerminal).count
    }

    private static func priority(for state: AgentRunState) -> Int {
        switch state {
        case .waitingForUser, .waitingForApproval, .failed:
            0
        case .starting, .working:
            1
        case .idle, .unknown:
            2
        case .stopped:
            3
        }
    }
}

/// An agent run is a navigational row: its left side answers “where?” and
/// its trailing status chip answers “what is it doing now?”. Clicking anywhere
/// in the row takes the user to that terminal; the context menu exposes the
/// secondary path action without competing with the primary navigation.
private struct AgentRunRow: View {
    let run: AgentRun
    @ObservedObject var agentStore: AgentWorkspaceStore
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var workingDirectory: String? {
        agentStore.workingDirectory(for: run)
    }

    private var pathLabel: String {
        workingDirectory ?? "Path unavailable"
    }

    var body: some View {
        Button {
            agentStore.focus(run: run)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 12)

                    Text(pathLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(workingDirectory == nil ? Theme.textSecondary : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                AgentRunStatusChip(run: run)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(8)
            .background(isHovering ? Theme.headerBackground : Theme.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isHovering ? Theme.focusBorder.opacity(0.65) : Theme.border.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .help(helpText)
        .contextMenu {
            Button("Focus terminal") {
                agentStore.focus(run: run)
            }
            Button("Copy Path") {
                guard let workingDirectory else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workingDirectory, forType: .string)
            }
            .disabled(workingDirectory == nil)
        }
        .accessibilityLabel("Detected \(run.provider.displayName) agent")
        .accessibilityValue("\(pathLabel), \(run.state.displayName)")
        .accessibilityHint("Focuses the associated terminal. Open the context menu to copy its path.")
        .accessibilityElement(children: .ignore)
    }

    private var helpText: String {
        var details = [
            "Path: \(pathLabel)",
            "Provider: \(run.provider.displayName)",
            "Status: \(run.state.displayName)",
            "Last observed: \(run.lastActivityAt.formatted(date: .omitted, time: .standard))",
            "Detection: \(run.confidence.rawValue)",
            "Click to focus the terminal."
        ]
        if let message = run.statusMessage, !message.isEmpty {
            details.insert(message, at: 4)
        }
        return details.joined(separator: "\n")
    }
}

private struct AgentRunStatusChip: View {
    let run: AgentRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        AgentVisuals.color(for: run.state)
    }

    var body: some View {
        HStack(spacing: 5) {
            statusSymbol
            Text(run.state.displayName)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.45), lineWidth: 1)
        )
        .accessibilityLabel("Agent status")
        .accessibilityValue(run.state.displayName)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch run.state {
        case .starting, .working:
            if reduceMotion {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
                    .frame(width: 10, height: 10)
            }
        case .waitingForUser:
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
        case .waitingForApproval:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
        case .idle:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundColor(color)
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

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PanelStore
    @StateObject private var agentStore = AgentWorkspaceStore()

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkspaceLayout(
                size: proxy.size,
                isQueueVisible: agentStore.isQueueVisible
            )

            ZStack {
                HStack(spacing: 0) {
                    terminalWorkspace
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if !agentStore.isQueueVisible {
                                HStack {
                                    Spacer(minLength: 0)

                                    Button {
                                        agentStore.isQueueVisible = true
                                    } label: {
                                        if layout.isCompact {
                                            Image(systemName: "sidebar.right")
                                                .font(.system(size: 12, weight: .semibold))
                                                .frame(width: 28, height: 28)
                                        } else {
                                            Label("Show Agent Queue", systemImage: "sidebar.right")
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Show Agent Queue")

                                    Spacer(minLength: 0)
                                }
                                .frame(height: layout.collapsedQueueControlHeight)
                                .background(Theme.background)
                            }
                        }

                    if layout.showsSidebarQueue {
                        Divider()
                        AgentQueueView(agentStore: agentStore)
                            .frame(width: layout.sidebarQueueWidth)
                            .frame(maxHeight: .infinity)
                    }
                }

                if layout.showsOverlayQueue {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        AgentQueueView(agentStore: agentStore)
                            .frame(width: layout.overlayQueueWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.panelCornerRadius)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.42), radius: 16, x: -4, y: 0)

                    }
                    .padding(Theme.panelSpacing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }

                if store.showWorkspaceSearch {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            WorkspaceFindBar(maximumWidth: layout.searchWidth)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, layout.searchTopInset)
                    .padding(.leading, Theme.panelSpacing)
                    .padding(.trailing, layout.searchTrailingInset)
                    .zIndex(2)
                }

                if store.showHelp {
                    HelpOverlay(isPresented: $store.showHelp)
                        .zIndex(3)
                }
            }
        }
        .onAppear { agentStore.attach(to: store) }
    }

    private var terminalWorkspace: some View {
        ZStack {
            CmdScrollView(commandScrollSpeed: store.commandScrollSpeed) {
                VStack(spacing: 0) {
                    ForEach(Array(store.panels.enumerated()), id: \.element.id) { index, panel in
                        RowView(
                            panel: panel,
                            fontSize: store.fontSize,
                            fontName: store.fontName,
                            rowHeight: store.rowHeight,
                            focusedCellID: store.focusedCellID,
                            agentRuns: agentStore.runs,
                            isNewlyInserted: panel.id == store.newlyAddedPanelID,
                            onRename: { store.renameRow(id: panel.id) },
                            onClose: { store.removePanel(id: panel.id) }
                        )
                        .padding(
                            .bottom,
                            rowSpacing(after: panel, at: index, total: store.panels.count)
                        )
                    }
                }
                .padding(Theme.panelSpacing)
            }
            .background(Theme.background)

            if store.panels.isEmpty {
                EmptyTerminalState {
                    store.addPanel()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func rowSpacing(after panel: PanelModel, at index: Int, total: Int) -> CGFloat {
        guard index < total - 1 else { return 0 }
        return panel.isMaster ? Theme.masterSectionSpacing : Theme.panelSpacing
    }
}

private struct WorkspaceLayout {
    private static let compactWidth: CGFloat = 960
    private static let preferredQueueWidth: CGFloat = 330
    private static let minimumQueueWidth: CGFloat = 280
    private static let collapsedQueueControlHeight: CGFloat = 44
    private static let preferredSearchWidth: CGFloat = 520

    let size: CGSize
    let isQueueVisible: Bool

    var isCompact: Bool {
        size.width < Self.compactWidth
    }

    var showsSidebarQueue: Bool {
        isQueueVisible && !isCompact
    }

    var showsOverlayQueue: Bool {
        isQueueVisible && isCompact
    }

    var sidebarQueueWidth: CGFloat {
        min(
            Self.preferredQueueWidth,
            max(Self.minimumQueueWidth, size.width * 0.28)
        )
    }

    var overlayQueueWidth: CGFloat {
        min(
            Self.preferredQueueWidth,
            max(0, size.width - Theme.panelSpacing * 2)
        )
    }

    var collapsedQueueControlHeight: CGFloat {
        isQueueVisible ? 0 : Self.collapsedQueueControlHeight
    }

    var searchWidth: CGFloat {
        let sidebarReservation = showsSidebarQueue
            ? sidebarQueueWidth + Theme.panelSpacing
            : 0
        let availableWidth = size.width - Theme.panelSpacing * 2 - sidebarReservation
        return min(Self.preferredSearchWidth, max(0, availableWidth))
    }

    var searchTopInset: CGFloat {
        Theme.panelSpacing + collapsedQueueControlHeight
    }

    var searchTrailingInset: CGFloat {
        Theme.panelSpacing + (showsSidebarQueue ? sidebarQueueWidth + Theme.panelSpacing : 0)
    }
}

private struct EmptyTerminalState: View {
    let createTerminal: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            Text("No terminals open")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)

            Button(action: createTerminal) {
                Label("New Terminal", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)

            Text("or press ⌘ ⇧ ↓")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

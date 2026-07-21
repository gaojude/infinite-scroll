import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PanelStore

    var body: some View {
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

            if store.showHelp {
                HelpOverlay(isPresented: $store.showHelp)
            }

            if store.showWorkspaceSearch {
                VStack {
                    HStack {
                        Spacer()
                        WorkspaceFindBar()
                    }
                    Spacer()
                }
                .padding(.top, Theme.panelSpacing)
                .padding(.trailing, Theme.panelSpacing)
            }
        }
    }

    private func rowSpacing(after panel: PanelModel, at index: Int, total: Int) -> CGFloat {
        guard index < total - 1 else { return 0 }
        return panel.isMaster ? Theme.masterSectionSpacing : Theme.panelSpacing
    }
}

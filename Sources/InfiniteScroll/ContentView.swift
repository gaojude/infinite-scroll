import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PanelStore

    var body: some View {
        ZStack {
            CmdScrollView {
                VStack(spacing: Theme.panelSpacing) {
                    ForEach(Array(store.panels.enumerated()), id: \.element.id) { index, panel in
                        RowView(
                            panel: panel,
                            index: index + 1,
                            fontSize: store.fontSize,
                            fontName: store.fontName,
                            rowHeight: store.rowHeight,
                            focusedCellID: store.focusedCellID,
                            onClose: { store.removePanel(id: panel.id) }
                        )
                    }
                }
                .padding(Theme.panelSpacing)
            }
            .background(Theme.background)

            if store.showHelp {
                HelpOverlay(isPresented: $store.showHelp)
            }
        }
    }
}

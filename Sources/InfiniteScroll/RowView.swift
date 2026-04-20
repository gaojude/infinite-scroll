import SwiftUI

struct RowView: View {
    @ObservedObject var panel: PanelModel
    let index: Int
    let fontSize: CGFloat
    let fontName: String
    let focusedCellID: UUID?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(panel.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.text)

                Spacer()

                Button(action: { panel.toggleNotes() }) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(panel.showNotes ? Theme.focusBorder : Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.arrow.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.headerHeight)
            .background(Theme.headerBackground)

            // Dynamic cells — equal width
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(panel.cells.enumerated()), id: \.element.id) { idx, cell in
                        if idx > 0 {
                            Rectangle()
                                .fill(Theme.border)
                                .frame(width: 1)
                        }
                        CellView(cell: cell, fontSize: fontSize, fontName: fontName)
                            .frame(width: cellWidth(total: geo.size.width))
                            .overlay(
                                Rectangle()
                                    .stroke(
                                        focusedCellID == cell.id ? Theme.focusBorder : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                }
            }
            .frame(height: Theme.panelHeight - Theme.headerHeight)
        }
        .frame(height: Theme.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func cellWidth(total: CGFloat) -> CGFloat {
        guard panel.cells.count > 0 else { return 0 }
        let count = CGFloat(panel.cells.count)
        let dividers = CGFloat(panel.cells.count - 1)
        return max(0, (total - dividers) / count)
    }

    private var statusColor: Color {
        let anyRunning = panel.cells.contains { $0.type == .terminal && $0.isRunning }
        return anyRunning ? .green : .gray
    }
}

// MARK: - CellView: renders a terminal or notes cell

struct CellView: View {
    @ObservedObject var cell: CellModel
    let fontSize: CGFloat
    let fontName: String

    var body: some View {
        switch cell.type {
        case .terminal:
            TerminalWrapper(
                terminalID: cell.id,
                initialDirectory: cell.cwd,
                fontSize: fontSize,
                fontName: fontName,
                onExit: { _ in cell.isRunning = false },
                onCwdChange: { cwd in cell.cwd = cwd }
            )
        case .notes:
            MarkdownNotesView(
                notesID: cell.id,
                text: $cell.text,
                fontSize: fontSize,
                fontName: fontName
            )
        }
    }
}

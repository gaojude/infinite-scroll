import AppKit
import Foundation
import InfiniteScrollProtocol

extension PanelStore {

    // MARK: - Snapshot

    /// Full snapshot, including an optional master row.
    func snapshot() -> [RowInfo] {
        let focusedID = focusedCellID
        return panels.enumerated().map { rowIdx, panel in
            let cells = panel.cells.enumerated().map { cellIdx, cell in
                CellInfo(
                    id: cell.id.uuidString,
                    ref: "\(rowIdx).\(cellIdx + 1)",
                    index: cellIdx + 1,
                    type: cell.type.rawValue,
                    cwd: cell.type == .terminal ? cell.cwd : nil,
                    isRunning: cell.type == .terminal ? cell.isRunning : nil,
                    focused: cell.id == focusedID
                )
            }
            return RowInfo(
                id: panel.id.uuidString,
                index: rowIdx,
                title: panel.title,
                focused: rowIdx == focusedRow,
                cells: cells
            )
        }
    }

    /// Snapshot visible to the CLI — excludes only rows explicitly marked master.
    func cliVisibleSnapshot() -> [RowInfo] {
        snapshot().filter { info in
            panels.indices.contains(info.index) && !panels[info.index].isMaster
        }
    }

    // MARK: - Reference resolution

    /// Resolve a cell reference (UUID or "row.cell") to array indices.
    /// Row number maps directly to the panels array index.
    func resolveCell(_ ref: String) -> (rowIdx: Int, cellIdx: Int)? {
        if let uuid = UUID(uuidString: ref) {
            for (rowIdx, panel) in panels.enumerated() {
                if let cellIdx = panel.cells.firstIndex(where: { $0.id == uuid }) {
                    return (rowIdx, cellIdx)
                }
            }
            return nil
        }
        let parts = ref.split(separator: ".")
        guard parts.count == 2,
              let row = Int(parts[0]),
              let cell = Int(parts[1]),
              row >= 0, cell >= 1
        else { return nil }
        let rowIdx = row
        let cellIdx = cell - 1
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return nil }
        return (rowIdx, cellIdx)
    }

    /// Resolve a row reference (UUID or integer index).
    func resolveRow(_ ref: String) -> Int? {
        if let uuid = UUID(uuidString: ref) {
            return panels.firstIndex(where: { $0.id == uuid })
        }
        if let idx = Int(ref), idx >= 0, idx < panels.count {
            return idx
        }
        return nil
    }

    /// True if the cell at the given indices belongs to the master row.
    func isMasterCell(rowIdx: Int, cellIdx: Int) -> Bool {
        guard rowIdx < panels.count else { return false }
        return panels[rowIdx].isMaster
    }

    // MARK: - CLI operations

    func cliFocusCell(rowIdx: Int, cellIdx: Int) {
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return }
        focusedRow = rowIdx
        focusedCell = cellIdx
        let cell = panels[rowIdx].cells[cellIdx]
        focusedCellID = cell.id
        switch cell.type {
        case .terminal:
            TerminalViewRegistry.shared.focus(id: cell.id)
        case .notes:
            NotesViewRegistry.shared.focus(id: cell.id)
        }
    }

    func cliAddRow() -> UUID {
        addPanel()
        return panels[focusedRow].id
    }

    func cliAddCell(rowIdx: Int, type: CellType) -> UUID? {
        guard rowIdx < panels.count else { return nil }
        let panel = panels[rowIdx]
        if type == .notes {
            if !panel.cells.contains(where: { $0.type == .notes }) {
                panel.toggleNotes()
            }
            return panel.cells.first(where: { $0.type == .notes })?.id
        }
        // terminal: insert before notes if any, else append
        let cwd = panel.cells.last(where: { $0.type == .terminal })?.cwd ?? NSHomeDirectory()
        let newCell = CellModel(type: .terminal, cwd: cwd)
        let insertIdx: Int
        if let notesIdx = panel.cells.firstIndex(where: { $0.type == .notes }) {
            insertIdx = notesIdx
        } else {
            insertIdx = panel.cells.count
        }
        panel.cells.insert(newCell, at: insertIdx)
        objectWillChange.send()
        return newCell.id
    }

    func cliCloseCell(rowIdx: Int, cellIdx: Int) {
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return }
        let panel = panels[rowIdx]
        let cell = panel.cells[cellIdx]
        if cell.type == .terminal {
            let sessionName = TmuxManager.sessionName(for: cell.id)
            DispatchQueue.global(qos: .utility).async {
                TmuxManager.killSession(sessionName)
            }
        }
        panel.cells.remove(at: cellIdx)
        objectWillChange.send()
        if panel.cells.isEmpty {
            removePanel(id: panel.id)
        }
    }

    func cliWriteNotes(rowIdx: Int, cellIdx: Int, text: String) -> Bool {
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return false }
        let cell = panels[rowIdx].cells[cellIdx]
        guard cell.type == .notes else { return false }
        cell.text = text
        return true
    }

    func cliReadNotes(rowIdx: Int, cellIdx: Int) -> String? {
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return nil }
        let cell = panels[rowIdx].cells[cellIdx]
        guard cell.type == .notes else { return nil }
        return cell.text
    }

    func cliCellAt(rowIdx: Int, cellIdx: Int) -> (CellModel, UUID)? {
        guard rowIdx < panels.count, cellIdx < panels[rowIdx].cells.count else { return nil }
        let panel = panels[rowIdx]
        return (panel.cells[cellIdx], panel.id)
    }
}

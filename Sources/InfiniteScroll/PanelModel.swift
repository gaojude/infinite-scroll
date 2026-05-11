import Foundation

// MARK: - Cell types

enum CellType: String, Codable {
    case terminal
    case notes
}

class CellModel: ObservableObject, Identifiable {
    let id: UUID
    let type: CellType
    @Published var cwd: String
    @Published var text: String
    @Published var isRunning: Bool = true

    init(type: CellType, id: UUID = UUID(), cwd: String? = nil, text: String = "") {
        self.id = id
        self.type = type
        self.cwd = cwd ?? NSHomeDirectory()
        self.text = text
    }
}

// MARK: - Row model

class PanelModel: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var cells: [CellModel]
    /// Persisted notes content — survives toggling notes off/on.
    @Published var notesText: String
    @Published var showNotes: Bool
    /// True for the orchestrator row at index 0. The master is protected
    /// from CLI mutations and cannot be removed.
    let isMaster: Bool

    init(index: Int, id: UUID = UUID(), cells: [CellModel]? = nil,
         notesText: String = "", showNotes: Bool = false, isMaster: Bool = false) {
        self.id = id
        self.isMaster = isMaster
        self.title = isMaster ? "Master · Row #0" : "Row #\(index)"
        self.notesText = notesText
        self.showNotes = showNotes
        if let cells = cells {
            self.cells = cells
        } else {
            // Default: one terminal, no notes
            self.cells = [CellModel(type: .terminal)]
        }
        // If showNotes, ensure a notes cell is present at the end
        if showNotes && !self.cells.contains(where: { $0.type == .notes }) {
            self.cells.append(CellModel(type: .notes, text: notesText))
        }
    }

    /// Toggle the notes cell on/off. Notes content is preserved across toggles.
    func toggleNotes() {
        if let idx = cells.firstIndex(where: { $0.type == .notes }) {
            // Save content and remove
            notesText = cells[idx].text
            cells.remove(at: idx)
            showNotes = false
        } else {
            // Add notes cell at the end
            cells.append(CellModel(type: .notes, text: notesText))
            showNotes = true
        }
    }
}

// MARK: - Codable persistence

struct CellState: Codable {
    let id: String
    let type: CellType
    let cwd: String?
    let text: String?
}

struct PanelState: Codable {
    let id: String
    let title: String
    let cells: [CellState]?
    let notesText: String?
    let showNotes: Bool?
    let isMaster: Bool?
    // Backward compat
    let cwd: String?
    let notes: String?
}

extension CellModel {
    func toState() -> CellState {
        CellState(
            id: id.uuidString,
            type: type,
            cwd: type == .terminal ? cwd : nil,
            text: type == .notes ? text : nil
        )
    }

    static func from(state: CellState) -> CellModel {
        CellModel(
            type: state.type,
            id: UUID(uuidString: state.id) ?? UUID(),
            cwd: state.cwd,
            text: state.text ?? ""
        )
    }
}

extension PanelModel {
    func toState() -> PanelState {
        // When notes cell is visible, persist its latest text as notesText too
        let currentNotesText: String
        if let notesCell = cells.first(where: { $0.type == .notes }) {
            currentNotesText = notesCell.text
        } else {
            currentNotesText = notesText
        }
        return PanelState(
            id: id.uuidString,
            title: title,
            cells: cells.map { $0.toState() },
            notesText: currentNotesText,
            showNotes: showNotes,
            isMaster: isMaster,
            cwd: nil,
            notes: nil
        )
    }

    static func from(state: PanelState, index: Int) -> PanelModel {
        let cells: [CellModel]
        if let cellStates = state.cells, !cellStates.isEmpty {
            // Filter out notes cells from persisted state — toggleNotes() will re-add if needed
            cells = cellStates.compactMap { cellState in
                cellState.type == .notes ? nil : CellModel.from(state: cellState)
            }
        } else {
            // Backward compat: old format had cwd + notes
            cells = [CellModel(type: .terminal, cwd: state.cwd)]
        }
        let isMaster = state.isMaster ?? false
        let model = PanelModel(
            index: index,
            id: UUID(uuidString: state.id) ?? UUID(),
            cells: cells,
            notesText: state.notesText ?? state.notes ?? "",
            showNotes: state.showNotes ?? false,
            isMaster: isMaster
        )
        // Trust the saved title only for non-master rows; master title is canonical.
        if !isMaster {
            model.title = state.title
        }
        return model
    }
}

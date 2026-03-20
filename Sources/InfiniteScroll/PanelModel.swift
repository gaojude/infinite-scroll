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

    init(index: Int, id: UUID = UUID(), cells: [CellModel]? = nil) {
        self.id = id
        self.title = "Row #\(index)"
        self.cells = cells ?? [CellModel(type: .terminal), CellModel(type: .notes)]
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
        PanelState(
            id: id.uuidString,
            title: title,
            cells: cells.map { $0.toState() },
            cwd: nil,
            notes: nil
        )
    }

    static func from(state: PanelState, index: Int) -> PanelModel {
        let cells: [CellModel]
        if let cellStates = state.cells, !cellStates.isEmpty {
            cells = cellStates.map { CellModel.from(state: $0) }
        } else {
            // Backward compat: old format had cwd + notes
            let term = CellModel(type: .terminal, cwd: state.cwd)
            let note = CellModel(type: .notes, text: state.notes ?? "")
            cells = [term, note]
        }
        let model = PanelModel(index: index, id: UUID(uuidString: state.id) ?? UUID(), cells: cells)
        model.title = state.title
        return model
    }
}

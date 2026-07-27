import Foundation

enum WorkspaceSearchMatchKind: Equatable {
    case title
    case directory
    case notes

    var label: String {
        switch self {
        case .title: return "Row name"
        case .directory: return "Folder"
        case .notes: return "Notes"
        }
    }

    var systemImageName: String {
        switch self {
        case .title: return "rectangle.3.group"
        case .directory: return "folder"
        case .notes: return "doc.text"
        }
    }
}

struct WorkspaceSearchResult: Identifiable, Equatable {
    let rowID: UUID
    let cellID: UUID
    let rowTitle: String
    let detail: String
    let matchKind: WorkspaceSearchMatchKind

    var id: UUID { rowID }
}

enum WorkspaceSearch {
    static func results(
        in panels: [PanelModel],
        matching rawQuery: String,
        limit: Int = 50
    ) -> [WorkspaceSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        var matches: [WorkspaceSearchResult] = []
        for (index, panel) in panels.enumerated() {
            guard let defaultCellID = panel.cells.first(where: { $0.type == .terminal })?.id
                ?? panel.cells.first?.id
            else { continue }

            let rowLabel = panel.isMaster ? "Master row" : "Row \(index)"
            if panel.title.localizedCaseInsensitiveContains(query) {
                matches.append(
                    WorkspaceSearchResult(
                        rowID: panel.id,
                        cellID: defaultCellID,
                        rowTitle: panel.title,
                        detail: rowLabel,
                        matchKind: .title
                    )
                )
            } else if let terminal = panel.cells.first(where: {
                $0.type == .terminal && $0.cwd.localizedCaseInsensitiveContains(query)
            }) {
                matches.append(
                    WorkspaceSearchResult(
                        rowID: panel.id,
                        cellID: terminal.id,
                        rowTitle: panel.title,
                        detail: terminal.cwd,
                        matchKind: .directory
                    )
                )
            } else if let notes = panel.cells.first(where: {
                $0.type == .notes && $0.text.localizedCaseInsensitiveContains(query)
            }) {
                matches.append(
                    WorkspaceSearchResult(
                        rowID: panel.id,
                        cellID: notes.id,
                        rowTitle: panel.title,
                        detail: notesPreview(notes.text),
                        matchKind: .notes
                    )
                )
            } else if panel.notesText.localizedCaseInsensitiveContains(query) {
                matches.append(
                    WorkspaceSearchResult(
                        rowID: panel.id,
                        cellID: defaultCellID,
                        rowTitle: panel.title,
                        detail: notesPreview(panel.notesText),
                        matchKind: .notes
                    )
                )
            }

            if matches.count == limit { break }
        }
        return matches
    }

    private static func notesPreview(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 96 else { return collapsed }
        return String(collapsed.prefix(93)) + "..."
    }
}

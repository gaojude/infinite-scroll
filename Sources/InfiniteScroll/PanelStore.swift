import AppKit
import Combine

class PanelStore: ObservableObject {
    @Published var panels: [PanelModel] = []
    @Published var fontSize: CGFloat = 16
    @Published var focusedCellID: UUID?
    @Published var showHelp: Bool = false
    private var nextIndex = 1
    private var autosaveCancellables: Set<AnyCancellable> = []
    private var nestedCancellables: Set<AnyCancellable> = []
    private var terminationObserver: Any?
    private var clickMonitor: Any?

    // Focus tracking: row index + cell index within that row
    private(set) var focusedRow: Int = 0
    private(set) var focusedCell: Int = 0

    init() {
        let saved = PersistenceManager.load()
        if let saved = saved, !saved.panels.isEmpty {
            nextIndex = saved.nextIndex
            fontSize = saved.fontSize ?? 16
            for (i, state) in saved.panels.enumerated() {
                panels.append(PanelModel.from(state: state, index: i + 1))
            }
            print("[InfiniteScroll] Restored \(saved.panels.count) panels, fontSize=\(fontSize)")
            // Clean up orphaned tmux sessions from previous runs
            let activeCellIDs = Set(panels.flatMap { $0.cells.filter { $0.type == .terminal }.map { $0.id } })
            DispatchQueue.global(qos: .utility).async {
                TmuxManager.cleanupOrphans(activeCellIDs: activeCellIDs)
            }
            focusedRow = 0
            focusedCell = 0
            scheduleFocus()
        } else {
            print("[InfiniteScroll] No saved state found, creating fresh panel")
            addPanel()
        }

        $panels
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &autosaveCancellables)

        // Re-subscribe to nested changes whenever the panels array changes
        $panels
            .sink { [weak self] panels in self?.subscribeToNestedChanges(panels) }
            .store(in: &autosaveCancellables)

        $fontSize
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &autosaveCancellables)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Cancel debounced saves and force immediate save
            self?.autosaveCancellables.removeAll()
            self?.nestedCancellables.removeAll()
            self?.save()
        }

        // Track mouse clicks to update focus from first responder
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.syncFocusFromFirstResponder()
            }
            return event
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Sync focus from actual first responder

    func syncFocusFromFirstResponder() {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return }

        for (rowIdx, panel) in panels.enumerated() {
            for (cellIdx, cell) in panel.cells.enumerated() {
                switch cell.type {
                case .terminal:
                    if let termView = TerminalViewRegistry.shared.view(for: cell.id),
                       responder === termView || responder.isDescendant(of: termView) {
                        focusedRow = rowIdx
                        focusedCell = cellIdx
                        focusedCellID = cell.id
                        return
                    }
                case .notes:
                    if responder is NotesTextView {
                        // Check if this notes view matches
                        if let notesView = NotesViewRegistry.shared.view(for: cell.id),
                           responder === notesView {
                            focusedRow = rowIdx
                            focusedCell = cellIdx
                            focusedCellID = cell.id
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row operations

    func addPanel() {
        let panel = PanelModel(index: panels.count + 1)
        nextIndex += 1
        let insertAt = min(focusedRow + 1, panels.count)
        panels.insert(panel, at: insertAt)
        renumberRows()
        focusedRow = insertAt
        focusedCell = 0
        scheduleFocus()
    }

    func removePanel(id: UUID) {
        // Kill tmux sessions for all terminal cells in this row
        if let panel = panels.first(where: { $0.id == id }) {
            for cell in panel.cells where cell.type == .terminal {
                let sessionName = TmuxManager.sessionName(for: cell.id)
                DispatchQueue.global(qos: .utility).async {
                    TmuxManager.killSession(sessionName)
                }
            }
        }
        panels.removeAll { $0.id == id }
        if panels.isEmpty {
            save()
            NSApplication.shared.terminate(nil)
        }
        focusedRow = min(focusedRow, max(panels.count - 1, 0))
        clampCell()
        renumberRows()
    }

    private func renumberRows() {
        for (i, panel) in panels.enumerated() {
            panel.title = "Row #\(i + 1)"
        }
    }

    // MARK: - Cell operations

    func duplicateCurrentCell() {
        syncFocusFromFirstResponder()
        guard focusedRow < panels.count else { return }
        let panel = panels[focusedRow]
        guard focusedCell < panel.cells.count else { return }

        let current = panel.cells[focusedCell]
        // Always duplicate as a terminal cell (notes is toggled separately)
        let sourceCwd: String
        if current.type == .terminal {
            let sessionName = TmuxManager.sessionName(for: current.id)
            sourceCwd = TmuxManager.paneCwd(session: sessionName) ?? current.cwd
        } else {
            // Cmd+D on notes: use cwd of the last terminal in this row
            sourceCwd = panel.cells.last(where: { $0.type == .terminal })?.cwd ?? NSHomeDirectory()
        }
        let newCell = CellModel(type: .terminal, cwd: sourceCwd)
        // Insert before the notes cell (if present) to keep notes rightmost
        let insertIdx: Int
        if let notesIdx = panel.cells.firstIndex(where: { $0.type == .notes }) {
            insertIdx = notesIdx
        } else {
            insertIdx = focusedCell + 1
        }
        panel.cells.insert(newCell, at: insertIdx)
        focusedCell = insertIdx
        objectWillChange.send()
        scheduleFocus()
    }

    func closeCurrentCell() {
        syncFocusFromFirstResponder()
        guard focusedRow < panels.count else { return }
        let panel = panels[focusedRow]
        guard focusedCell < panel.cells.count else { return }

        let cell = panel.cells[focusedCell]
        // Kill tmux session when explicitly closing a terminal cell
        if cell.type == .terminal {
            let sessionName = TmuxManager.sessionName(for: cell.id)
            DispatchQueue.global(qos: .utility).async {
                TmuxManager.killSession(sessionName)
            }
        }

        panel.cells.remove(at: focusedCell)
        objectWillChange.send()

        if panel.cells.isEmpty {
            removePanel(id: panel.id)
            return
        }

        focusedCell = min(focusedCell, panel.cells.count - 1)
        scheduleFocus()
    }

    // MARK: - Zoom

    func zoomIn() {
        fontSize = min(fontSize + 1, 32)
    }

    func zoomOut() {
        fontSize = max(fontSize - 1, 8)
    }

    // MARK: - Focus navigation

    func focusUp() {
        guard panels.count > 1 else { return }
        focusedRow = (focusedRow - 1 + panels.count) % panels.count
        clampCell()
        applyFocus()
    }

    func focusDown() {
        guard panels.count > 1 else { return }
        focusedRow = (focusedRow + 1) % panels.count
        clampCell()
        applyFocus()
    }

    func focusLeft() {
        guard focusedRow < panels.count else { return }
        let count = panels[focusedRow].cells.count
        guard count > 1 else { return }
        focusedCell = (focusedCell - 1 + count) % count
        applyFocus()
    }

    func focusRight() {
        guard focusedRow < panels.count else { return }
        let count = panels[focusedRow].cells.count
        guard count > 1 else { return }
        focusedCell = (focusedCell + 1) % count
        applyFocus()
    }

    private func clampCell() {
        guard focusedRow < panels.count else { return }
        let count = panels[focusedRow].cells.count
        if focusedCell >= count {
            focusedCell = max(count - 1, 0)
        }
    }

    private func scheduleFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyFocus()
        }
    }

    private func applyFocus() {
        guard focusedRow < panels.count else { return }
        let panel = panels[focusedRow]
        guard focusedCell < panel.cells.count else { return }

        let cell = panel.cells[focusedCell]
        focusedCellID = cell.id

        switch cell.type {
        case .terminal:
            TerminalViewRegistry.shared.focus(id: cell.id)
        case .notes:
            NotesViewRegistry.shared.focus(id: cell.id)
        }
    }

    // MARK: - Nested observation

    /// Subscribe to objectWillChange on each panel and its cells so that
    /// edits to notes text (or any nested property) trigger autosave.
    private func subscribeToNestedChanges(_ panels: [PanelModel]) {
        nestedCancellables.removeAll()
        for panel in panels {
            panel.objectWillChange
                .debounce(for: .seconds(2), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.save() }
                .store(in: &nestedCancellables)
            for cell in panel.cells {
                cell.objectWillChange
                    .debounce(for: .seconds(2), scheduler: RunLoop.main)
                    .sink { [weak self] _ in self?.save() }
                    .store(in: &nestedCancellables)
            }
        }
    }

    // MARK: - Persistence

    func save() {
        let state = AppState(
            panels: panels.map { $0.toState() },
            nextIndex: nextIndex,
            fontSize: fontSize
        )
        PersistenceManager.save(state)
    }
}

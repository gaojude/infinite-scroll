import Foundation

public enum CLISocket {
    public static var path: String {
        let home = NSHomeDirectory()
        return "\(home)/.infinite-scroll/socket"
    }
}

public struct CLIRequest: Codable {
    public var kind: String
    public var cell: String?
    public var row: String?
    public var text: String?
    public var keys: [String]?
    public var scrollback: Int?
    public var cellType: String?

    public init(
        kind: String,
        cell: String? = nil,
        row: String? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        scrollback: Int? = nil,
        cellType: String? = nil
    ) {
        self.kind = kind
        self.cell = cell
        self.row = row
        self.text = text
        self.keys = keys
        self.scrollback = scrollback
        self.cellType = cellType
    }
}

public struct CellInfo: Codable {
    public var id: String
    public var ref: String
    public var index: Int
    public var type: String
    public var cwd: String?
    public var isRunning: Bool?
    public var focused: Bool

    public init(id: String, ref: String, index: Int, type: String, cwd: String?, isRunning: Bool?, focused: Bool) {
        self.id = id
        self.ref = ref
        self.index = index
        self.type = type
        self.cwd = cwd
        self.isRunning = isRunning
        self.focused = focused
    }
}

public struct RowInfo: Codable {
    public var id: String
    public var index: Int
    public var title: String
    public var focused: Bool
    public var cells: [CellInfo]

    public init(id: String, index: Int, title: String, focused: Bool, cells: [CellInfo]) {
        self.id = id
        self.index = index
        self.title = title
        self.focused = focused
        self.cells = cells
    }
}

public struct EventInfo: Codable {
    public var kind: String
    public var cellID: String?
    public var rowID: String?

    public init(kind: String, cellID: String? = nil, rowID: String? = nil) {
        self.kind = kind
        self.cellID = cellID
        self.rowID = rowID
    }
}

public struct CLIResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var rows: [RowInfo]?
    public var text: String?
    public var cell: CellInfo?
    public var event: EventInfo?

    public init(
        ok: Bool,
        error: String? = nil,
        rows: [RowInfo]? = nil,
        text: String? = nil,
        cell: CellInfo? = nil,
        event: EventInfo? = nil
    ) {
        self.ok = ok
        self.error = error
        self.rows = rows
        self.text = text
        self.cell = cell
        self.event = event
    }

    public static func okEmpty() -> CLIResponse { CLIResponse(ok: true) }
    public static func failure(_ message: String) -> CLIResponse {
        CLIResponse(ok: false, error: message)
    }
}

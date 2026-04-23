import Foundation

struct AppState: Codable {
    let panels: [PanelState]
    let nextIndex: Int
    let fontSize: CGFloat?
    let fontName: String?
    let rowHeight: CGFloat?
}

enum PersistenceManager {
    private static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".infinite-scroll")
    private static let fileURL = directoryURL.appendingPathComponent("state.json")

    static func save(_ state: AppState) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("PersistenceManager: failed to save — \(error)")
        }
    }

    static func load() -> AppState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            print("PersistenceManager: failed to load — \(error)")
            return nil
        }
    }
}

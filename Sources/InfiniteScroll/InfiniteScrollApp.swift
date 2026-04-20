import SwiftUI

@main
struct InfiniteScrollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PanelStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1800, height: 900)
        .commands {
            // Cmd+W: close current cell
            CommandGroup(replacing: .saveItem) {
                Button("Close Cell") {
                    store.closeCurrentCell()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                // Cmd+D: duplicate current cell
                Button("Duplicate Cell") {
                    store.duplicateCurrentCell()
                }
                .keyboardShortcut("d", modifiers: .command)

                // Cmd+Shift+Down: new row below
                Button("New Row Below") {
                    store.addPanel()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    store.showHelp.toggle()
                }
                .keyboardShortcut("/", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    store.zoomIn()
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") {
                    store.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Focus Row Above") {
                    store.focusUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Focus Row Below") {
                    store.focusDown()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Focus Left") {
                    store.focusLeft()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Focus Right") {
                    store.focusRight()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

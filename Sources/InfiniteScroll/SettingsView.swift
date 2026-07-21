import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: PanelStore
    @State private var cliInstalled: Bool = CLIInstaller.isInstalled()
    @State private var cliBusy: Bool = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Font", selection: $store.fontName) {
                    ForEach(PanelStore.availableMonospacedFonts, id: \.self) { name in
                        Text(name)
                            .font(.custom(name, size: 13))
                            .tag(name)
                    }
                }

                Stepper(value: $store.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(store.fontSize))pt")
                }
            }

            Section("Layout") {
                Stepper(
                    value: $store.rowHeight,
                    in: PanelStore.minRowHeight...PanelStore.maxRowHeight,
                    step: 25
                ) {
                    Text("Row height: \(Int(store.rowHeight))px")
                }

                Slider(
                    value: $store.rowHeight,
                    in: PanelStore.minRowHeight...PanelStore.maxRowHeight,
                    step: 25
                )
            }

            Section("Navigation") {
                HStack {
                    Text("Workspace scroll speed")
                    Spacer()
                    Text("\(Int((store.commandScrollSpeed * 100).rounded()))%")
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $store.commandScrollSpeed,
                    in: PanelStore.minCommandScrollSpeed...PanelStore.maxCommandScrollSpeed,
                    step: 0.25
                )

                Text("Applies only when holding Command while scrolling between rows.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Shell command") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cliInstalled ? "Installed at /usr/local/bin/infinite-scroll" : "Not installed")
                            .font(.system(size: 12))
                        Text("Lets AI agents and scripts read and manipulate cells from a terminal. Run 'infinite-scroll --help' to see commands.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if cliInstalled {
                        Button("Uninstall") {
                            cliBusy = true
                            DispatchQueue.global(qos: .userInitiated).async {
                                let ok = CLIInstaller.uninstall()
                                DispatchQueue.main.async {
                                    if ok { cliInstalled = CLIInstaller.isInstalled() }
                                    cliBusy = false
                                }
                            }
                        }
                        .disabled(cliBusy)
                    } else {
                        Button("Install Shell Command") {
                            cliBusy = true
                            DispatchQueue.global(qos: .userInitiated).async {
                                let ok = CLIInstaller.install()
                                DispatchQueue.main.async {
                                    if ok { cliInstalled = CLIInstaller.isInstalled() }
                                    cliBusy = false
                                }
                            }
                        }
                        .disabled(cliBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
        .onAppear { cliInstalled = CLIInstaller.isInstalled() }
    }
}

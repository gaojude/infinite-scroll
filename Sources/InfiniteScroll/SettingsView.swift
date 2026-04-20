import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: PanelStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Font", selection: $store.fontName) {
                    ForEach(SettingsView.monospacedFonts, id: \.self) { name in
                        Text(name)
                            .font(.custom(name, size: 13))
                            .tag(name)
                    }
                }

                Stepper(value: $store.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(store.fontSize))pt")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
    }

    private static let monospacedFonts: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        // Strip hidden system fonts (leading dot) and sort case-insensitively.
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.lowercased() < $1.lowercased() }
    }()
}

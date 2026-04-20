import SwiftUI

struct HelpOverlay: View {
    @Binding var isPresented: Bool

    private static let shortcuts: [(key: String, description: String)] = [
        ("⌘ W",         "Close current cell"),
        ("⌘ D",         "Duplicate current cell"),
        ("⌘ ⇧ ↓",      "New row below"),
        ("⌘ =",         "Zoom in"),
        ("⌘ -",         "Zoom out"),
        ("⌘ ,",         "Open settings"),
        ("⌘ ↑",         "Focus row above"),
        ("⌘ ↓",         "Focus row below"),
        ("⌘ ←",         "Focus left"),
        ("⌘ →",         "Focus right"),
        ("⌘ Scroll",    "Scroll between rows"),
        ("⇧ Enter",     "Send newline in terminal"),
        ("⌘ ⌫",         "Delete to start of line (notes)"),
        ("⌘ /",         "Toggle this help"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.text)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()
                    .background(Theme.border)

                VStack(spacing: 0) {
                    ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                        HStack {
                            Text(shortcut.key)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.accent)
                                .frame(width: 120, alignment: .trailing)

                            Text(shortcut.description)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Theme.text)

                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(
                            index.isMultiple(of: 2)
                                ? Color.clear
                                : Color.white.opacity(0.03)
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 420)
            .background(Theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
    }
}

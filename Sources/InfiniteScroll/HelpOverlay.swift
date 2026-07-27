import SwiftUI

struct HelpOverlay: View {
    @Binding var isPresented: Bool

    private static let shortcuts: [(key: String, description: String)] = [
        ("⌘ W",         "Close current cell"),
        ("⌘ D",         "Duplicate current cell"),
        ("⌘ ⇧ ↑",      "New row above"),
        ("⌘ ⇧ ↓",      "New row below; terminal if empty"),
        ("⌘ ⇧ R",      "Rename current row"),
        ("⌘ =",         "Zoom in"),
        ("⌘ -",         "Zoom out"),
        ("⌘ ,",         "Open settings"),
        ("⌘ ↑",         "Focus row above"),
        ("⌘ ↓",         "Focus row below"),
        ("⌘ ←",         "Focus left"),
        ("⌘ →",         "Focus right"),
        ("⌘ Scroll",    "Scroll between rows (speed in Settings)"),
        ("⌘ F",         "Find rows, folders, and notes"),
        ("⇧ Enter",     "Send newline in terminal"),
        ("⌘ ⌫",         "Delete to start of line (notes)"),
        ("⌘ /",         "Toggle this help"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(420, max(0, proxy.size.width - Theme.panelSpacing * 2))
            let cardHeight = min(560, max(0, proxy.size.height - Theme.panelSpacing * 2))
            let usesCompactRows = cardWidth < 360

            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Keyboard Shortcuts")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
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

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                                shortcutRow(shortcut, compact: usesCompactRows)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, usesCompactRows ? 8 : 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        index.isMultiple(of: 2)
                                            ? Color.clear
                                            : Color.white.opacity(0.03)
                                    )
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .frame(width: cardWidth)
                .frame(maxHeight: cardHeight)
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

    @ViewBuilder
    private func shortcutRow(_ shortcut: (key: String, description: String), compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.key)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.accent)

                Text(shortcut.description)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.text)
            }
        } else {
            HStack {
                Text(shortcut.key)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .frame(width: 120, alignment: .trailing)

                Text(shortcut.description)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.text)

                Spacer(minLength: 0)
            }
        }
    }
}

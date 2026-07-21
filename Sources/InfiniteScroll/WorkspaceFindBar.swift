import AppKit
import SwiftUI

struct WorkspaceFindBar: View {
    @EnvironmentObject var store: PanelStore
    @State private var query = ""
    @State private var shouldFocusSearchField = false

    private var results: [WorkspaceSearchResult] {
        store.searchResults(matching: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Find in Workspace")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.text)

                Spacer()

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close workspace search")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            WorkspaceSearchField(
                text: $query,
                shouldFocus: shouldFocusSearchField,
                onSubmit: jumpToFirstResult
            )
            .frame(height: 26)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()
                .background(Theme.border)

            searchContent
        }
        .frame(width: 520)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16)
        .onAppear {
            shouldFocusSearchField = true
        }
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder
    private var searchContent: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Search row names, folders, and notes. Press Return to jump to the first result.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(14)
        } else if results.isEmpty {
            Text("No workspace matches")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(14)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { result in
                        Button {
                            store.jumpToSearchResult(result)
                        } label: {
                            WorkspaceSearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(result.rowTitle), \(result.matchKind.label), \(result.detail)"
                        )
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func jumpToFirstResult() {
        guard let result = results.first else { return }
        store.jumpToSearchResult(result)
    }

    private func dismiss() {
        store.closeWorkspaceSearch()
    }
}

private struct WorkspaceSearchResultRow: View {
    let result: WorkspaceSearchResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.matchKind.systemImageName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.rowTitle)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)

                Text("\(result.matchKind.label) · \(result.detail)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("↵")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    let shouldFocus: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search rows, folders, and notes"
        field.setAccessibilityLabel("Find in Workspace")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        guard shouldFocus, nsView.window?.firstResponder !== nsView else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: WorkspaceSearchField

        init(parent: WorkspaceSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}

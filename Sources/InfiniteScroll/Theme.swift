import SwiftUI

enum Theme {
    static let background = Color(red: 0.1, green: 0.1, blue: 0.12)
    static let panelBackground = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let headerBackground = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let border = Color(red: 0.25, green: 0.25, blue: 0.28)
    static let text = Color(red: 0.85, green: 0.85, blue: 0.88)
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.58)
    static let accent = Color(red: 0.4, green: 0.6, blue: 1.0)
    static let closeButton = Color(red: 0.8, green: 0.3, blue: 0.3)
    static let addButton = Color(red: 0.3, green: 0.7, blue: 0.4)

    // Notes-specific colors
    static let notesBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let notesText = Color(red: 0.85, green: 0.85, blue: 0.88)

    static let panelHeight: CGFloat = 750
    static let headerHeight: CGFloat = 32
    static let panelCornerRadius: CGFloat = 8
    static let panelSpacing: CGFloat = 12
    // For AppKit code that can't use SwiftUI Color
    static let panelSpacingValue: CGFloat = 12
    static let focusBorder = Color(red: 0.4, green: 0.6, blue: 1.0)
}

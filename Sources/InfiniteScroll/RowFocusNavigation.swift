enum RowFocusNavigation {
    enum Direction {
        case up
        case down
    }

    /// Returns the adjacent row in the requested direction, or nil at a boundary.
    /// Rows are a vertical stack, so navigation must never wrap to the opposite end.
    static func adjacentRow(
        from currentRow: Int,
        rowCount: Int,
        direction: Direction
    ) -> Int? {
        guard rowCount > 0, (0..<rowCount).contains(currentRow) else { return nil }

        switch direction {
        case .up:
            return currentRow > 0 ? currentRow - 1 : nil
        case .down:
            return currentRow < rowCount - 1 ? currentRow + 1 : nil
        }
    }
}

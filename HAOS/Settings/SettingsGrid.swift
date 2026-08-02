import AppKit

/// One row of the Settings window.
///
/// The window describes the rows it wants and `SettingsGrid` lays them out, so
/// a section can be assembled somewhere else — each VM feature brings its own —
/// without anyone having to know which row number it landed on.
enum SettingsRow {
    /// A bold heading introducing the rows below it.
    case header(String)

    /// A labelled control: label in the right-aligned label column, control
    /// beside it. The label is passed in rather than made here so a section
    /// can dim it along with its controls.
    case field(label: NSTextField, control: NSView)

    /// A control with no label of its own, lined up with the labelled ones —
    /// a checkbox whose title already says what it does.
    case control(NSView)

    /// Small print belonging to the row above rather than standing on its own.
    case caption(NSView)

    /// A view spanning both columns.
    case fullWidth(NSView)

    /// A hairline between sections.
    case separator
}

enum SettingsGrid {
    /// Lays the rows out in an `NSGridView`: labels right-aligned in the first
    /// column, controls in the second, and headers, separators and full-width
    /// views spanning both.
    static func make(_ rows: [SettingsRow]) -> NSGridView {
        let grid = NSGridView(views: rows.map(\.views))
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        for (index, row) in rows.enumerated() {
            switch row {
            case .header, .fullWidth:
                span(grid, row: index, placement: .leading)
            case .separator:
                span(grid, row: index, placement: .fill)
                grid.row(at: index).rowAlignment = .none
                grid.row(at: index).topPadding = 6
                grid.row(at: index).bottomPadding = 6
            case .caption:
                // Sits close under the control it explains.
                grid.row(at: index).topPadding = -4
            case .field, .control:
                break
            }
        }
        return grid
    }

    private static func span(_ grid: NSGridView, row: Int, placement: NSGridCell.Placement) {
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                        verticalRange: NSRange(location: row, length: 1))
        grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = placement
    }
}

/// The window's label styles, shared so sections written elsewhere match.
enum SettingsLabel {
    /// A section heading.
    static func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    /// Small secondary text, for captions and footnotes.
    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// A caption that wraps to `width` instead of running off the window.
    static func wrappingCaption(_ text: String, width: CGFloat) -> NSTextField {
        // A label is single-line until told otherwise, and this one wraps.
        let label = caption(text)
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        return label
    }
}

private extension SettingsRow {
    /// The views making up the row, in grid-column order.
    var views: [NSView] {
        switch self {
        case .header(let title): return [SettingsLabel.header(title)]
        case .field(let label, let control): return [label, control]
        case .control(let view), .caption(let view): return [NSGridCell.emptyContentView, view]
        case .fullWidth(let view): return [view]
        case .separator: return [NSBox.separator]
        }
    }
}

private extension NSBox {
    /// A horizontal hairline for separating the window's sections.
    static var separator: NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

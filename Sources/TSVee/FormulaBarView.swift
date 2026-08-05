import AppKit

/// Google-Sheets-style bar above the grid: a name box showing the focused
/// cell's address, an editable field mirroring its raw content, and — at the
/// right — a tally of the current selection plus a duplicate-ID warning that
/// jumps to the offending rows.
final class FormulaBarView: NSView, NSTextFieldDelegate {

    var onCommit: ((String) -> Void)?
    var onJumpToDuplicate: (() -> Void)?

    private let nameBox = NSTextField(labelWithString: "")
    private let contentField = NSTextField(string: "")
    private let duplicateButton = NSButton(title: "", target: nil, action: nil)
    private let tallyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameBox.translatesAutoresizingMaskIntoConstraints = false
        nameBox.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        nameBox.textColor = .secondaryLabelColor
        nameBox.alignment = .center
        nameBox.stringValue = "A1"

        let nameBoxDivider = NSBox()
        nameBoxDivider.boxType = .separator
        nameBoxDivider.translatesAutoresizingMaskIntoConstraints = false

        contentField.translatesAutoresizingMaskIntoConstraints = false
        contentField.font = .systemFont(ofSize: 12)
        contentField.isBordered = false
        contentField.drawsBackground = false
        contentField.focusRingType = .none
        contentField.placeholderString = ""
        contentField.delegate = self
        contentField.cell?.usesSingleLineMode = true
        contentField.cell?.isScrollable = true

        duplicateButton.translatesAutoresizingMaskIntoConstraints = false
        duplicateButton.bezelStyle = .inline
        duplicateButton.isBordered = false
        duplicateButton.contentTintColor = .systemRed
        duplicateButton.font = .systemFont(ofSize: 11, weight: .medium)
        duplicateButton.target = self
        duplicateButton.action = #selector(jumpToDuplicate)
        duplicateButton.isHidden = true

        tallyLabel.translatesAutoresizingMaskIntoConstraints = false
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        tallyLabel.textColor = .secondaryLabelColor
        tallyLabel.isHidden = true

        // A stack so the warning slides over to the edge whenever there's no
        // tally to show (hidden arranged views drop out of the layout).
        let status = NSStackView(views: [duplicateButton, tallyLabel])
        status.translatesAutoresizingMaskIntoConstraints = false
        status.orientation = .horizontal
        status.spacing = 12

        addSubview(nameBox)
        addSubview(nameBoxDivider)
        addSubview(contentField)
        addSubview(status)

        NSLayoutConstraint.activate([
            nameBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameBox.widthAnchor.constraint(equalToConstant: 64),

            nameBoxDivider.leadingAnchor.constraint(equalTo: nameBox.trailingAnchor, constant: 8),
            nameBoxDivider.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameBoxDivider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            contentField.leadingAnchor.constraint(equalTo: nameBoxDivider.trailingAnchor, constant: 10),
            contentField.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentField.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -10),
            contentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(cellName: String, content: String, duplicateCount: Int,
                tally: SelectionTally?) {
        nameBox.stringValue = cellName
        if contentField.currentEditor() == nil {
            contentField.stringValue = content
        }
        if let tally {
            tallyLabel.stringValue = tally.idsOnly
                ? "\(tally.populated) entr\(tally.populated == 1 ? "y" : "ies")"
                : "Count: \(tally.populated)/\(tally.total)"
            tallyLabel.isHidden = false
        } else {
            tallyLabel.isHidden = true
        }
        if duplicateCount > 0 {
            duplicateButton.title = "⚠︎ \(duplicateCount) duplicate ID\(duplicateCount == 1 ? "" : "s")"
            duplicateButton.isHidden = false
        } else {
            duplicateButton.isHidden = true
        }
    }

    @objc private func jumpToDuplicate() {
        onJumpToDuplicate?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // onCommit writes the value and hands focus back to the grid.
            onCommit?(contentField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }
}

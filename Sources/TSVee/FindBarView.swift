import AppKit

/// Find & replace state shared by every window's find bar, so ⌘G keeps
/// working from any sheet and a search continues seamlessly in whichever
/// sheet the next match lands in.
final class FindState {
    static let shared = FindState()
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var wholeCell = false
    var allSheets = false
    var options: FindOptions { FindOptions(caseSensitive: caseSensitive, wholeCell: wholeCell) }
}

/// Find & replace bar docked at the bottom of each document window (never a
/// blocking panel). ⌘F shows it, Esc hides it. Scope is either the sheet it
/// lives in or every open sheet; cross-sheet matches bring the other sheet's
/// window (or tab) forward.
final class FindBarView: NSView, NSSearchFieldDelegate {

    static let barHeight: CGFloat = 66

    /// The sheet this bar belongs to — searches start here.
    var ownDocument: (() -> TSVDocument?)?
    var ownFocusedCell: (() -> GridPos)?
    var onDismiss: (() -> Void)?

    private let searchField = NSSearchField()
    private let replaceField = NSTextField(string: "")
    private let matchLabel = NSTextField(labelWithString: "")
    private let scopePopup = NSPopUpButton()
    private let caseCheckbox = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeCellCheckbox = NSButton(checkboxWithTitle: "Whole Cell", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        replaceField.placeholderString = "Replace"
        replaceField.bezelStyle = .roundedBezel
        replaceField.delegate = self
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.cell?.usesSingleLineMode = true
        replaceField.cell?.isScrollable = true

        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.lineBreakMode = .byTruncatingTail
        matchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scopePopup.addItems(withTitles: ["This Sheet", "All Open Sheets"])
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.target = self
        scopePopup.action = #selector(optionsChanged)

        for checkbox in [caseCheckbox, wholeCellCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox.target = self
            checkbox.action = #selector(optionsChanged)
        }

        let previousButton = symbolButton("chevron.left", description: "Find Previous",
                                          action: #selector(findPreviousClicked))
        let nextButton = symbolButton("chevron.right", description: "Find Next",
                                      action: #selector(findNextClicked))
        let closeButton = symbolButton("xmark", description: "Done",
                                       action: #selector(closeClicked))
        closeButton.isBordered = false

        let replaceButton = NSButton(title: "Replace", target: self,
                                     action: #selector(replaceClicked))
        let replaceAllButton = NSButton(title: "Replace All", target: self,
                                        action: #selector(replaceAllClicked))
        for button in [replaceButton, replaceAllButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let findRow = NSStackView(views: [searchField, previousButton, nextButton, matchLabel,
                                          scopePopup, caseCheckbox, wholeCellCheckbox, closeButton])
        findRow.orientation = .horizontal
        findRow.spacing = 8
        findRow.translatesAutoresizingMaskIntoConstraints = false

        let replaceRow = NSStackView(views: [replaceField, replaceButton, replaceAllButton])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 8
        replaceRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(divider)
        addSubview(findRow)
        addSubview(replaceRow)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),

            findRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            findRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            findRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            replaceRow.topAnchor.constraint(equalTo: findRow.bottomAnchor, constant: 6),
            replaceRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func symbolButton(_ name: String, description: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: - State sync

    func refreshFromState() {
        let state = FindState.shared
        searchField.stringValue = state.query
        replaceField.stringValue = state.replacement
        caseCheckbox.state = state.caseSensitive ? .on : .off
        wholeCellCheckbox.state = state.wholeCell ? .on : .off
        scopePopup.selectItem(at: state.allSheets ? 1 : 0)
        updateMatchCount()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Which of the bar's fields holds keyboard focus, if either. A search
    /// that hops to another sheet re-focuses the same field over there, so
    /// Return keeps doing what it was doing.
    enum Field { case search, replace }

    var focusedField: Field? {
        guard let editor = window?.firstResponder as? NSTextView else { return nil }
        if editor.delegate === searchField { return .search }
        if editor.delegate === replaceField { return .replace }
        return nil
    }

    func focus(_ field: Field) {
        guard focusedField != field else { return }
        let target: NSTextField = field == .search ? searchField : replaceField
        window?.makeFirstResponder(target)
        target.currentEditor()?.selectAll(nil)
    }

    /// The grid changed under us (edits, undo, replace in another window).
    func noteModelChanged() {
        guard !isHidden else { return }
        updateMatchCount()
    }

    private func syncStateFromFields() {
        let state = FindState.shared
        state.query = searchField.stringValue
        // A pasted tab or newline would smuggle structure into a cell.
        state.replacement = replaceField.stringValue
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    @objc private func optionsChanged(_ sender: Any?) {
        let state = FindState.shared
        state.caseSensitive = caseCheckbox.state == .on
        state.wholeCell = wholeCellCheckbox.state == .on
        state.allSheets = scopePopup.indexOfSelectedItem == 1
        updateMatchCount()
    }

    // MARK: - Searching

    private struct Match {
        let document: TSVDocument
        let row: Int
        let column: Int
    }

    /// Sheets the current scope covers, rotated so this bar's own sheet is
    /// first — searches walk forward (or back) from here and wrap around.
    private func documentsInScope() -> [TSVDocument] {
        guard let current = ownDocument?() else { return [] }
        guard FindState.shared.allSheets else { return [current] }
        let all = NSDocumentController.shared.documents.compactMap { $0 as? TSVDocument }
        guard let index = all.firstIndex(where: { $0 === current }) else { return [current] }
        return Array(all[index...]) + Array(all[..<index])
    }

    func performFind(backwards: Bool) {
        syncStateFromFields()
        guard !FindState.shared.query.isEmpty else { NSSound.beep(); return }
        guard let match = nextMatch(backwards: backwards) else {
            matchLabel.stringValue = "No matches"
            NSSound.beep()
            return
        }
        updateMatchCount()
        reveal(match)
    }

    private func nextMatch(backwards: Bool) -> Match? {
        let state = FindState.shared
        let documents = documentsInScope()
        guard let current = documents.first else { return nil }
        let pos = ownFocusedCell?() ?? GridPos(row: 0, col: 0)
        let here = current.model.findMatches(state.query, options: state.options)

        if backwards {
            if let m = here.last(where: { ($0.row, $0.column) < (pos.row, pos.col) }) {
                return Match(document: current, row: m.row, column: m.column)
            }
            for document in documents.dropFirst().reversed() {
                if let m = document.model.findMatches(state.query, options: state.options).last {
                    return Match(document: document, row: m.row, column: m.column)
                }
            }
            if let m = here.last { return Match(document: current, row: m.row, column: m.column) }
        } else {
            if let m = here.first(where: { ($0.row, $0.column) > (pos.row, pos.col) }) {
                return Match(document: current, row: m.row, column: m.column)
            }
            for document in documents.dropFirst() {
                if let m = document.model.findMatches(state.query, options: state.options).first {
                    return Match(document: document, row: m.row, column: m.column)
                }
            }
            if let m = here.first { return Match(document: current, row: m.row, column: m.column) }
        }
        return nil
    }

    private func reveal(_ match: Match) {
        guard let controller = match.document.windowControllers.first
            as? DocumentWindowController else { return }
        // Capture before the window switch steals first-responder status.
        let field = focusedField
        match.document.showWindows()
        controller.revealFindMatch(row: match.row, column: match.column, focusing: field)
    }

    private func updateMatchCount() {
        let state = FindState.shared
        guard !state.query.isEmpty else {
            matchLabel.stringValue = ""
            return
        }
        var total = 0
        var sheets = 0
        for document in documentsInScope() {
            let count = document.model.findMatches(state.query, options: state.options).count
            if count > 0 {
                total += count
                sheets += 1
            }
        }
        if total == 0 {
            matchLabel.stringValue = "No matches"
        } else if state.allSheets && sheets > 1 {
            matchLabel.stringValue = "\(total) matches in \(sheets) sheets"
        } else {
            matchLabel.stringValue = "\(total) match\(total == 1 ? "" : "es")"
        }
    }

    // MARK: - Replacing

    @objc private func replaceClicked(_ sender: Any?) {
        syncStateFromFields()
        let state = FindState.shared
        guard !state.query.isEmpty, let document = ownDocument?() else { NSSound.beep(); return }
        let pos = ownFocusedCell?() ?? GridPos(row: 0, col: 0)
        let value = document.model.value(row: pos.row, column: pos.col)
        if let updated = SpreadsheetModel.replacing(value, query: state.query,
                                                    with: state.replacement,
                                                    options: state.options) {
            document.model.setValue(updated, row: pos.row, column: pos.col)
        }
        performFind(backwards: false)
    }

    @objc private func replaceAllClicked(_ sender: Any?) {
        syncStateFromFields()
        let state = FindState.shared
        guard !state.query.isEmpty else { NSSound.beep(); return }
        var total = 0
        var sheets = 0
        for document in documentsInScope() {
            let count = document.model.replaceAll(state.query, with: state.replacement,
                                                  options: state.options)
            if count > 0 {
                total += count
                sheets += 1
            }
        }
        if total == 0 {
            matchLabel.stringValue = "No matches"
            NSSound.beep()
        } else if sheets > 1 {
            matchLabel.stringValue = "Replaced \(total) in \(sheets) sheets"
        } else {
            matchLabel.stringValue = "Replaced \(total) cell\(total == 1 ? "" : "s")"
        }
    }

    // MARK: - Buttons & keys

    @objc private func findNextClicked(_ sender: Any?) { performFind(backwards: false) }
    @objc private func findPreviousClicked(_ sender: Any?) { performFind(backwards: true) }
    @objc private func closeClicked(_ sender: Any?) { onDismiss?() }

    func controlTextDidChange(_ obj: Notification) {
        syncStateFromFields()
        updateMatchCount()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === searchField {
                let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                performFind(backwards: backwards)
            } else {
                replaceClicked(nil)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        default:
            return false
        }
    }
}

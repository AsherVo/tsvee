import AppKit

final class DocumentWindowController: NSWindowController {

    private let spreadsheetView = SpreadsheetView()
    private let formulaBar = FormulaBarView()
    private let findBar = FindBarView()
    private var findBarHeightConstraint: NSLayoutConstraint?

    convenience init(document: TSVDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true)
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.setFrameAutosaveName("TSVeeDocumentWindow")

        // Sublime-style tabs: documents open as tabs of the frontmost window;
        // dragging a tab out creates an independent window with its own tabs.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "TSVeeDocumentWindow"

        self.init(window: window)

        // Format hooks must be in place before the model is attached — the
        // model's didSet does the first geometry pass using the .tss widths.
        spreadsheetView.formatProvider = { [weak document] in document?.format ?? TSSFormat() }
        spreadsheetView.onFormatChange = { [weak document] mutate in
            guard let document else { return }
            mutate(&document.format)
            document.noteFormatChanged()
        }
        spreadsheetView.documentURLProvider = { [weak document] in document?.fileURL }
        // Values a `source` column mirrored in aren't in the file yet.
        spreadsheetView.onDerivedDataChanged = { [weak document] in
            document?.updateChangeCount(.changeDone)
        }
        spreadsheetView.model = document.model

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.documentView = spreadsheetView
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Zoom (⌘+ / ⌘- / ⌘0, or pinch) scales the clip view, so the grid
        // keeps drawing and hit-testing in document coordinates.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = SpreadsheetView.zoomSteps.first!
        scrollView.maxMagnification = SpreadsheetView.zoomSteps.last!
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        formulaBar.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        let findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeightConstraint = findBarHeight

        let content = NSView()
        content.addSubview(formulaBar)
        content.addSubview(divider)
        content.addSubview(scrollView)
        content.addSubview(findBar)
        window.contentView = content

        NSLayoutConstraint.activate([
            formulaBar.topAnchor.constraint(equalTo: content.topAnchor),
            formulaBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formulaBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formulaBar.heightAnchor.constraint(equalToConstant: 34),

            divider.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: findBar.topAnchor),

            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            findBarHeight,
        ])

        wireUp(document: document)
        window.makeFirstResponder(spreadsheetView)

        // Coming to the front is when a sheet showing stale content starts
        // doing harm, so that's when it re-reads its file. (An app switch
        // resigns and re-takes key, so returning to TSVee counts too.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window)

        // Debug/automation hook: `-TSVeeDebugDirty 1` marks the document
        // edited after launch so the dirty indicator can be screenshot-tested.
        if UserDefaults.standard.bool(forKey: "TSVeeDebugDirty") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak document] in
                document?.updateChangeCount(.changeDone)
            }
        }

        // Debug/automation hook: `-TSVeeDebugScroll 400,300` scrolls the grid
        // after launch so scrolled rendering can be screenshot-tested.
        if let spec = UserDefaults.standard.string(forKey: "TSVeeDebugScroll") {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak scrollView] in
                    guard let scrollView else { return }
                    scrollView.contentView.scroll(to: NSPoint(x: parts[0], y: parts[1]))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }

    private func wireUp(document: TSVDocument) {
        let model = document.model

        model.onChange = { [weak self] in
            guard let self else { return }
            self.spreadsheetView.modelDidChange()
            self.refreshFormulaBar()
            self.findBar.noteModelChanged()
        }

        spreadsheetView.onSelectionChange = { [weak self] in
            self?.refreshFormulaBar()
            self?.noteCurrentID()
        }

        formulaBar.onCommit = { [weak self] text in
            self?.spreadsheetView.applyToFocusedCell(text)
        }
        formulaBar.onJumpToDuplicate = { [weak self] in
            self?.spreadsheetView.jumpToNextDuplicateID(nil)
        }

        findBar.ownDocument = { [weak document] in document }
        findBar.ownFocusedCell = { [weak self] in
            self?.spreadsheetView.focusedCell ?? GridPos(row: 0, col: 0)
        }
        findBar.onDismiss = { [weak self] in self?.hideFindBar() }

        // The document was read before this controller existed, so push the
        // initial state through by hand.
        refreshFormulaBar()
    }

    // MARK: - Changes made to the file on disk

    @objc private func windowBecameKey(_ notification: Notification) {
        (document as? TSVDocument)?.reconcileWithDiskIfNeeded(confirmingIn: window)
        // The sheets this one links to may have moved on too, and they're read
        // straight from disk rather than through a document of their own.
        spreadsheetView.refreshLinkedSheets()
        // Last, so it lands in whatever rows the two steps above settled on.
        followCurrentID()
    }

    // MARK: - Cross-sheet ID following

    /// Remembers the focused row's ID, for the sheet the user switches to
    /// next. Only while this window is the one being driven: a sheet updating
    /// itself in the background must not redirect where everything else looks.
    private func noteCurrentID() {
        guard window?.isKeyWindow == true, let model = spreadsheetView.model else { return }
        let row = spreadsheetView.focusedCell.row
        guard row < model.rowCount, model.headerLevel(ofRow: row) == 0,
              !model.isFieldNameRow(row) else { return }
        let id = model.value(row: row, column: 0)
        guard !id.isEmpty else { return }
        FollowState.shared.currentID = id
    }

    /// Arriving at this sheet lands on the entry the last one was on, exactly
    /// as picking it out of the "Go to" menu would — collapsed sections
    /// unfolded, whole row selected.
    ///
    /// Silent when there's nothing worth doing: following is off, the ID isn't
    /// in this sheet, the cursor is already on it (following would flatten a
    /// cell selection into a whole-row one for nothing — which is every time
    /// you switch back from another app), or a cell is mid-edit and moving the
    /// selection would strand the editor.
    private func followCurrentID() {
        guard FollowState.shared.isEnabled, !isEditingCell,
              let id = FollowState.shared.currentID,
              let model = spreadsheetView.model,
              model.value(row: spreadsheetView.focusedCell.row, column: 0) != id,
              let row = model.firstRow(withID: id) else { return }
        spreadsheetView.selectRowAndReveal(row)
    }

    /// True while a cell's in-place editor is open with text in it.
    var isEditingCell: Bool { spreadsheetView.isEditingCell }

    /// About to swap the document's contents out from under this window: drop
    /// the in-cell editor first, so it can't commit into rows that are gone.
    func prepareForReload() {
        spreadsheetView.cancelCellEdit()
        findBar.noteModelChanged()
    }

    // MARK: - Find & replace (menu actions arrive via the responder chain)

    /// ⌘F: find in this sheet. ⇧⌘F: find across all open sheets. Either way
    /// the scope stays visible (and changeable) in the bar's popup, which also
    /// offers this sheet's individual columns. ⌘F leaves a column scope alone
    /// (it already searches only this sheet); ⇧⌘F widens past it.
    @objc func showFindBar(_ sender: Any?) {
        FindState.shared.allSheets = false
        showFindBar(takeFocus: true)
    }

    @objc func showFindBarAllSheets(_ sender: Any?) {
        FindState.shared.allSheets = true
        FindState.shared.column = nil
        showFindBar(takeFocus: true)
    }

    func showFindBar(takeFocus: Bool) {
        findBar.refreshFromState()
        findBar.isHidden = false
        findBarHeightConstraint?.constant = FindBarView.barHeight
        if takeFocus { findBar.focusSearchField() }
    }

    func hideFindBar() {
        findBar.isHidden = true
        findBarHeightConstraint?.constant = 0
        window?.makeFirstResponder(spreadsheetView)
    }

    @objc func findNext(_ sender: Any?) { findBar.performFind(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findBar.performFind(backwards: true) }

    /// Brings this sheet forward and selects a matching cell. When a search
    /// hops here from another sheet, this bar comes up showing the same
    /// search, and focus lands in the same field it left — so Return (or
    /// typing a new query) carries straight on.
    func revealFindMatch(row: Int, column: Int, focusing field: FindBarView.Field?) {
        window?.makeKeyAndOrderFront(nil)
        spreadsheetView.selectCellAndReveal(row: row, column: column)
        guard !FindState.shared.query.isEmpty else { return }
        if findBar.isHidden { showFindBar(takeFocus: false) }
        if let field { findBar.focus(field) }
    }

    // MARK: - Dirty indicator in the window/tab title

    /// Compact title for a tab: the dirty marker goes up front (narrow tabs
    /// truncate the tail, so a trailing marker is the first thing to vanish)
    /// and the ".tsv" every tab shares is dropped — it's pure noise at tab
    /// width. The file's full path lives in the tab's tooltip.
    static func tabTitle(for displayName: String, edited: Bool) -> String {
        let name = (displayName as NSString).pathExtension.lowercased() == "tsv"
            ? (displayName as NSString).deletingPathExtension
            : displayName
        return (edited ? "*" : "") + name
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        (document as? NSDocument)?.isDocumentEdited == true ? "*" + displayName : displayName
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        synchronizeWindowTitleWithDocumentName()
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        guard let window, let document = document as? NSDocument else { return }
        window.tab.title = Self.tabTitle(for: document.displayName,
                                         edited: document.isDocumentEdited)
        // Two sheets of the same name in different folders are told apart by
        // hovering, so the tooltip is the path, not the name again.
        window.tab.toolTip = document.fileURL?.path ?? document.displayName
    }

    /// Brings this sheet forward and selects the given row (cross-file ID
    /// navigation lands here).
    func reveal(row: Int) {
        window?.makeKeyAndOrderFront(nil)
        spreadsheetView.selectRowAndReveal(row)
    }

    private func refreshFormulaBar() {
        guard let model = spreadsheetView.model else { return }
        formulaBar.update(
            cellName: spreadsheetView.focusedCellName(),
            content: spreadsheetView.focusedCellValue(),
            editable: spreadsheetView.focusedCellIsEditable,
            duplicateCount: model.duplicateIDRows.count,
            tally: spreadsheetView.selectionTally())
    }
}

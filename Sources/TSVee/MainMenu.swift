import AppKit

/// Programmatic main menu (no storyboard in this project).
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "TSVee"))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(sheetMenu(), title: "Sheet"))
        main.addItem(submenu(windowMenu(), title: "Window"))
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "TSVee")
        menu.addItem(withTitle: "About TSVee",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide TSVee",
                                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = .command
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TSVee",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        let newWindow = menu.addItem(withTitle: "New Window",
                                     action: NSSelectorFromString("newUntitledWindow:"), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        openRecent.submenu = openRecentMenu
        menu.addItem(openRecent)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = menu.addItem(withTitle: "Save As…",
                                  action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .option, .shift]
        let saveAll = menu.addItem(withTitle: "Save All",
                                   action: NSSelectorFromString("saveAllDocuments:"), keyEquivalent: "s")
        saveAll.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Revert to Saved",
                     action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: NSSelectorFromString("delete:"), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find and Replace…",
                     action: NSSelectorFromString("showFindBar:"), keyEquivalent: "f")
        let findAll = menu.addItem(withTitle: "Find and Replace in All Sheets…",
                                   action: NSSelectorFromString("showFindBarAllSheets:"),
                                   keyEquivalent: "F")
        findAll.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Find Next",
                     action: NSSelectorFromString("findNext:"), keyEquivalent: "g")
        let findPrevious = menu.addItem(withTitle: "Find Previous",
                                        action: NSSelectorFromString("findPrevious:"), keyEquivalent: "G")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Freeze Column Names Row",
                     action: NSSelectorFromString("toggleFreezeFieldRow:"), keyEquivalent: "")
        menu.addItem(withTitle: "Freeze ID Column",
                     action: NSSelectorFromString("toggleFreezeIDColumn:"), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Tab Bar",
                     action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Show All Tabs",
                     action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")
        return menu
    }

    private static func sheetMenu() -> NSMenu {
        let menu = NSMenu(title: "Sheet")
        menu.addItem(withTitle: "Insert Row Above",
                     action: NSSelectorFromString("insertRowAbove:"), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Row Below",
                     action: NSSelectorFromString("insertRowBelow:"), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Rows",
                     action: NSSelectorFromString("deleteSelectedRows:"), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Insert Column Left",
                     action: NSSelectorFromString("insertColumnLeft:"), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Column Right",
                     action: NSSelectorFromString("insertColumnRight:"), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Columns",
                     action: NSSelectorFromString("deleteSelectedColumns:"), keyEquivalent: "")
        menu.addItem(.separator())
        let leftArrow = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        let rightArrow = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        let collapse = menu.addItem(withTitle: "Collapse Section",
                                    action: NSSelectorFromString("collapseSection:"),
                                    keyEquivalent: leftArrow)
        collapse.keyEquivalentModifierMask = [.command, .option]
        let expand = menu.addItem(withTitle: "Expand Section",
                                  action: NSSelectorFromString("expandSection:"),
                                  keyEquivalent: rightArrow)
        expand.keyEquivalentModifierMask = [.command, .option]
        let collapseAll = menu.addItem(withTitle: "Collapse All Sections",
                                       action: NSSelectorFromString("collapseAllSections:"),
                                       keyEquivalent: leftArrow)
        collapseAll.keyEquivalentModifierMask = [.command, .option, .shift]
        let expandAll = menu.addItem(withTitle: "Expand All Sections",
                                     action: NSSelectorFromString("expandAllSections:"),
                                     keyEquivalent: rightArrow)
        expandAll.keyEquivalentModifierMask = [.command, .option, .shift]

        menu.addItem(.separator())
        let jump = menu.addItem(withTitle: "Jump to Next Duplicate ID",
                                action: NSSelectorFromString("jumpToNextDuplicateID:"), keyEquivalent: "d")
        jump.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let previousTab = menu.addItem(withTitle: "Show Previous Tab",
                                       action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        let nextTab = menu.addItem(withTitle: "Show Next Tab",
                                   action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Move Tab to New Window",
                     action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Merge All Windows",
                     action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }
}

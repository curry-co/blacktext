import AppKit

/// The menu bar, built in code (no nib, nothing to load at launch).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "BlackText")
        let delegate = NSApp.delegate as? AppDelegate
        menu.addItem(item("About BlackText", #selector(AppDelegate.showAbout(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Allow Agents to Edit", #selector(AppDelegate.toggleAgentsCanEdit(_:)), target: delegate))
        menu.addItem(item("Copy MCP Config", #selector(AppDelegate.copyMCPConfig(_:)), target: delegate))
        menu.addItem(item("Install Command Line Tool…", #selector(AppDelegate.installCommandLineTool(_:)), target: delegate))
        menu.addItem(item("iCloud Sync…", #selector(AppDelegate.showSyncStatus(_:)), target: delegate))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide BlackText", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit BlackText", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Note", #selector(MainWindowController.newNote(_:)), "n"))
        menu.addItem(item("File Note Away", #selector(MainWindowController.fileNoteAway(_:)), "\r"))
        menu.addItem(.separator())
        menu.addItem(item("Delete Note", #selector(MainWindowController.deleteCurrentNote(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Export All as Text…", #selector(AppDelegate.exportAllAsText(_:)), target: NSApp.delegate as? AppDelegate))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(MainWindowController.showFind(_:)), "f"))
        find.addItem(item("Find and Replace…", #selector(MainWindowController.showFindAndReplace(_:)), "f", [.command, .option]))
        find.addItem(item("Search All Notes…", #selector(MainWindowController.showSearchAllNotes(_:)), "f", [.command, .shift]))
        find.addItem(.separator())
        find.addItem(item("Find Next", #selector(MainWindowController.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(MainWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        find.addItem(item("Use Selection for Find", #selector(MainWindowController.useSelectionForFind(_:)), "e"))
        find.addItem(.separator())
        find.addItem(item("Highlight All", #selector(MainWindowController.toggleHighlightAll(_:)), "a", [.command, .option]))
        find.addItem(item("Match Case", #selector(MainWindowController.toggleFindMatchCase(_:)), "c", [.command, .option]))
        find.addItem(item("Whole Word", #selector(MainWindowController.toggleFindWholeWord(_:)), "w", [.command, .option]))
        find.addItem(item("Regular Expression", #selector(MainWindowController.toggleFindRegex(_:)), "r", [.command, .option]))
        find.addItem(.separator())
        find.addItem(item("Replace All", #selector(MainWindowController.replaceAllMatches(_:)), "\r", [.command, .option]))
        menu.addItem(submenu(find))

        let spelling = NSMenu(title: "Spelling")
        spelling.addItem(item("Check Spelling While Typing", #selector(MainWindowController.toggleSpellChecking(_:))))
        menu.addItem(submenu(spelling))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Hide Sidebar", #selector(MainWindowController.toggleNoteSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Dark Mode", #selector(MainWindowController.toggleTheme(_:)), "l", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(MainWindowController.biggerText(_:)), "+"))
        let bigger = item("Bigger", #selector(MainWindowController.biggerText(_:)), "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        menu.addItem(bigger)
        menu.addItem(item("Smaller", #selector(MainWindowController.smallerText(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(MainWindowController.actualSizeText(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Previous Note", #selector(MainWindowController.previousNote(_:)), up, [.command, .option]))
        menu.addItem(item("Next Note", #selector(MainWindowController.nextNote(_:)), down, [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Recently Deleted", #selector(MainWindowController.showRecentlyDeleted(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("BlackText", #selector(AppDelegate.showMainWindow(_:)), "1", target: NSApp.delegate as? AppDelegate))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("BlackText on GitHub", #selector(AppDelegate.openRepository(_:)), target: NSApp.delegate as? AppDelegate))
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.openShortcuts(_:)), target: NSApp.delegate as? AppDelegate))
        return menu
    }
}

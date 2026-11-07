import UIKit

/// The Mac's keyboard map (PLAN.md §3) for a hardware keyboard on iPad.
/// The actions live on MainViewController, which sits at the top of the responder chain;
/// its canPerformAction does what the Mac's menu validation does. ⌘Z is UIKit's own undo.
@MainActor
enum KeyCommands {
    private static func command(_ title: String, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector,
                                hidden: Bool = false) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        // Ours, even when the text view has an idea of its own for the key.
        command.wantsPriorityOverSystemBehavior = true
        if hidden { command.attributes = .hidden }
        return command
    }

    static func make() -> [UIKeyCommand] {
        let up = UIKeyCommand.inputUpArrow
        let down = UIKeyCommand.inputDownArrow
        return [
            command("File Note Away", "\r", .command, #selector(MainViewController.fileNoteAway)),
            command("New Note", "n", .command, #selector(MainViewController.newNote)),
            command("Toggle Sidebar", "s", [.command, .control], #selector(MainViewController.toggleNoteSidebar)),
            command("Previous Note", up, [.command, .alternate], #selector(MainViewController.previousNote)),
            command("Next Note", down, [.command, .alternate], #selector(MainViewController.nextNote)),

            command("Find", "f", .command, #selector(MainViewController.showFind)),
            command("Find and Replace", "f", [.command, .alternate], #selector(MainViewController.showFindAndReplace)),
            command("Search All Notes", "f", [.command, .shift], #selector(MainViewController.showSearchAllNotes)),
            command("Find Next", "g", .command, #selector(MainViewController.findNextMatch)),
            command("Find Previous", "g", [.command, .shift], #selector(MainViewController.findPreviousMatch)),
            command("Use Selection for Find", "e", .command, #selector(MainViewController.useSelectionAsSearch)),
            command("Highlight All", "a", [.command, .alternate], #selector(MainViewController.toggleHighlightAll)),
            command("Match Case", "c", [.command, .alternate], #selector(MainViewController.toggleFindMatchCase)),
            command("Whole Word", "w", [.command, .alternate], #selector(MainViewController.toggleFindWholeWord)),
            command("Regular Expression", "r", [.command, .alternate], #selector(MainViewController.toggleFindRegex)),
            command("Replace All", "\r", [.command, .alternate], #selector(MainViewController.replaceAllMatches)),

            command("Bigger", "+", .command, #selector(MainViewController.biggerText)),
            command("Bigger", "=", .command, #selector(MainViewController.biggerText), hidden: true),
            command("Smaller", "-", .command, #selector(MainViewController.smallerText)),
            command("Actual Size", "0", .command, #selector(MainViewController.actualSizeText)),
            command("Light / Dark", "l", [.command, .control], #selector(MainViewController.toggleTheme)),

            command("Close", UIKeyCommand.inputEscape, [], #selector(MainViewController.escape), hidden: true),
        ]
    }
}

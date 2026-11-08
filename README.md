# BlackText

**BlackText is a plain-text notepad for the Mac that saves everything and adds nothing.**

BlackText is a single page for typing. There's no formatting, no choice of fonts and no styles, just plain text in light or dark.

It saves as you type and keeps a timestamped version of each note as it grows. You never press Save and you never lose a word. When you're done with a thought, ⌘↩ files it away and gives you a clean page. It's made for the things you jot down for a moment: an idea, a quote, a link, or a paragraph from an email you want to rewrite.

Find & replace is instant, in one note or across all of them. BlackText opens as fast after ten years of notes as it did on the first day. Your AI agents, like Claude, GPT and Grok, can read, search and write to it.

It runs on your Mac and keeps everything in one file that belongs to you. It needs no account, and it's open source. Signed releases can keep your notes in step across your devices through your own private iCloud; nothing else ever sees them.

- **Plain text only.** One font, one size, black and white. Paste strips formatting.
- **Never lose a word.** Saved about a second after you pause. A version every 100 words changed. If a save ever fails, it says so and keeps a copy.
- **⌘↩ files the note away** and gives you a fresh one. ⌘Z brings it back.
- **Find & replace** that's live as you type: one match at a time or all at once, inverted highlights, match marks, whole word, regex, preserve case, and search across every note.
- **Fast at any size.** Launch does the same work after ten years as on day one.
- **Agents welcome.** A built-in MCP server lets Claude, Codex, Cursor and others read, search and write your notes.

## Nothing added

I take my coffee black. I wanted my notes the same way: nothing added.

**Text is enough.** Words don't need bold, fonts or colors to matter. Every style is a decision made instead of a thought finished.

**Saving is the app's job.** You should never have to press Save, and you should never lose a word.

**Fast, forever.** My last editor took five to eight minutes to open. A notepad should be ready before the thought is gone, on day one and in year ten.

**A clean page is one keystroke away.** Most notes are for now: write it, file it, move on. It's still there if you need it.

**History is honest.** Each version is saved when it happened. You can edit any note, but you can't rewrite the past.

**Your notes are yours.** They live in one file on your machine, with no account and no lock-in. With iCloud sync on, they also go to your own private iCloud database, encrypted in transit and on Apple's servers (and end to end, if you turn on Advanced Data Protection), and to nowhere else. It's open source, so you never have to take my word for it.

**Agents are guests.** They can read, search and write. They can't delete, and every change they make is saved as a version with their name on it.

**When in doubt, leave it out.**

## Install

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.

```bash
git clone https://github.com/curry-co/blacktext.git
cd blacktext
make install
```

This builds `BlackText.app`, puts it in `~/Applications`, and links the `blacktext` command into `~/.local/bin`.

## Using it

The sidebar lists your notes, most recently edited first. The **+** at the top (or ⌘↩) files the current note away and starts a new one right below it. Click any note to keep editing it; editing an old note moves it back to the top.

Each note keeps its own history. Click the arrow beside a note to see its versions; click one to read it. Versions are read-only: copy from them, or start a new note from one. Nothing is ever saved "in the past".

Closing the window keeps BlackText running. **⌃⌥B** anywhere shows or hides it.

<a name="keyboard"></a>
### Keyboard

| Keys | Action |
|---|---|
| ⌘↩ / ⌘N | File this note away, start a new one (⌘Z undoes) |
| ⌃⌘S | Toggle sidebar |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next note |
| ⌘F | Find |
| ⌥⌘F | Find & replace |
| ⇧⌘F | Search all notes |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘E | Find the selected text |
| ↩ / ⇧↩ (in find) | Next / previous |
| ⌥⌘A | One at a time / highlight all |
| ⌥⌘C / ⌥⌘W / ⌥⌘R | Match case / whole word / regex |
| ↩ (in replace) | Replace this one, go to next |
| ⌥⌘↩ | Replace all |
| Esc | Close find (the match stays selected, so you can type over it) |
| ⌘+ / ⌘− / ⌘0 | Text size |
| ⌃⌘L | Light / dark |
| ⌃⌥B | Show / hide BlackText from anywhere |
| ⌫ (in the sidebar) | Move a note to Recently Deleted (kept 30 days) |

### Sending text in

- **Services**: select text in any app → right-click → Services → **New BlackText Note**.
- **URLs**: `blacktext://new?text=…` and `blacktext://append?text=…` (for Raycast, Alfred, Shortcuts).
- **Shell**: `pbpaste | blacktext new`.

## Agents

BlackText speaks [MCP](https://modelcontextprotocol.io). For Claude Code:

```bash
claude mcp add blacktext -- ~/Applications/BlackText.app/Contents/Helpers/blacktext mcp
```

For Claude Desktop, Cursor and others, choose **BlackText → Copy MCP Config** and paste it into the app's MCP settings.

| Tool | What it does |
|---|---|
| `list_notes` | Recent notes: title, dates, word count |
| `read_note` | A note's full text (default: the open one) |
| `search` | Search all notes, with snippets |
| `list_versions` / `read_version` | A note's history |
| `create_note` | A new note in the sidebar; never touches the canvas |
| `append_to_current` | Adds to the open note, live and undoable |
| `replace_in_note` | Find & replace in a note, with a version saved first |
| `edit_status` | What became of an edit that was still queued when it returned |

Agents can't delete. Uncheck **BlackText → Allow Agents to Edit** to make them read-only. While the app is running, agent edits go through it, so they never overwrite what you're typing. Every agent edit is recorded as a version tagged with the agent's name. An edit lands on the note it was aimed at when it was asked for, even if you've moved to another note by the time it's applied, and it's applied once. If the app is busy, the call returns `queued` with a request to ask about.

The agent name is a label the agent gives itself, not proof of who it is. Anything running as you can read and write the notes file directly, so the read-only setting keeps well-behaved agents in line; it isn't a security boundary.

## The `blacktext` command

```
blacktext list [-n COUNT]          Recent notes
blacktext cat [ID]                 Print a note (default: the open one)
blacktext search QUERY [--case] [--word] [--regex]
blacktext new [TEXT…]              New note from TEXT or stdin
blacktext append [TEXT…]           Append to the open note
blacktext replace FIND REPLACE [--note ID] [--first] [--preserve-case]
blacktext versions ID / version ID
blacktext status REQUEST           What became of a queued edit
blacktext mcp                      MCP server on stdio
```

Add `--json` to `list`, `cat`, `search` and `versions` for machine-readable output. Put `--` before text that starts with a dash: `blacktext append -- "-30 degrees"`.

## Your data

Everything lives in one SQLite file: `~/Library/Application Support/blacktext/blacktext.sqlite`. Time Machine backs it up, and any SQLite tool can open it.

- **File → Back Up Notes…** writes a complete copy, history and Recently Deleted included. To restore it, quit BlackText and put it in place of the file above; it won't sync until you turn sync back on, and then it's merged with iCloud, keeping both texts wherever a note differs.
- **File → Export All as Text** writes every note as a `.txt` file.
- Before a new version of BlackText changes the file's layout, it copies it to `Backups` next to it. An older BlackText won't open a file a newer one has changed; it says to update instead.
- If a save ever fails (a full disk, say), BlackText says so above the note, keeps retrying, and writes the text to `Recovered` next to the file in the meantime. Quitting with unsaved changes asks first.
- Emptying a note keeps what it said as a version, and an emptied note you leave goes to Recently Deleted for 30 days.
- A crash of the app never loses a save. SQLite runs in write-ahead mode with `synchronous = NORMAL`, so a power cut or a crash of macOS itself can lose the last few saves before it.

## iCloud sync

Releases signed by the project (not builds you make yourself) sync through a private CloudKit database in your iCloud account: every note, its history and Recently Deleted. When two devices change a note at once, the newer text wins and the other is kept as a version, labeled with the device it came from.

Sync stops and asks before doing anything if you delete BlackText's data from iCloud (Settings), reset your encrypted iCloud data, or sign in to a different iCloud account. The notes on the device are always kept. **BlackText → iCloud Sync…** shows what's waiting to be sent and anything iCloud refused.

## Speed

`make bench` builds a database simulating 10 years of heavy use and times what BlackText does with it. Results on an Apple Silicon Mac:

10 years at 10,000 words a day: **58,419 notes, 364,210 versions, 40.5 million words, a 1.9 GB database.**

| | Time |
|---|---|
| Open the database | 0.2 ms |
| Load the open note | < 0.1 ms |
| First sidebar page (200 notes) | 0.1 ms |
| Open any older note | < 0.1 ms |
| Search all notes: "the", "coffee", a rare word, a whole word | 11–16 ms |
| Search all notes: a phrase | 43 ms |
| Search all notes: two letters, or a regex (no index; runs in the background, cancelled as you type) | 0.2 s / 2.3 s |
| Find in a 100,000-word note | 3.5 ms |
| Launch, process start to the window drawn with the cursor in your note | ~270–310 ms |
| Quit | < 1 ms |

For scale, an empty AppKit window with one text view takes about 220 ms on the same Mac. Launch time comes from drawing the window, not from your history: everything BlackText reads at launch takes under a millisecond with ten years of notes. Search reads the newest notes directly first, then streams older ones from a full-text index (trigram for substrings, words for whole words), so common and rare words are both fast.

## Development

```bash
make test      # unit tests
make app       # build/BlackText.app
make run       # build and open it
make bench     # seed 10 years of notes and measure
```

`BLACKTEXT_DB=/path/to/test.sqlite` points the app and the CLI at a different database. The code:

- `Sources/BlackTextCore`: storage, versioning, search, find & replace, agents, MCP. No UI; tested.
- `Sources/BlackTextApp`: the AppKit app.
- `Sources/blacktext`: the command-line tool.
- `Sources/blacktext-bench`: the benchmark.

See [PLAN.md](PLAN.md) for the design.

## License

MIT

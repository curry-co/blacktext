# BlackText

> One page. Plain text. Nothing added.

BlackText (blktxt) is a native macOS notepad. One canvas to type in, saved continuously, with automatic version history, fast find & replace, and a door for AI agents. No formatting, no account, no cloud.

- **Plain text only.** One font, one size, black and white. Paste strips formatting.
- **Never lose a word.** Saved about a second after you pause. A version every 100 words changed.
- **⌘↩ files the note away** and gives you a fresh one. ⌘Z brings it back.
- **Find & replace** that's live as you type: one match at a time or all at once, inverted highlights, match marks, whole word, regex, preserve case, and search across every note.
- **Fast at any size.** Launch does the same work after ten years as on day one.
- **Agents welcome.** A built-in MCP server lets Claude, Codex, Cursor and others read, search and write your notes.

## Install

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.

```bash
git clone https://github.com/curry-co/blktxt.git
cd blktxt
make install
```

This builds `BlackText.app`, puts it in `~/Applications`, and links the `blktxt` command into `~/.local/bin`.

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
- **URLs**: `blktxt://new?text=…` and `blktxt://append?text=…` (for Raycast, Alfred, Shortcuts).
- **Shell**: `pbpaste | blktxt new`.

## Agents

BlackText speaks [MCP](https://modelcontextprotocol.io). For Claude Code:

```bash
claude mcp add blktxt -- ~/Applications/BlackText.app/Contents/Helpers/blktxt mcp
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

Agents can't delete. Uncheck **BlackText → Allow Agents to Edit** to make them read-only. While the app is running, agent edits go through it, so they never overwrite what you're typing. Every agent edit is recorded as a version tagged with the agent's name.

## The `blktxt` command

```
blktxt list [-n COUNT]          Recent notes
blktxt cat [ID]                 Print a note (default: the open one)
blktxt search QUERY [--case] [--word] [--regex]
blktxt new [TEXT…]              New note from TEXT or stdin
blktxt append [TEXT…]           Append to the open note
blktxt replace FIND REPLACE [--note ID] [--first] [--preserve-case]
blktxt versions ID / version ID
blktxt mcp                      MCP server on stdio
```

Add `--json` to `list`, `cat`, `search` and `versions` for machine-readable output.

## Your data

Everything lives in one SQLite file: `~/Library/Application Support/blktxt/blktxt.sqlite`. Time Machine backs it up. **File → Export All as Text** writes every note as a `.txt` file. Any SQLite tool can open it.

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

`BLKTXT_DB=/path/to/test.sqlite` points the app and the CLI at a different database. The code:

- `Sources/BlktxtCore`: storage, versioning, search, find & replace, agents, MCP. No UI; tested.
- `Sources/BlktxtApp`: the AppKit app.
- `Sources/blktxt`: the command-line tool.
- `Sources/blktxt-bench`: the benchmark.

See [PLAN.md](PLAN.md) for the design.

## License

MIT

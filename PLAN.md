# BlackText — plan

> One page. Plain text. Nothing added.

BlackText is a native macOS notepad with one canvas, continuous autosave, automatic version history, the best find & replace we can build, and a door for AI agents. The repo, the command-line tool and the data folder are named `blktxt`. This document is the build spec. All open questions are decided (see the last section).

---

## 1. Principles

1. **Nothing added.** No bold, no headings, no colors, no formatting toolbar. One font, one size, black and white. Pasted text arrives as plain text. Even the selection and the cursor are monochrome.
2. **Never lose a word.** Typing is saved within about a second. Every big change (100 words, ⌘↩, Replace All, an agent edit) leaves a version you can go back to.
3. **Launch cost is constant.** Opening the app does the same small amount of work after ten years as on day one. Nothing on launch scales with how much you've written.
4. **Keyboard first.** Everything can be done without the mouse. The mouse still works for everything.
5. **Your data is yours.** One local file, readable by standard tools, exportable as plain `.txt`, reachable by your agents. No account, no cloud, no telemetry.

---

## 2. The experience

### Window

```
┌─────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [▤]                                                    [☾]  │
├──────────────────┬──────────────────────────────────────────────────┤
│ Today            │                                                  │
│ Rewrite for Sam  │  Thanks for sending this over. I read it twice   │
│ 2:14 PM · 340 w  │  and I think the second paragraph is doing all   │
│                  │  the work, so I'd lead with it.|                 │
│ "The obstacle is │                                                  │
│ 11:02 AM · 18 w  │                                                  │
│ https://example… │                                                  │
│ 9:40 AM · 1 w    │                                                  │
│                  │                                                  │
│ Yesterday        │                                                  │
│ › Notes on prici │                                                  │
│ 4:31 PM · 1,204 w│                                                  │
└──────────────────┴──────────────────────────────────────────────────┘
```

- One window. Transparent title bar: traffic lights, a sidebar toggle, and the sun/moon toggle. No window title, no toolbar, no status bar.
- Opens with the cursor in the canvas at the end of your text, ready to type.
- No placeholder text on an empty canvas. Just the cursor.
- Remembers its size and position, and whether the sidebar is open.
- Closing the window keeps BlackText running; **⌃⌥B** anywhere on your Mac shows or hides it instantly. ⌘Q quits.

### Text: no styles

- Font: the macOS system font (SF Pro), regular weight, 15 pt, comfortable line spacing.
- ⌘+ / ⌘− / ⌘0 change the size of all text on screen (a view setting, not formatting).
- The editor is plain-text only, at the engine level. Bold/italic/fonts don't exist in it, so they can't sneak in.
- Paste always strips formatting. Paste from a web page, Mail, Docs: you get the words.
- Spell-check underlines on. Smart quotes, smart dashes, autocorrect, and auto-capitalization off, so links, code, and quoted text stay exactly as pasted.
- Text column capped at a readable width (about 70 characters) and centered when the window is wide.
- ⌘-click a URL to open it. No blue underline, no link styling.

### ⌘↩ and the + button — file it away

- Saves the note (and a version) and starts a new, empty note, which appears at the top of the sidebar right under the **+** button.
- The **+** button sits at the very top of the sidebar: a 50% gray rounded rectangle with a + in the middle. On hover it turns solid black (light mode) or solid white (dark mode); once clicked it goes back to gray.
- A new note left empty disappears when you move on, so the sidebar never fills with blanks.
- ⌘Z immediately afterward brings it back, in case you hit it by accident.
- Only works when the cursor is in the canvas (not while you're typing in the find bar).
- Does nothing on an empty canvas.
- ⌘N does the same thing (standard "New").

### Notes and their history

The rule that keeps this simple: **you only ever edit the present version of a note, and every note keeps its own history.**

- The sidebar lists your notes, **most recently edited first**, grouped under quiet date headers (Today, Yesterday, Previous 7 Days, Previous 30 Days, then months, then years).
- Each row: first line of the note, time, word count. Secondary text in gray. Nothing else.
- **Click a note** and it opens in the canvas, editable. What you were writing is already saved.
- **Editing an old note** moves it to the top of the sidebar, because you edited it today. Its new versions are dated today, after its old ones. Nothing is ever saved "in the past" and there are no branches: a note's history is one straight line, sometimes with a gap in it.

```
Notes on pricing                today · 1,240 w
  Oct 28  2:14 PM   1,240 w     ← today's edits
  Oct 28  2:09 PM   1,180 w
  · · ·  6 months  · · ·
  Apr 12  4:31 PM   1,204 w     ← filed with ⌘↩ in April
  Apr 12  4:20 PM   1,100 w
```

- **Versions are read-only.** A note's versions are tucked underneath it, collapsed; → or a click on the disclosure arrow shows them. Clicking a version shows it in the canvas read-only with a thin bar: `Oct 28, 2:10 PM · 1,100 words · Copy · New Note from This · Done`. Select and copy any part of it, or start a new note (dated today) from it.
- **There is no Restore.** To recover a deleted paragraph: open the version, copy it, Esc, paste. To bring back a whole version: copy all, paste over. That's a big change, so a version is saved automatically and the history shows exactly what happened.
- ⌥⌘↑ / ⌥⌘↓ move to the previous/next note without touching the mouse.
- Deleting: ⌫ (or ⌘⌫) on a selected note moves it to **Recently Deleted**, purged after 30 days. ⌘Z undoes. View → Recently Deleted shows them, with Put Back.
- The list is paged: it only loads the rows near what's on screen, so it's instant with 10 notes or 100,000.

### Light and dark

- One toggle in the top-right of the title bar: it shows ☀ in light mode and ☾ in dark; click to flip. Also ⌃⌘L.
- First launch follows the system setting; once you click, your choice sticks.
- Everything is monochrome:

| | Light | Dark |
|---|---|---|
| Background | white `#FFFFFF` | black `#000000` |
| Text | black `#000000` | near-white `#EDEDED` |
| Selection | black at 15% | white at 25% |
| Find match | white text on black | black text on white |
| Row with a match | black at ~6% | white at ~10% |

---

## 3. Find & replace

The goal is the fastest find & replace you've used: live as you type, fully keyboard driven, and visually unmistakable.

### Find bar (⌘F)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  coffee                 3 of 17  ‹ ›   One | All   Aa  W  .*   Note | All notes  ✕ │
│  tea                    Replace   Replace All (17)    Preserve case                 │
└──────────────────────────────────────────────────────────────────────────┘
```

- Slides down at the top of the canvas and pushes the text down (it never covers a line).
- Opens with your selected text already in it (selected, so typing replaces it).
- Results update on every keystroke. On very large notes the search runs off the main thread and stale searches are cancelled, so typing in the field never stutters.
- **One at a time / Highlight all** toggle (remembered):
  - *One at a time*: only the current match is inverted and its row is faintly tinted. ↩ moves to the next one.
  - *Highlight all*: every match is inverted and every row containing one is faintly tinted; the current match's row is tinted a little more strongly so you always know where you are.
- "Row" means the visual line on screen, so with wrapped paragraphs only the line that holds the match is tinted.
- **Match marks**: a small tick at the right edge of the canvas for every match, so you can see where they cluster in a long note. Click a tick to jump there.
- Toggles: match case (Aa), whole word (W), regular expression (.\*). An invalid regex shows "invalid" where the count goes. No red.
- Esc closes the bar and leaves the current match selected, so you can just start typing to change it.
- ↑ / ↓ in the field cycles through recent searches.

### Replace (⌥⌘F)

- Same bar with a second row. Tab moves between the two fields.
- ↩ in the replace field: replace this match, jump to the next.
- ⌥⌘↩: Replace All. The button shows the count (`Replace All (17)`) before you commit.
- Replace All is a single ⌘Z, and it saves a version first.
- **Preserve case** toggle: replacing `coffee` with `tea` turns `Coffee` into `Tea` and `COFFEE` into `TEA`.
- Regex replacements support `$1`-style groups.

### Search all notes (⇧⌘F)

- The same find bar with its scope set to **All notes**. The sidebar becomes a results list: note title, date, match count, and a snippet with the match inverted.
- ↑/↓ move through results and show each note in the canvas with its matches highlighted. ↩ / ⇧↩ step through matches inside it. Esc closes the bar and returns the sidebar to normal, leaving you in that note.
- Backed by a full-text index, so searching years of notes is fast. Partial words match (`coff` finds `coffee`), the same as find-in-note.

### Keyboard map

| Keys | Action |
|---|---|
| ⌘↩ / ⌘N | File this note away, blank canvas (⌘Z undoes) |
| ⌃⌘S | Toggle sidebar |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next note |
| ⌘F | Find |
| ⌥⌘F | Find & replace |
| ⇧⌘F | Search all notes |
| ⌘G / ⇧⌘G | Next / previous match (works with the bar closed) |
| ⌘E | Find the selected text |
| ↩ / ⇧↩ (in find) | Next / previous |
| ⌥⌘A | Toggle One at a time / Highlight all |
| ⌥⌘C / ⌥⌘W / ⌥⌘R | Match case / whole word / regex |
| ↩ (in replace) | Replace this one, go to next |
| ⌥⌘↩ | Replace all |
| Esc | Close find, or leave a version preview |
| ⌘+ / ⌘− / ⌘0 | Text size |
| ⌃⌘L | Light / dark |
| ⌃⌥B (anywhere) | Show / hide BlackText |

---

## 4. Saving and versions

### How autosave works (and why it costs nothing)

Apple Notes and other Mac document apps save shortly after you pause and again when you switch away or quit. Google Docs sends small batches of edits to its server every fraction of a second and groups them into revisions by time. Neither writes on every keystroke, and neither needs to.

BlackText does the same thing, locally:

- A keystroke only marks the note as changed. No disk activity.
- A save happens 1 second after you stop typing, and at least every 5 seconds if you never stop.
- It also saves immediately on ⌘↩, switching notes, leaving the app, closing the window, and quitting.
- A save writes one row (the note you're in) on a background thread. For a typical note that's a few kilobytes and about a millisecond.
- When you're not typing there are no timers and no background work. CPU use at idle is zero.
- On a sudden power cut, the most you can lose is the last second or so of typing.

### Versions: every 100 words, done right

Versions count **words changed**, not the net word count. If you rewrite a paragraph of an email in place, the word count barely moves but the text is completely different; counting words typed *plus* words deleted catches that.

A version is saved when:

- about 100 words have been typed or deleted since the last version;
- you press ⌘↩, switch to another note, or quit (if anything changed since the last version);
- right before a Replace All or any agent edit, so every large change is one click from recoverable.

Versions are stored compressed (Apple's built-in LZFSE) and loaded only when you open a note's version list. Each version records who made it (you, or which agent).

---

## 5. Staying fast after years

Slow launches almost always mean an app is doing work on startup that grows with your data: restoring every past document, re-indexing files, rebuilding lists. BlackText is built so that can't happen:

- **Launch reads two things:** the note you were last in, and the first page of sidebar rows. Everything else (older rows, versions, search) loads only when you ask for it.
- **Native AppKit, no web view.** No Electron, no embedded browser.
- **The editor lays out lazily** (TextKit's non-contiguous layout), so even a huge pasted document opens and scrolls smoothly.
- **All disk work happens off the main thread**; typing never waits for a save.
- **Quitting is instant**: at most one small write, then exit.
- **Housekeeping (purging old deleted notes) runs after the window is up**, never before.

`make bench` generates a database simulating 10 years of heavy use and measures launch, quit, sidebar, search and find against these targets, so we know rather than hope.

| | Target | Measured at 10 years (40.5M words, 1.9 GB) |
|---|---|---|
| Launch (process start → window drawn, warm) | < 200 ms | ~270–310 ms (a bare AppKit window is ~220 ms) |
| Quit | < 50 ms | < 1 ms |
| Search all notes | < 50 ms typical | 11–43 ms indexed; 0.2–2.3 s for two-letter or regex queries |
| Open a note from the sidebar | < 16 ms | < 0.1 ms |
| Find in a 100,000-word note | live | 3.5 ms |

The launch target was tighter than macOS allows: an empty AppKit window with one text view already takes ~220 ms on this Mac. What matters held up: everything launch reads takes under a millisecond with ten years of notes, so launch doesn't grow with your history.

Search runs in two passes: the newest notes are read directly (fills results at once for common words), then older notes stream from an index (trigram for substrings, a word index for whole words), newest first, stopping at the result limit.

---

## 6. Agents

Agents connect through **MCP** (Model Context Protocol), the common standard for letting AI apps use tools. BlackText ships a small `blktxt` command-line tool inside the app that does double duty:

- `blktxt mcp` is an MCP server. For Claude Code, setup is one line: `claude mcp add blktxt -- blktxt mcp`. Claude Desktop, Codex, Cursor, and other apps that support local MCP servers take a JSON snippet; the app menu has **Copy MCP Config**.
- It's also a normal shell tool, useful to you and to agents that run shell commands:
  `blktxt search coffee` · `pbpaste | blktxt new` · `blktxt cat` · `blktxt append "..."`

### Agent tools

| Tool | What it does |
|---|---|
| `list_notes` | Recent notes: title, time, word count (paged) |
| `read_note` | Full text of a note, or the one currently open |
| `search` | Full-text search across all notes, with snippets |
| `list_versions` / `read_version` | A note's history |
| `create_note` | Adds a new note to the sidebar (never touches your canvas) |
| `append_to_current` | Adds text to the end of what you're writing. Appears live, undoable |
| `replace_in_note` | Find & replace in a note. A version is saved first |

- No delete for agents.
- **BlackText → Allow Agents to Edit** (on by default) switches agents to read-only when unchecked.
- While the app is running, agent edits are applied by the app itself, so an agent can never overwrite what you're mid-sentence on. If the app isn't running, agent changes go straight to the database and are there when you open it.
- Every agent edit shows up in the version list as made by that agent.

### ChatGPT, Grok, and other web chatbots

Agents running on your Mac work from day one. Chatbots that run in a browser or in the cloud can only reach servers on the internet, so connecting them means exposing BlackText through a secure tunnel with a token. That comes later, once the local version is solid.

---

## 7. Technology

| Choice | Why |
|---|---|
| **Swift + AppKit** | Native, fastest launch, full control over the editor. SwiftUI's text editor can't do the custom find highlighting, row tints, or match marks. |
| **NSTextView (TextKit 1, non-contiguous layout)** | Apple's mature text engine; plain-text mode; reliable temporary attributes for find highlighting. |
| **SQLite** (built into macOS) | One durable file, crash-safe, fast at any size. Its full-text index (FTS5, trigram) is built in. |
| **Apple Compression (LZFSE)** | Shrinks stored versions; built into macOS. |
| **No third-party dependencies** | Nothing to update or break; the whole app is readable in one repo. |
| **Swift Package Manager + a build script** | Builds a real `BlackText.app` from the terminal. Xcode is not required. |
| **Swift Testing** | Unit tests; included with the Command Line Tools. |
| **GitHub Actions** | Build and test on every push to `curry-co/blktxt`. |

- Minimum macOS: 14 Sonoma.
- Bundle ID: `co.curry.blktxt`.
- Data lives at `~/Library/Application Support/blktxt/blktxt.sqlite`, covered by Time Machine. **File → Export All as Text** writes every note as a `.txt` file.
- Not sandboxed (no App Store), which keeps the CLI and app sharing one database simple.

### Repo layout

```
blktxt/
  Package.swift
  Makefile                 make app · make run · make install · make test · make bench
  Sources/
    BlktxtCore/            storage, versioning, search, replace engine, agent service, MCP (no UI, tested)
    BlktxtApp/             the Mac app (AppKit)
    blktxt/                the command-line tool + MCP server
    blktxt-bench/          10-year database generator and timings
  Tests/BlktxtCoreTests/
  Resources/               Info.plist, app icon
  scripts/                 build-app.sh, make-icon.swift, bench.sh
  README.md  LICENSE  PLAN.md
```

### Data model

```
notes      id, created_at, updated_at, text, title, word_count, deleted_at
versions   id, note_id, created_at, word_count, source, body (compressed)
notes_fts    trigram full-text index over notes.text (substring search)
notes_words  word full-text index over notes.text (whole-word search)
state      current note, agent permission
inbox      agent edits waiting for the running app to apply them
```

---

## 8. Running it locally (no App Store)

```bash
make install
```

That builds a release version, signs it for local use, copies `BlackText.app` to `~/Applications`, and links the `blktxt` command into `~/.local/bin`. Apps you build yourself aren't quarantined, so macOS opens it without warnings. Later, to hand it to other people: an Apple Developer ID plus notarization, then GitHub Releases and a Homebrew cask.

---

## 9. Build order

1. **Core**: database, notes, versioning rule, search & replace engine, agent service, MCP, plus tests.
2. **App**: window, plain-text editor, autosave, ⌘↩ with undo, sun/moon, sidebar with versions.
3. **Find & replace**: find bar, One/All, inverted highlights and row tints, match marks, replace, search all notes.
4. **Agents**: `blktxt` CLI and MCP server; live append into the open canvas.
5. **Speed**: seed the 10-year database, measure every target in §5, fix anything over budget.
6. **Polish**: icon, menus, export, Services, URL scheme, README, CI.
7. **Verify**: launch the real app and drive it (light and dark, find in both modes, ⌘↩ and undo, sidebar, versions), and connect over MCP.

---

## 10. Ideas

**In v1:**

- **⌘Z after ⌘↩** brings the note back.
- **Services menu: "New BlackText Note"**: select text in any app → right-click → Services → it lands in BlackText.
- **Global hotkey ⌃⌥B** to show/hide BlackText from anywhere.
- **Match marks** and **preserve-case replace**.
- **Monochrome everything**, including selection and cursor.
- **`blktxt://new?text=…` URL** so Raycast, Alfred, and Shortcuts can send text in.

**Later:**

- Pin a note to the top.
- Auto-expire: ephemeral notes disappear after N days unless pinned.
- Compare two versions.
- Web-chatbot access through a secure tunnel.
- Shortcuts actions.
- iPhone app and sync.

---

## 11. Decisions

1. **History model:** notes sorted by last edited, each with its own straight-line history; versions are read-only (Copy, New Note from This); no Restore.
2. **Deleting:** Recently Deleted, purged after 30 days. No auto-expire in v1.
3. **Storage:** one SQLite file in Application Support, plus Export All as Text.
4. **Closing the window:** blktxt keeps running; ⌃⌥B shows/hides it.
5. **Dark mode:** pure black with near-white text; one sun/moon toggle that flips.
6. **Typing aids:** spell-check on; smart quotes/dashes/autocorrect off; readable column width.
7. **Agents:** read, search, create, append, find & replace (with versions); no delete; read-only switch.
8. **Housekeeping:** MIT license; macOS 14+; commits as jason@curry.co.

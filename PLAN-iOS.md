# BlackText for iPhone and iPad: plan

> The same one page, in your pocket, kept in step with your Mac through iCloud.

This is the build spec for the iOS version. The Mac spec is [PLAN.md](PLAN.md); everything there applies here unless this document says otherwise.

---

## 1. Decisions

| | Decision | Why |
|---|---|---|
| **Language** | Native Swift + UIKit, sharing `BlackTextCore` with the Mac app | One copy of every rule (versions every 100 words, titles, word counts, search, find & replace, merging edits), so the two apps can't drift or disagree. |
| **Not Expo / React Native** | Rejected | Expo Go can't use iCloud; React Native's text box can't do large-note speed, inverted find highlights or match marks; the rules would exist twice; hundreds of npm packages. |
| **Builds** | GitHub Actions (the repo's existing CI), no local Xcode needed | Its Macs have Xcode; free for public repos. |
| **Delivery** | TestFlight (internal testing), then the App Store | |
| **Sync** | CloudKit private database via `CKSyncEngine` | Apple's engine for exactly this: batching, retries, push notifications, account changes. |
| **Privacy** | Note text, titles and version bodies go in CloudKit *encrypted* fields | Encrypted in transit and on Apple's servers, and end-to-end encrypted with Advanced Data Protection. (This first said end-to-end even without it; Apple's documentation says otherwise.) |
| **Minimum OS** | iOS 17 (needed by `CKSyncEngine`); macOS stays 14 | |
| **Identifiers** | Bundle ID `co.curry.blacktext` on both; container `iCloud.co.curry.blacktext`; App Group `group.co.curry.blacktext` | The App Group lets a share extension reach the same database later. |

PLAN.md's principle 5 ("No account, no cloud") becomes: **your notes stay yours.** One local file on each device, synced only through *your* iCloud account, with the text encrypted in transit and on Apple's servers, and end to end with Advanced Data Protection. If you're not signed in to iCloud, or for builds without iCloud (like `make install`), BlackText works exactly as before, local only.

---

## 2. The experience: same app, touch instead of keys

```
┌───────────────────────────────┐
│ ▤        BLACKTEXT        ⌕ ☾ │
├───────────────────────────────┤
│ Thanks for sending this over. │
│ I read it twice and I think   │
│ the second paragraph is doing │
│ all the work, so I'd lead     │
│ with it.|                     │
│                               │
│                  ╭──────────╮ │
│                  │ Save+New │ │  ← rides just above the keyboard
├──────────────────╰──────────╯─┤
│  q  w  e  r  t  y  u  i  o  p │
└───────────────────────────────┘
```

| Mac | iPhone / iPad |
|---|---|
| One canvas, plain text only, 15 pt SF, readable column | Same. Column capped on iPad; full width on iPhone with comfortable margins. |
| Autosave 1 s after typing stops, at least every 5 s | Same (shared core), plus an immediate save when the app goes to the background. |
| A version every ~100 words changed, and on ⌘↩ / switching notes | Same (shared core). |
| **⌘↩ / ⌘N files the note away** | **Save+New button**: a small 50%-gray rounded rectangle labeled `Save+New`, the same style as the sidebar's + button. Bottom-right, riding just above the keyboard where your thumb already is (like a Send button); bottom-right of the screen when the keyboard is down. Turns solid black (light) / white (dark) while pressed. Hidden on an empty canvas. After a tap it becomes `Undo` in the same spot for 4 seconds, the touch version of ⌘Z. With a hardware keyboard, ⌘↩, ⌘N and ⌘Z work exactly as on the Mac. |
| Title bar: sidebar toggle, sun/moon | Top bar: sidebar toggle (left), `BLACKTEXT` centered (12 pt medium, letter-spaced), find (⌕) and sun/moon (right). Find gets a button because there's no ⌘F on glass. |
| Sidebar: + button, date groups, rows (title, time · words), versions under each note | iPhone: slides in from the left over the canvas; tap a note or swipe it away to close. iPad: a real sidebar beside the canvas. Same + button, groups, rows and version disclosure. |
| ⌫ on a note → Recently Deleted, Put Back | Swipe left on a row → Delete. Recently Deleted at the bottom of the sidebar, with Put Back. |
| Version preview bar: `date · words · Copy · New Note from This · Done` | Same bar, same actions. |
| Find bar: One/All, Aa, W, .*, Note/All notes, replace row, Replace All (n), preserve case, match marks | Same bar at the top of the canvas, the same toggles, live as you type, match marks on the right edge. Search all notes turns the sidebar into results, as on the Mac. |
| ⌘+ / ⌘− / ⌘0 text size | Starts from the system Text Size (Dynamic Type), so a larger system setting means larger notes. Pinch the canvas, or the same keys on a hardware keyboard, to go a point bigger or smaller from there. |
| Light / dark, monochrome caret and selection | Same colors, same toggle. First launch follows the system. |
| Spell-check on; smart quotes, dashes, autocorrect, auto-capitalization off | Same. |
| Paste strips formatting | Same. |
| `blacktext://new?text=…` | Same. |
| CLI, MCP for agents, ⌃⌥B, Services menu | Mac only. Agents edit on the Mac and the edits sync to the phone. iOS later gets a share-sheet "New BlackText Note" (its Services menu) and Shortcuts actions. |

---

## 3. Sync design

**Goal:** a change on one device shows up on the other within a few seconds while both are open, and as soon as the app opens otherwise. Nothing is ever lost.

### IDs and change tracking

- Notes and versions get a global `uid` (random UUID) via a schema migration. The integer `id`s stay as local keys, so nothing else in the app changes.
- **SQLite triggers** record every insert, update and delete of notes and versions in a `sync_outbox` table. That catches every writer: the app, the `blacktext` CLI and agents (even when the app isn't running), so no code path can forget to sync.
- Remote changes are applied in one transaction that also clears the outbox rows it caused, so a change never bounces back.

### Records (CloudKit private database, zone `Notes`)

| Record | Fields |
|---|---|
| `Note` (name = uid) | `text`, `title` *(encrypted)*; `createdAt`, `editedAt`, `deletedAt`, `wordCount`, `device` |
| `Version` (name = uid, parent = its Note) | `body` *(encrypted, LZFSE)*; `createdAt`, `wordCount`, `source` |

- A record's limit is 1 MB. Notes bigger than ~900 KB (about 150,000 words) travel as an asset instead of inline.
- Versions are append-only, so they never conflict.

### Timing: "as frequently as possible"

- **Send:** each autosave (1 s after you stop typing, at least every 5 s) queues the note, and the engine sends right away rather than waiting for its own schedule.
- **Receive:** CloudKit sends a silent push to the other devices, which fetch only what changed. Typical end to end: about 2 to 5 seconds. Also fetched on launch and whenever the app comes to the front.
- No polling and no timers at idle: the Mac's zero-CPU-at-idle promise holds.

### Conflicts: the newest wins, the other is kept

- Each note is one value; there's no character-by-character merge. That keeps it simple and predictable.
- If a note you have open changes on another device and you haven't typed since, the canvas updates in place and keeps your cursor.
- If both devices changed the same note, the most recently edited text becomes the note, and the other text is saved as a **version** marked with the device it came from. You can always see and copy it ("History is honest").
- Deleting moves to Recently Deleted on every device; Put Back syncs too. The 30-day purge deletes the record and its versions.

### Speed rules still hold

- Launch never waits for sync: it starts after the window is up, in the background.
- First sync on a new device downloads in batches while you work; the sidebar fills in as notes arrive.
- The 10-year benchmark database gets a sync benchmark: time to queue, send and apply a change at 100,000 notes.

---

## 4. Repo layout (one repo for both)

```
Package.swift                  BlackTextCore builds for macOS 14 and iOS 17
Sources/
  BlackTextCore/               shared: storage, versions, search, find & replace, agents, MCP
    Sync/                      CloudKit sync (shared by both apps)
  BlackTextApp/                Mac app (AppKit)
  blacktext/                   CLI + MCP server (Mac)
  blacktext-bench/
iOS/
  project.yml                  XcodeGen spec; CI generates BlackText.xcodeproj from it
  BlackText/                   UIKit app: editor, sidebar, find bar, Save+New, theme
  BlackText.entitlements
Resources/                     Mac Info.plist and icon (the iOS icon comes from the same script)
.github/workflows/
  ci.yml                       Mac: test, build, benchmark (unchanged)
  ios.yml                      iOS: build, core tests on the Simulator, screenshots, TestFlight
```

---

## 5. Build and delivery

- `ios.yml` runs on pushes to `ios` branches:
  1. Generate the Xcode project from `project.yml`.
  2. Run the core tests on the iOS Simulator.
  3. Launch the app in the Simulator and save screenshots (light, dark, sidebar, find, Save+New) as build artifacts, so changes can be checked without a phone.
  4. Archive, sign and upload to TestFlight, when the signing secrets are set.
- Repo secrets: an App Store Connect API key with Admin access (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`). Xcode uses it to sign automatically, so no certificates or profiles are stored in the repo.
- Build number: the GitHub run number. Version: the same `Version.swift` as the Mac.

### Apple account setup

1. App ID `co.curry.blacktext` with iCloud (CloudKit), Push Notifications and App Groups.
2. iCloud container `iCloud.co.curry.blacktext`; App Group `group.co.curry.blacktext`.
3. Signing for TestFlight: automatic, through the API key in CI.
4. A macOS Developer ID provisioning profile with iCloud (gives the Mac app sync).
5. An App Store Connect app record for iOS.
6. Testers invited to the team; an internal TestFlight group.
7. CloudKit schema: created by a development build of the Mac app syncing for real, then deployed to Production in CloudKit Console (TestFlight and Developer ID builds use Production).

---

## 6. Build order

1. **Core sync:** `uid` migration, outbox triggers, the CloudKit record mapping, conflict rules, the sync engine, and tests (everything except the network is tested with a fake CloudKit).
2. **Mac sync:** entitlements and the Developer ID profile, push registration, live canvas updates. Verified on this Mac against CloudKit's Development environment.
3. **iOS app:** the UIKit port with Save+New; CI builds and screenshots it.
4. **Account setup and TestFlight:** the first build to testers.
5. **Parity and sync testing:** walk the table in §2 on both devices; edit the same note on both, offline edits, a 150,000-word note, deletes and Put Back, sign out of iCloud.
6. **Later:** share extension, Shortcuts, iPad keyboard polish, App Store release.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Two devices edit the same note at the same moment | Newest wins; the other text is kept as a version, so nothing is lost. |
| iOS suspends apps in the background | Sync on launch and on coming to the front; silent push wakes it for changes. |
| CloudKit's 1 MB record limit | Big notes go as assets. |
| A user isn't signed in to iCloud | Local only, exactly as today; sync starts when they sign in. |
| Apple's first notarization of the Mac app takes hours | A one-time delay for a new team; later ones take minutes. |

# Going public

`curry-co/blacktext` is public and MIT-licensed. It already has the Mac app, and pull request #1 adds the iPhone and iPad app and iCloud sync. This plan covers what the project needs before anyone is pointed at it:

- GitHub settings, branch rules and security.
- The name, description, topics and README.
- How releases ship.

Each section gives the exact values, plus the commands where a setting can be scripted. Section 12 is the order of work, and section 13 lists the decisions that are yours.

## Where things stand

Audited 2026-11-07.

| Area | Now | Target |
|---|---|---|
| `main` | Unprotected | Ruleset: changes only through PRs, checks must pass, no force pushes or deletion |
| Release tags | None, unprotected | `v*` tags only from admins; `v0.1.0` first |
| Secret scanning, push protection | Off | On |
| Vulnerability reports | Off; no `SECURITY.md` | Private reporting on, with `SECURITY.md` |
| Dependabot | Alerts on; security updates off; no version updates | All three, weekly for Actions |
| Code scanning | Not set up (GitHub detects Swift and Actions) | CodeQL default setup |
| Actions | Any action allowed, versions unpinned; token is read-only by default | GitHub-owned and verified actions only, pinned to commits |
| Signing secrets | An App Store Connect **Admin** key in repo-wide secrets | Least privilege, scoped to environments that need approval |
| Description | "One page. Plain text. Autosave. Versioning." | Names the platforms and sync |
| Topics, homepage, social image | None | 20 topics, a GitHub Pages site, a 1280×640 image |
| Community files | README and LICENSE (GitHub's health score: 50%) | Contributing, security, conduct, issue and PR templates, owners |
| README | Mac only; promises "no account and no cloud" | Mac, iPhone and iPad; download first; sync and privacy explained |
| Wiki, Projects | On, unused | Off |
| Organization | Free plan; 2FA not required; one admin (you) | 2FA required |

## 1. Fix before announcing

1. **Encrypt large note attachments.**
   - *The gap.* `CloudSync` stores a note or version body in `encryptedValues`, which is end-to-end encrypted. A body over about 900 KB compressed goes up as a `CKAsset` instead, and assets are end-to-end encrypted only for people who have turned on Advanced Data Protection.
   - *Your notes.* None of them come close (the largest is 4 KB), but a pasted log file could.
   - *The fix.* Encrypt the asset file with AES-GCM (CryptoKit), using a new 256-bit key for each record, and store that key in `encryptedValues["bodyKey"]`. Add a round-trip test. TestFlight build 4 can't read the new format, so replace it.
   - *Until then,* the README and site describe the exception rather than claiming everything is encrypted. The PR description already does.
2. **Give the two CI jobs distinct names.** Both workflows call their job `build`, and a ruleset matches required checks by job name. Rename them `mac` (in `ci.yml`) and `ios` (in `ios.yml`).
3. **Take the Admin key out of GitHub.** See section 4.
4. **Rewrite the README.** It currently promises "no account and no cloud". See section 8.
5. **Merge PR #1** once sync has been tried between a real iPhone and the Mac. Use a rebase merge to keep its commits, since the history explains the sync design.

Steps 1 and 2 belong on the `ios` branch, so they ship inside PR #1.

## 2. Repository settings

| Setting | Value | Why |
|---|---|---|
| Description | "A plain-text notepad for Mac, iPhone and iPad. Saves as you type, keeps every version, syncs through iCloud." | Says what it is and where it runs in one line (section 7 has alternatives) |
| Website | `https://curry-co.github.io/blacktext/` (or a custom domain) | Section 10; the App Store also needs privacy and support URLs |
| Topics | The 20 in section 7 | How people find it in GitHub search |
| Social preview | 1280×640: black, the white "bt" mark, "BlackText", the tagline | The card shown when the link is shared. Upload only in Settings → General; there's no API for it |
| Issues | On | |
| Discussions | Off for now | Section 13 |
| Wiki, Projects | Off | Unused; the docs live in the repo |
| Merge commits | Off | Keeps history linear (the ruleset requires it) |
| Squash merge | On; uses the PR title and description | The default for small PRs |
| Rebase merge | On | For PRs whose commits are worth keeping, like #1 |
| Always suggest updating PR branches | On | |
| Auto-merge | On | Merges once checks pass |
| Delete head branches after merging | On | No pile of stale branches |

```bash
R=curry-co/blacktext
gh repo edit $R \
  --description "A plain-text notepad for Mac, iPhone and iPad. Saves as you type, keeps every version, syncs through iCloud." \
  --homepage "https://curry-co.github.io/blacktext/" \
  --enable-wiki=false --enable-projects=false --enable-discussions=false \
  --enable-merge-commit=false --enable-squash-merge --enable-rebase-merge \
  --allow-update-branch --enable-auto-merge --delete-branch-on-merge \
  --add-topic notes,note-taking,notepad,plain-text,text-editor,minimalist,autosave,version-history \
  --add-topic macos,ios,ipados,swift,appkit,uikit,sqlite,full-text-search,icloud,cloudkit \
  --add-topic mcp-server,model-context-protocol
gh api -X PATCH repos/$R -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
```

That's 20 topics, GitHub's limit. The social image comes from a script in `scripts/` that reuses the icon renderer in `make-icon.swift`; it's committed to `docs/images/social.png`.

## 3. Branch and tag rules

Use rulesets rather than classic branch protection: they're the current mechanism, and their JSON can be reviewed. Keep the JSON in `.github/rulesets/` so the settings are recorded alongside the code. GitHub doesn't read that folder; it's only a record.

**`main`** (`.github/rulesets/main.json`):

```json
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash", "rebase"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "mac", "integration_id": 15368 },
          { "context": "ios", "integration_id": 15368 } ] } }
  ]
}
```

- **No required approvals.** With one maintainer, a required approval would block every merge. Outside contributors can't merge anyway; you merge their PRs. Raise it to 1 when there's a second maintainer.
- **Admins bypass only through a PR** (`bypass_mode: pull_request`). In an emergency you can merge your own PR before its checks finish, but nobody can push straight to `main`.
- **Required checks.** `15368` is the GitHub Actions app, so a check from anywhere else can't satisfy the rule. Both checks must run on every PR, which means no `paths` filter on the `pull_request` trigger; otherwise a docs-only PR waits forever for a check that never starts.

**Release tags** (`.github/rulesets/tags.json`): only admins can create, move or delete `v*` tags. Pushing a tag starts a signed release, so this matters.

```json
{
  "name": "release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ]
}
```

```bash
gh api -X POST repos/$R/rulesets --input .github/rulesets/main.json
gh api -X POST repos/$R/rulesets --input .github/rulesets/tags.json
```

**Signed commits** aren't required for now. Section 13 has the trade-off.

## 4. Actions and signing secrets

### Workflows

- **Token permissions.** Add `permissions: contents: read` at the top of every workflow, and give write access per job only where a job needs it (the release job). The repo default is already read-only; stating it in the file survives a settings change.
- **Pinned actions.**
  - Pin every action to a full commit SHA, with the version in a comment (`actions/checkout@<sha> # v4.2.2`). Dependabot keeps the pins current.
  - Then turn on *Require actions to be pinned to a full-length commit SHA*.
  - Allow only actions from GitHub and verified creators.
- **Checkout.** Use `actions/checkout` with `persist-credentials: false`, so later steps can't reuse the token.
- **Concurrency.** Add `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true }` on PR runs, so a new push cancels the run it replaces.
- **`pull_request_target`.** Never use it. It runs fork code with secrets.
- **Fork PRs.** Require approval before workflows run for *all* outside contributors. macOS runners are slow and in demand, and approval is a second look before anything runs.
- **Triggers.**
  - `ci.yml`: `push` to `main` plus `pull_request`. Today it runs on every push to every branch, so each PR runs twice.
  - `ios.yml`: the Simulator build and screenshots (job `ios`) run on `pull_request` and on pushes to `main`, with no secrets. Uploading to TestFlight becomes its own job in the `testflight` environment, run on `v*` tags and by manual dispatch from `main`.

```bash
gh api -X PUT repos/$R/actions/permissions --input - <<'EOF'
{ "enabled": true, "allowed_actions": "selected", "sha_pinning_required": true }
EOF
gh api -X PUT repos/$R/actions/permissions/selected-actions --input - <<'EOF'
{ "github_owned_allowed": true, "verified_allowed": true }
EOF
gh api -X PUT repos/$R/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
```

### Secrets go into environments, with the least power that works

Today `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` are repository secrets, so any workflow on any branch can read them. The key behind them has the **Admin** role, which can do anything in the App Store Connect account, including for the other apps that account holds. CI uses Admin only because Xcode's automatic signing creates certificates and profiles on the fly.

**Replace it with manual signing:**

- Create a fixed **Apple Distribution** certificate and an **App Store provisioning profile** for `co.curry.blacktext` that includes iCloud and push.
- Create an **App Manager** API key. It can upload builds and run TestFlight, but it can't manage users or keys.
- Move all of these into environments:

| Environment | Secrets | Can run from | Approval |
|---|---|---|---|
| `testflight` | App Manager key, Distribution certificate (.p12 and password), App Store profile | `main` and `v*` tags | You |
| `release` | Developer ID Application certificate (.p12 and password), Developer ID profile, notary key (the existing Developer-role key), a Homebrew tap token (section 9) | `v*` tags only | You |

Then:

- Delete the three repository-level `ASC_*` secrets.
- Take the Admin key out of every workflow. Keep it only in `~/.config/blacktext-release` for setup work, or revoke it.
- Change `scripts/ios-testflight.sh` to `CODE_SIGN_STYLE=Manual` with the named profile, imported into a temporary keychain for the job.

Who does what: I create the certificate and profile through the API and save them in `~/.config/blacktext-release`. You generate the App Manager key in App Store Connect and paste the secrets into the environments. I create the environments themselves, with their branch rules and you as the approver.

## 5. Security features

```bash
gh api -X PATCH repos/$R --input - <<'EOF'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" },
    "secret_scanning_non_provider_patterns": { "status": "enabled" },
    "secret_scanning_validity_checks": { "status": "enabled" } } }
EOF
gh api -X PUT repos/$R/automated-security-fixes
gh api -X PUT repos/$R/private-vulnerability-reporting
gh api -X PATCH repos/$R/code-scanning/default-setup --input - <<'EOF'
{ "state": "configured", "languages": ["actions", "swift"], "query_suite": "default" }
EOF
```

- **Secret scanning and push protection** are free for public repos. Push protection blocks a push that contains a known token type. The last two settings, generic patterns and validity checks, may need a paid plan; if the API refuses them, leave them off.
- **Private vulnerability reporting** adds a *Report a vulnerability* button under Security. `SECURITY.md` points people to it.
- **Dependabot.**
  - `.github/dependabot.yml` updates the `github-actions` ecosystem weekly, labelled `dependencies`.
  - The Swift package has no outside dependencies today. Add the `swift` ecosystem when one arrives (Sparkle, section 9).
- **CodeQL default setup** for Swift and Actions.
  - The Actions queries catch workflow mistakes such as injection through PR titles.
  - CodeQL's Swift support sometimes trails new Xcode releases. If Swift extraction fails on the current toolchain, keep Actions scanning and retry Swift later.
- **Release provenance.** The release job runs `actions/attest-build-provenance` on the DMG. Anyone can then check that a download was built from this repo at that tag: `gh attestation verify BlackText-0.1.0.dmg -R curry-co/blacktext`.
- **`.gitignore` for signing material.** Add `*.p8`, `*.p12`, `*.cer`, `*.mobileprovision`, `*.provisionprofile`, `AuthKey_*` and `.env`. The keys live outside the repo, so this is a second line of defence.
- **OpenSSF Scorecard** is optional: a weekly check of the practices above, with a badge. It's worth adding once the rest is in place, because it will score well.
- **Organization 2FA.** Turn on *Require two-factor authentication* in the curry-co organization's settings. You're the only member, so check that your own account has 2FA first; GitHub removes members who don't.

## 6. Community files

| File | Contents |
|---|---|
| `SECURITY.md` | Report privately with *Report a vulnerability*, never in a public issue. In scope: the apps, the `blacktext` command, the MCP server and sync. Supported: the latest release. Acknowledgement within a week; no bounty. |
| `CONTRIBUTING.md` | The principle first: "when in doubt, leave it out", so a new feature starts as an issue, not a PR. How to build and test (`make test`, and the iOS app through XcodeGen or CI). Use `BLACKTEXT_DB` and scratch databases, never your own notes. Builds you make yourself don't sync, and that's expected. Match the surrounding code, add tests for core changes, and write commit messages that say why. |
| `CODE_OF_CONDUCT.md` | Contributor Covenant 2.1, with a contact address (section 13). |
| `.github/CODEOWNERS` | `* @jasonacurry`, so you're asked to review every PR. |
| `.github/ISSUE_TEMPLATE/bug.yml` | A form asking for the device (Mac, iPhone or iPad), the OS version, the BlackText version (from About), steps, and what you expected versus what happened. Warns against pasting private note text. |
| `.github/ISSUE_TEMPLATE/idea.yml` | Starts with the problem ("What were you trying to do?"), not the feature, and links the principles. |
| `.github/ISSUE_TEMPLATE/config.yml` | Blank issues off. Links to vulnerability reporting, and to Discussions if they're turned on. |
| `.github/pull_request_template.md` | What and why, how it was tested, screenshots for any UI change, and a box confirming no real notes appear in screenshots or tests. |
| `.github/release.yml` | Release-note categories by label: Features, Fixes, Sync, Agents, Other. |
| `.github/dependabot.yml` | Section 5. |

**Labels:** replace GitHub's defaults with `bug`, `idea`, `mac`, `ios`, `sync`, `agents` (the CLI and MCP), `docs`, `good first issue`, `help wanted`, `not planned`, `security` and `dependencies`. Use `gh label create` and `gh label delete`.

## 7. Name, description, topics and copy

**Name:** BlackText; the repo stays `blacktext`. The App Store record already holds the name.

**Description**, at most 350 characters. My pick:

> A plain-text notepad for Mac, iPhone and iPad. Saves as you type, keeps every version, syncs through iCloud.

Alternatives:
- Keep your line and add the platforms: "One page. Plain text. Autosave. Versioning. For Mac, iPhone and iPad."
- Lead with agents: "A plain-text notepad for Mac, iPhone and iPad that your AI agents can read and write. Autosave, versions, iCloud sync."

**Topics:** notes, note-taking, notepad, plain-text, text-editor, minimalist, autosave, version-history, macos, ios, ipados, swift, appkit, uikit, sqlite, full-text-search, icloud, cloudkit, mcp-server, model-context-protocol.

**Lines to reuse everywhere:**

| Where | Copy |
|---|---|
| Headline (site, social image) | Plain text. Nothing added. |
| One-sentence pitch (README, cask, site) | BlackText is a plain-text notepad for Mac, iPhone and iPad that saves everything and adds nothing. |
| Homebrew `desc` (short, no article) | Plain-text notepad that saves everything and adds nothing |
| App Store subtitle (30 max) | Plain text. Nothing added. |
| App Store promotional text (170 max) | One page for typing. It saves as you type, keeps every version, and syncs your notes between iPhone, iPad and Mac through iCloud. |
| App Store keywords (100 max) | notepad,plain text,notes,editor,minimal,autosave,versions,history,writing,drafts,scratchpad,jot |
| Launch post title | BlackText: a plain-text notepad that opens as fast in year ten as on day one |

The README's "Nothing added" section is the voice for everything else. Keep it first-person and short.

## 8. README

Keep what works: the principles, the keyboard table, Agents, the command line and Speed. Change the rest so a visitor can download in one click, and so the README no longer contradicts sync.

**New order:**

1. **Title, one-sentence pitch, screenshot.** One wide image: the Mac window in light and dark next to an iPhone. Made from sample notes by script (`scripts/ios-screenshots.sh` exists; add `scripts/mac-screenshots.sh` using `BLACKTEXT_DB` and `screencapture -l`). Never from real notes. Save to `docs/images/`.
2. **Badges:** CI, latest release, license. One small row (section 13).
3. **Download.**
   - **Mac:** [Download BlackText.dmg](https://github.com/curry-co/blacktext/releases/latest), or `brew install --cask curry-co/tap/blacktext`. macOS 14 or later.
   - **iPhone and iPad:** a public TestFlight link until the App Store listing exists. iOS 17 or later.
   - **From source:** the current Install section, moved under Development.
4. **The bullet list.** Add two bullets:
   - "**On every device.** Mac, iPhone and iPad, synced through iCloud in seconds."
   - "**Save+New** on iPhone and iPad does what ⌘↩ does."
5. **Nothing added.** Unchanged except "Your notes are yours":
   > **Your notes are yours.** They live in one file on your device. Sync goes through your own iCloud account and is end-to-end encrypted. There's no BlackText account and no BlackText server. It's open source, so you never have to take my word for it.
   >
   > (Once section 1's fix lands. Until then: "end-to-end encrypted for notes up to about 900 KB".)
6. **Using it.** The current Mac text, plus an "On iPhone and iPad" part:
   > Same page, same notes. **Save+New**, at the bottom right above the keyboard, files the note away and gives you a clean page, with Undo for a few seconds. The sidebar, history, find & replace and search across notes work as on the Mac, and with a hardware keyboard so do the Mac's shortcuts.

   Check every claim against the app before publishing.
7. **Sync** (new):
   > BlackText keeps your notes, their history and deletions the same on your Mac, iPhone and iPad through iCloud, usually within seconds. Sign in to the same Apple Account on each device; there's nothing to set up. Note text is end-to-end encrypted, so Apple stores it but can't read it. If two devices change the same note at once, the newer edit wins and the other is kept in the note's history, labelled with the device it came from. Without iCloud, BlackText works the same on one device. Builds you make yourself don't sync, because iCloud needs Apple's signing.
8. **Agents, the `blacktext` command, Your data.** Your data adds that sync is optional and that export still writes plain `.txt` files.
9. **Privacy** (new):
   > BlackText collects nothing: no analytics, no crash reporting, no tracking. Its only network connection is to iCloud, for sync.

   This is true today; I checked that the code has no other network calls. Keep it true.
10. **Speed.** Unchanged.
11. **Development.**
    - Install from source.
    - `make` targets, and the code layout with `iOS/` added.
    - XcodeGen, and CI's iOS build and screenshots.
    - Testing sync with scratch databases.
    - A link to `docs/releasing.md` for maintainers (`make release`, tags).
12. **Contributing, Security, License:** one line each, linking the files.

## 9. Releases

**Versioning.**
- Semantic versioning, with one version shared by the Mac and iOS apps.
- `Sources/BlackTextCore/Version.swift` is the single source; both build scripts already read it.
- A release is a `vX.Y.Z` tag on `main`. The workflow refuses a tag that doesn't match `Version.swift`.
- Stay on 0.x until the App Store release. The first tag is `v0.1.0`.

**`.github/workflows/release.yml`** runs on a `v*` tag:

1. **`mac`** (`release` environment, so it waits for your approval).
   - Imports the Developer ID certificate into a temporary keychain.
   - Runs `scripts/release.sh`, changed to name the files `BlackText-<version>.dmg` and `.sha256`.
   - The notary key comes from a secret, written to a temp file.
2. **Attest.** `actions/attest-build-provenance` on the DMG.
3. **Draft release.**
   - A **draft** GitHub Release with the DMG and checksum.
   - Notes generated from labels (`.github/release.yml`), under a short hand-written summary.
   - Publishing the draft is the human gate.
4. **`ios`** (`testflight` environment): archives at the tag's version and uploads to TestFlight.
5. **`homebrew`.** When the release is published, a job bumps the cask in `curry-co/homebrew-tap`. It uses a fine-grained token that can write only to that repo.

**The Homebrew tap.** `curry-co/homebrew-tap` is a new public repo, so it's your call. Then `brew install --cask curry-co/tap/blacktext` works:

```ruby
cask "blacktext" do
  version "0.1.0"
  sha256 "…"
  url "https://github.com/curry-co/blacktext/releases/download/v#{version}/BlackText-#{version}.dmg"
  name "BlackText"
  desc "Plain-text notepad that saves everything and adds nothing"
  homepage "https://curry-co.github.io/blacktext/"
  depends_on macos: ">= :sonoma"
  app "BlackText.app"
  binary "#{appdir}/BlackText.app/Contents/Helpers/blacktext"
end
```

- **No `zap` stanza for the database.** Uninstalling must never delete notes.
- **The official Homebrew cask list** wants evidence that a project is notable. Submit there once the project has some users.

**Mac updates.**
- A DMG doesn't update itself. Until something does, Homebrew users get updates with `brew upgrade`, and everyone else re-downloads.
- [Sparkle 2](https://sparkle-project.org) adds in-app updates. It uses an EdDSA-signed appcast that the release job publishes to the Pages site, and it would be the package's first outside dependency.

**iPhone and iPad.**
- *Public TestFlight link.* It needs an external testing group and one Beta App Review.
- *The App Store needs:*
  - privacy policy and support URLs (section 10);
  - 6.9-inch iPhone and 13-inch iPad screenshots (the screenshot script, at those sizes);
  - App Privacy set to "Data Not Collected" (notes in the person's own iCloud aren't collected by the developer);
  - Productivity as the category, and an age rating.
- *The listing names the seller.* See section 13.

## 10. Website

GitHub Pages, deployed by `.github/workflows/pages.yml` from a `site/` folder:

- `/`: the headline, the screenshot, Download buttons, the principles, a link to GitHub.
- `/privacy`: the Privacy paragraph above, at more length. The App Store requires it.
- `/support`: issues for bugs, the security policy for vulnerabilities, and a contact address. The App Store requires it.
- Later, `/appcast.xml` for Sparkle.

Plain HTML and CSS in black and white, matching the app. No trackers and no fonts from elsewhere. A custom domain is optional (section 13).

## 11. Tidy the repo

- Move the plans into `docs/`: `PLAN.md` to `docs/design.md`, `PLAN-iOS.md` to `docs/ios.md`, and this file to `docs/open-source.md` once it's done. Move `design/icon-mockups/` to `docs/design/icon-mockups/`. Fix links.
- Add `docs/releasing.md`: the maintainer's checklist for a release, and where signing material lives (the folder name, never the contents).
- That leaves the root as README, LICENSE, Makefile, Package.swift, Sources, Tests, iOS, Resources, scripts, docs and site.

## 12. Order of work

| # | Step | Who |
|---|---|---|
| 1 | On `ios`: encrypt large attachments, rename the jobs to `mac` and `ios`, harden the workflows (section 4), `.gitignore` | Me, pushed to PR #1 |
| 2 | Try sync between your iPhone and Mac with a new TestFlight build | You |
| 3 | Merge PR #1 (rebase) | You |
| 4 | Repo settings, topics, labels, security features, rulesets, Actions restrictions (sections 2, 3, 5): one scripted batch | Me, once you approve the batch |
| 5 | Social preview image | Me to make it; you to upload it, or me in the browser pane |
| 6 | Community files, README rewrite, screenshots, moving docs | Me, as one PR |
| 7 | Distribution certificate and App Store profile; App Manager key | Me through the API; you generate the key |
| 8 | Environments with rules and approvers; you add the secrets; delete the old repo secrets | Me for the environments, you for the secrets |
| 9 | Release workflow, Pages site, `curry-co/homebrew-tap` | Me, as PRs; the tap repo needs your OK |
| 10 | Tag `v0.1.0`, approve the jobs, publish the draft release | You |
| 11 | Organization 2FA | You |
| 12 | Public TestFlight link, then the App Store listing | Together, after section 13's account decision |

Steps 4 and 6 can run alongside 7–9. Rulesets wait for step 3, because they require the renamed checks.

## 13. Decisions for you

1. **Whose name is on it.** The Developer ID signature, which anyone can inspect in the DMG, and the App Store's seller line both show the legal name of the individual who holds the developer account. You can publish under it, or move to a Curry Co organization account first. That needs a D-U-N-S number and Apple's review.
   - Moving later changes the Mac signing identity. The iCloud container belongs to the developer team, so moving is cheapest before there are users.
   - *My pick:* TestFlight and GitHub releases under the current account now; decide before the App Store listing.
2. **Where Mac releases are built.**
   - In CI behind the `release` environment: it gets provenance attestations and doesn't depend on one Mac.
   - On your Mac with `make release`: the Developer ID certificate never leaves your Mac.
   - *My pick:* CI.
3. **Discussions.** *My pick:* off until there are questions that don't fit in issues.
4. **Contact address** for the code of conduct and the support page. It will be public, so a dedicated alias is better than a personal address.
5. **Signed commits.** Requiring them means setting up SSH signing on every machine you commit from, including commits I make. *My pick:* not yet; revisit with a second maintainer.
6. **Mac auto-updates.** *My pick:* add Sparkle before announcing widely; Homebrew alone is enough for `v0.1.0`.
7. **Badges.** *My pick:* three small ones (CI, release, license). Leave them out if you'd rather keep the top of the README as spare as the app.
8. **Custom domain** for the site, if you have one in mind. Otherwise `curry-co.github.io/blacktext`.
9. **Description wording.** *My pick* is the first option in section 7.

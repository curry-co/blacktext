# Releasing

One version number covers the Mac app and the iPhone and iPad app: `Sources/BlackTextCore/Version.swift`. A release is a `vX.Y.Z` tag on `main` that matches it.

## Before you start

- Signing material lives in `~/.config/blacktext-release/` on the release Mac. Never commit anything from it or paste it anywhere.
- The Mac app's update key is in the login keychain (account `blacktext`), with a copy in that folder. **Keep a backup of it somewhere safe, such as a password manager.** Every Mac copy of BlackText checks updates against its public half (`SUPublicEDKey` in `Resources/Info.plist`). If the key is lost, those copies can't update themselves again.
- Release from `main`, with nothing uncommitted. The Mac build number is the number of commits on `main`, and the update feed relies on it going up.

## 1. Set the version

In a pull request, change `Version.swift` and `MARKETING_VERSION` in `iOS/project.yml`. Merge it.

## 2. The Mac app

```bash
git switch main && git pull
make release                      # build/BlackText.dmg: universal, Developer ID, iCloud Production, notarized
scripts/appcast.sh notes.html     # site/appcast.xml; notes.html is optional
```

- `make release` signs, notarizes and staples the app and the disk image, which takes a few minutes. It refuses to build without the Developer ID identity or the iCloud provisioning profile.
- Try the DMG before publishing: open it, copy the app somewhere new, launch it, and check **About BlackText**.

Publish the DMG as a GitHub release. The asset must be named `BlackText.dmg`, because the website's Download button and the update feed link to that name.

```bash
gh release create vX.Y.Z build/BlackText.dmg build/BlackText.dmg.sha256 --draft --title "BlackText X.Y.Z" --generate-notes
```

Read the draft on GitHub, then publish it. Publishing creates the tag.

Then open a pull request with `site/appcast.xml` and merge it. The site redeploys, and copies of BlackText on Macs offer the update within a day. Merge it only after the release is published, or Macs would be offered a download that isn't there yet.

## 3. iPhone and iPad

The tag runs the `testflight` job in `.github/workflows/ios.yml`. It archives the app at the tag's version and uploads it to TestFlight. You can also start it by hand from the Actions tab.

In App Store Connect:

1. Wait for the build to finish processing, then try it from TestFlight.
2. Open the app's next version (create it if needed, with the same number), choose the build, and fill in **What's New**.
3. Submit it for review. Once it's approved, release it.

## The listing

The App Store text, keywords and screenshots are kept in `docs/app-store.md` and `site/images/`. Update them there first, then in App Store Connect, so the repo stays the record of what's published.

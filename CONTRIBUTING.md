# Contributing

Thanks for wanting to help. BlackText stays small on purpose, so please open an issue to talk about a feature before building it: "when in doubt, leave it out" is the rule, and many good ideas don't fit.

Bug reports are always welcome. Say what you did, what you expected, what happened, and the BlackText and system versions.

For a pull request:

- `make test` passes, and new behavior comes with a test in `Tests/BlackTextCoreTests`.
- The Mac app builds with `make app`. CI builds the iPhone and iPad app and takes Simulator screenshots, so you don't need Xcode for that.
- Never test with your real notes: `BLACKTEXT_DB=/tmp/scratch.sqlite` points the app and the `blacktext` command at a scratch database, which never syncs.
- Keep it plain: no new dependencies, no analytics, no network connections.

By contributing, you agree that your work is released under the MIT License.

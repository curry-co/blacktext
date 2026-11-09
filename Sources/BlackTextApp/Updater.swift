import AppKit
import Sparkle

/// In-app updates, through Sparkle, for the Mac app downloaded from the website. Only releases have a feed:
/// scripts/release.sh adds `SUFeedURL` to the Info.plist, so builds you make yourself never update themselves
/// and have no Check for Updates item. Updates are checked about once a day, and each one must be signed
/// with the project's EdDSA key (`SUPublicEDKey`) and with the same Developer ID as the running app.
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        controller = bundle.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil
            : SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// True for releases, which have a feed.
    var isAvailable: Bool { controller != nil }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Starts the daily checks. Called once the window is up, so it never slows down launch.
    func start() {
        controller?.startUpdater()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

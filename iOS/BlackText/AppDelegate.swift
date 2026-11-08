import UIKit
import BlackTextCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Preferences.register()
        // Sync belongs to the app, not a window, so a push can wake the app and fetch with no window open.
        Sync.start()
        if Sync.cloud != nil { application.registerForRemoteNotifications() }
        return true
    }

    /// CloudKit's silent push: another device changed something. iOS wants to hear what the fetch found,
    /// within about 30 seconds.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Sync.start()
        guard let sync = Sync.cloud else {
            completionHandler(.noData)
            return
        }
        let once = Once()
        Task {
            let outcome = await sync.fetchChanges()
            guard once.claim() else { return }
            switch outcome {
            case .newData: completionHandler(.newData)
            case .noData: completionHandler(.noData)
            case .failed: completionHandler(.failed)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            if once.claim() { completionHandler(.failed) }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        for scene in application.connectedScenes {
            (scene.delegate as? SceneDelegate)?.flush()
        }
    }
}

/// Where the notes live: the App Group container, so a share extension can reach the same
/// database later; or Application Support when the group isn't available (a build without
/// the entitlement), the same place the Mac keeps it.
enum DatabaseLocation {
    static let appGroup = "group.co.curry.blacktext"

    static var url: URL {
        // BLACKTEXT_DB (used for Simulator screenshots) wins, as on the Mac.
        if Paths.isDatabaseOverridden { return Paths.databaseURL }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent("blacktext.sqlite")
        }
        return Paths.databaseURL
    }
}

/// True for the first caller only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// The iCloud sync engine, owned by the app. A scene attaches to it while it's on screen (see
/// `SceneDelegate`), so changes from other devices reach the canvas; without one they still land.
@MainActor enum Sync {
    static var cloud: CloudSync?

    /// Starts sync if this build may and it hasn't started yet. Fails quietly if the notes can't be opened
    /// yet (a locked device after a restart); the next launch or push tries again.
    static func start() {
        guard cloud == nil, CloudSync.isAvailable, let store = try? Store(url: DatabaseLocation.url) else { return }
        let sync = CloudSync(store: store, deviceName: UIDevice.current.model)
        cloud = sync
        sync.start()
    }
}

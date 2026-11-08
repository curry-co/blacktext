import UIKit
import BlackTextCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Preferences.register()
        if CloudSync.isAvailable { application.registerForRemoteNotifications() }
        return true
    }

    /// CloudKit's silent push: another device changed something.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Sync.cloud?.fetchNow()
        completionHandler(.newData)
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

/// The iCloud sync engine, shared by the scene (which starts it) and the app delegate (which gets its pushes).
@MainActor enum Sync {
    static var cloud: CloudSync?
}

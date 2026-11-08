import UIKit
import BlackTextCore
import notify

/// The one window. Opens the database, shows the canvas, saves on the way out, and handles
/// blacktext:// links and "the database changed" notifications, like the Mac's AppDelegate.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var main: MainViewController?
    private var store: Store?
    private var notifyToken: Int32 = 0
    private var isListening = false
    /// The first foreground is launch itself, which has just read everything it needs.
    private var hasBeenInForeground = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        Theme.apply(to: window)

        // Separate connections for the main thread, saves and search, so a long search never
        // blocks a save (SQLite's write-ahead log lets them share the file).
        let url = DatabaseLocation.url
        let stores: (Store, Store, Store)
        do {
            stores = (try Store(url: url), try Store(url: url), try Store(url: url))
        } catch {
            window.rootViewController = StartupErrorViewController(
                title: "BlackText couldn't open its notes", detail: "\(error)\n\n\(url.path)")
            window.makeKeyAndVisible()
            return
        }
        store = stores.0
        let main = MainViewController(store: stores.0, saveStore: stores.1, searchStore: stores.2)
        self.main = main
        main.start()
        window.rootViewController = main
        window.makeKeyAndVisible()
        open(connectionOptions.urlContexts)

        // Everything below waits until the window is up.
        DispatchQueue.main.async { [weak self] in self?.finishLaunching() }
    }

    private func finishLaunching() {
        // The CLI, agents or (later) a share extension changed the database.
        notify_register_dispatch(AppLink(database: DatabaseLocation.url).changedNotification, &notifyToken, .main) { [weak self] _ in
            self?.main?.databaseDidChange()
        }
        isListening = true
        guard let store else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = try? store.purgeDeleted(before: Date().addingTimeInterval(-30 * 86_400))
        }
        startCloudSync()
        showScreenshotState()
    }

    /// Only builds signed with the iCloud entitlement sync (not Simulator builds from CI).
    private func startCloudSync() {
        guard CloudSync.isAvailable, Sync.cloud == nil, let main,
              let syncStore = try? Store(url: DatabaseLocation.url) else { return }
        let sync = CloudSync(store: syncStore, deviceName: UIDevice.current.model)
        sync.willApplyRemoteChanges = { [weak main] in main?.editor.flushPendingSave() }
        sync.didApplyRemoteChanges = { [weak main] _ in main?.databaseDidChange() }
        main.onLocalChange = { [weak sync] in sync?.localChangesMayExist() }
        Sync.cloud = sync
        sync.start()
    }

    /// `-BTScreenshot canvas|sidebar|find` opens the newest note and puts the app in a state for CI's
    /// Simulator screenshots.
    private func showScreenshotState() {
        guard let main, let store, let state = UserDefaults.standard.string(forKey: "BTScreenshot") else { return }
        if let newest = try? store.notes(limit: 1).first { main.editor.open(noteID: newest.id, caretAtEnd: true) }
        switch state {
        case "sidebar": main.toggleNoteSidebar()
        case "find": main.find.showForScreenshot(query: "the")
        default: break
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        flush()
        if isListening {
            notify_cancel(notifyToken)
            isListening = false
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard hasBeenInForeground else {
            hasBeenInForeground = true
            return
        }
        // Date headers may have rolled over, and another process may have written while we were away.
        main?.databaseDidChange()
        Sync.cloud?.fetchNow()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        main?.editor.saveSoon()
    }

    /// The app may never come back from the background, so the save happens now and is waited for.
    func sceneDidEnterBackground(_ scene: UIScene) {
        // Ask for time to finish, in case the write is slow.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save the open note")
        main?.editor.saveForBackground()
        Sync.cloud?.localChangesMayExist()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    /// Saves now with a version if anything changed. Used when the scene or app is going away.
    func flush() {
        main?.editor.flush()
    }

    // MARK: URLs: blacktext://new?text=…  blacktext://append?text=…

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts)
    }

    private func open(_ contexts: Set<UIOpenURLContext>) {
        guard let main else { return }
        for context in contexts where context.url.scheme == "blacktext" {
            let text = URLComponents(url: context.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value ?? ""
            switch context.url.host() {
            case "new" where !text.isEmpty:
                main.openNewNote(text: text)
            case "append" where !text.isEmpty:
                main.appendToCurrentNote(text)
            default:
                break
            }
        }
    }
}

/// Shown instead of the canvas when the database can't be opened.
final class StartupErrorViewController: UIViewController {
    private let titleText: String
    private let detail: String

    init(title: String, detail: String) {
        titleText = title
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        let heading = UILabel()
        heading.text = titleText
        heading.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = Palette.text
        heading.numberOfLines = 0
        let body = UILabel()
        body.text = detail
        body.font = UIFont.systemFont(ofSize: 13)
        body.textColor = Palette.secondaryText
        body.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [heading, body])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

import Foundation
import Observation
import ServiceManagement

/// Preferences, saved in the app's user defaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Switch layouts automatically when a watched game starts and quits.
    var automaticSwitching: Bool {
        didSet { defaults.set(automaticSwitching, forKey: Keys.automaticSwitching) }
    }

    /// Back to the normal layout while you're in another app (⌘Tab), game layout again when you return.
    var freeCursorOutsideGame: Bool {
        didSet { defaults.set(freeCursorOutsideGame, forKey: Keys.freeCursorOutsideGame) }
    }

    /// Turn off "Shake mouse pointer to locate" while the game layout is on.
    var disableShakeToLocate: Bool {
        didSet { defaults.set(disableShakeToLocate, forKey: Keys.disableShakeToLocate) }
    }

    /// GameEdge turned Shake to Locate off and must turn it back on (saved, to survive a crash).
    var shakeToLocateNeedsRestore: Bool {
        didSet { defaults.set(shakeToLocateNeedsRestore, forKey: Keys.shakeToLocateNeedsRestore) }
    }

    /// Hide the menu bar and Dock while a game runs, and cover a windowed game's title bar.
    var fillScreenInWindowedMode: Bool {
        didSet { defaults.set(fillScreenInWindowedMode, forKey: Keys.fillScreenInWindowedMode) }
    }

    /// ⌥Tab switches between the game and the last app, like Alt+Tab on Windows.
    var altTabSwitches: Bool {
        didSet { defaults.set(altTabSwitches, forKey: Keys.altTabSwitches) }
    }

    /// GameEdge hid the menu bar / the Dock and must show them again (saved, to survive a crash).
    var menuBarNeedsRestore: Bool {
        didSet { defaults.set(menuBarNeedsRestore, forKey: Keys.menuBarNeedsRestore) }
    }

    var dockNeedsRestore: Bool {
        didSet { defaults.set(dockNeedsRestore, forKey: Keys.dockNeedsRestore) }
    }

    var watchedApps: [WatchedApp] {
        didSet { save(watchedApps, forKey: Keys.watchedApps) }
    }

    /// A game layout saved by the user; nil means automatic.
    var customLayout: Arrangement? {
        didSet { save(customLayout, forKey: Keys.customLayout) }
    }

    /// The arrangement to restore. Non-nil while the game layout is on, and
    /// saved to disk so a crash or a forced quit can still restore it.
    var savedNormalLayout: Arrangement? {
        didSet { save(savedNormalLayout, forKey: Keys.savedNormal) }
    }

    var hasLaunchedBefore: Bool {
        didSet { defaults.set(hasLaunchedBefore, forKey: Keys.didFirstRun) }
    }

    private enum Keys {
        static let automaticSwitching = "automaticSwitching"
        static let watchedApps = "watchedApps"
        static let customLayout = "customGaming"
        static let savedNormal = "savedNormal"
        static let didFirstRun = "didFirstRun"
        static let freeCursorOutsideGame = "freeCursorOutsideGame"
        static let disableShakeToLocate = "disableShakeToLocate"
        static let shakeToLocateNeedsRestore = "shakeToLocateNeedsRestore"
        static let fillScreenInWindowedMode = "fillScreenInWindowedMode"
        static let altTabSwitches = "altTabSwitches"
        static let menuBarNeedsRestore = "menuBarNeedsRestore"
        static let dockNeedsRestore = "dockNeedsRestore"
    }

    private init() {
        defaults.register(defaults: [Keys.automaticSwitching: true, Keys.freeCursorOutsideGame: true,
                                     Keys.disableShakeToLocate: true, Keys.fillScreenInWindowedMode: true,
                                     Keys.altTabSwitches: true])
        automaticSwitching = defaults.bool(forKey: Keys.automaticSwitching)
        freeCursorOutsideGame = defaults.bool(forKey: Keys.freeCursorOutsideGame)
        disableShakeToLocate = defaults.bool(forKey: Keys.disableShakeToLocate)
        shakeToLocateNeedsRestore = defaults.bool(forKey: Keys.shakeToLocateNeedsRestore)
        fillScreenInWindowedMode = defaults.bool(forKey: Keys.fillScreenInWindowedMode)
        altTabSwitches = defaults.bool(forKey: Keys.altTabSwitches)
        menuBarNeedsRestore = defaults.bool(forKey: Keys.menuBarNeedsRestore)
        dockNeedsRestore = defaults.bool(forKey: Keys.dockNeedsRestore)
        // 1.2.0 test builds changed League of Legends' game.cfg resolution: no longer.
        defaults.removeObject(forKey: "leagueWindowedContentSize")
        defaults.removeObject(forKey: "leagueOriginalResolution")
        hasLaunchedBefore = defaults.bool(forKey: Keys.didFirstRun)
        customLayout = Self.load(Arrangement.self, defaults: defaults, key: Keys.customLayout)
        savedNormalLayout = Self.load(Arrangement.self, defaults: defaults, key: Keys.savedNormal)
        var apps = Self.load([WatchedApp].self, defaults: defaults, key: Keys.watchedApps) ?? []
        // Built-in games always come from the code (only the switch is saved), and
        // new ones appear after an update.
        apps = apps.map { saved in
            guard var builtIn = WatchedApp.defaults.first(where: { $0.id == saved.id }) else { return saved }
            builtIn.isEnabled = saved.isEnabled
            return builtIn
        }
        for builtIn in WatchedApp.defaults.reversed() where !apps.contains(where: { $0.id == builtIn.id }) {
            apps.insert(builtIn, at: 0)
        }
        watchedApps = apps
    }

    private func save<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Open at login, through the system's Login Items.
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

enum Log {
    static let url: URL = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "GameEdge"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name).log")
    }()

    /// Appends a line to ~/Library/Logs/GameEdge.log (kept under 1 MB).
    static func write(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
        let fileManager = FileManager.default
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? fileManager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

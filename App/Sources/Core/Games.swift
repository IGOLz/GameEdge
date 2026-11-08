import AppKit
import Darwin

/// An app that turns on the game layout while it's running.
nonisolated struct WatchedApp: Codable, Identifiable, Equatable, Sendable {
    /// Bundle identifier.
    var id: String
    var name: String
    /// File name of the app bundle, e.g. "LeagueofLegends.app": also matches
    /// processes started without Launch Services.
    var bundleFileName: String
    var isEnabled = true
    var isBuiltIn = false

    /// League of Legends: the in-match process only, so the layout changes
    /// when a match starts and not while you're in the client.
    static let leagueOfLegends = WatchedApp(
        id: "com.riotgames.LeagueofLegends.GameClient",
        name: "League of Legends",
        bundleFileName: "LeagueofLegends.app",
        isBuiltIn: true)

    static let defaults = [leagueOfLegends]

    var executableMarker: String { "/\(bundleFileName)/Contents/MacOS/" }

    var subtitle: String {
        isBuiltIn && id == Self.leagueOfLegends.id ? "Only during a match, not in the client" : id
    }

    init(id: String, name: String, bundleFileName: String, isEnabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.bundleFileName = bundleFileName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    /// An app chosen by the user.
    init?(appURL: URL) {
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        self.init(id: id, name: name, bundleFileName: appURL.lastPathComponent)
    }
}

enum GameDetector {
    /// The first enabled app that is running now.
    static func runningGame(among apps: [WatchedApp]) -> WatchedApp? {
        let enabled = apps.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let app = enabled.first(where: { bundleIDs.contains($0.id) }) { return app }
        // Games launched by their own launcher can be missing from Launch
        // Services: match the executable path instead (~1 ms).
        let paths = processPaths()
        return enabled.first { app in paths.contains { $0.contains(app.executableMarker) } }
    }

    private static func processPaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        return pids.prefix(Int(max(found, 0))).compactMap { pid in
            guard pid > 0 else { return nil }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        }
    }

    /// Icon of an installed app, if Launch Services knows it.
    static func icon(for app: WatchedApp) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if app.id == WatchedApp.leagueOfLegends.id,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.riotgames.leagueoflegends") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

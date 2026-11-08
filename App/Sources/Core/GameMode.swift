import AppKit
import Observation

/// Watches for games and switches between the normal and the game layout.
@Observable
final class GameMode {
    static let shared = GameMode()

    struct Display: Identifiable, Equatable {
        let id: String
        let name: String
        let frame: CGRect
        let isMain: Bool
    }

    struct Event: Identifiable {
        let id = UUID()
        let date = Date.now
        let symbol: String
        let text: String
    }

    enum Status: Equatable {
        case gameLayout(game: String?)
        case waiting
        case paused
    }

    private(set) var displays: [Display] = []
    private(set) var runningGame: WatchedApp?
    /// The game layout was turned on by hand, so it stays on until turned off by hand.
    private(set) var isManual = false
    private(set) var events: [Event] = []
    private(set) var lastError: String?

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    var isActive: Bool { settings.savedNormalLayout != nil }

    var status: Status {
        if isActive { return .gameLayout(game: isManual ? nil : runningGame?.name) }
        return settings.automaticSwitching ? .waiting : .paused
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        reloadDisplays()
        #if DEBUG
        if DebugUI.usesSampleDisplays { return }
        #endif
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { GameMode.shared.refresh() }
            }
        }
        // Some games start from their launcher without Launch Services: poll too.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { GameMode.shared.refresh() }
        }
        CGDisplayRegisterReconfigurationCallback(displaysReconfigured, nil)
        Log.write("started \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")")
        if isActive { Log.write("a game layout from the previous session is still on") }
        refresh()
    }

    /// Restores the normal layout before quitting.
    func stop() {
        if isActive { restoreNormalLayout(reason: "GameEdge quit") }
    }

    func refresh() {
        let game = GameDetector.runningGame(among: settings.watchedApps)
        let previous = runningGame
        if game?.id != runningGame?.id {
            if let game { Log.write("\(game.name) started") } else if let runningGame { Log.write("\(runningGame.name) quit") }
            runningGame = game
        }
        if let game, !isActive, settings.automaticSwitching {
            applyGameLayout(manual: false, reason: "\(game.name) started")
        } else if game == nil, isActive, !isManual {
            restoreNormalLayout(reason: previous.map { "\($0.name) quit" } ?? "No game running")
        }
    }

    func displaysChanged() {
        reloadDisplays()
    }

    // MARK: Actions

    /// Turns on the game layout by hand (to try it, or for a game GameEdge doesn't watch).
    func useGameLayoutNow() {
        applyGameLayout(manual: true, reason: "Turned on from GameEdge")
    }

    func restoreNow() {
        restoreNormalLayout(reason: "Turned off from GameEdge")
    }

    /// Saves the current arrangement (made in System Settings › Displays) as the game layout.
    func saveCurrentAsGameLayout() {
        guard !isActive, let current = currentArrangement() else { return }
        settings.customLayout = current
        Log.write("custom game layout saved: \(current.origins)")
        record("square.and.arrow.down.fill", "Saved the current arrangement as the game layout")
    }

    func useAutomaticLayout() {
        settings.customLayout = nil
        record("wand.and.stars", "Using the automatic game layout")
    }

    // MARK: Layouts

    /// The arrangement to restore when the game layout is on, otherwise the current one.
    var normalFrames: [String: CGRect] {
        frames(of: settings.savedNormalLayout ?? currentArrangement())
    }

    var gameFrames: [String: CGRect] {
        guard let normal = settings.savedNormalLayout ?? currentArrangement() else { return [:] }
        return frames(of: gameLayout(for: normal))
    }

    var mainDisplayID: String? { displays.first(where: \.isMain)?.id }

    /// The saved custom layout, when it fits the displays connected now.
    var usableCustomLayout: Arrangement? {
        guard let custom = settings.customLayout, custom.mainUUID == mainDisplayID,
              displays.allSatisfy({ custom.origins[$0.id] != nil }) else { return nil }
        return custom
    }

    func gameLayout(for normal: Arrangement) -> Arrangement {
        if let custom = usableCustomLayout { return custom }
        let frames = Geometry.gameFrames(from: frames(of: normal), game: normal.mainUUID)
        return Arrangement(mainUUID: normal.mainUUID, frames: frames)
    }

    private func frames(of arrangement: Arrangement?) -> [String: CGRect] {
        guard let arrangement else { return [:] }
        return arrangement.frames(sizes: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame.size) }))
    }

    private func currentArrangement() -> Arrangement? {
        guard let main = mainDisplayID else { return nil }
        return Arrangement(mainUUID: main, frames: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame) }))
    }

    // MARK: Switching

    private func applyGameLayout(manual: Bool, reason: String) {
        guard !isActive else { return }
        reloadDisplays()
        guard let normal = currentArrangement() else { return }
        let target = gameLayout(for: normal)
        settings.savedNormalLayout = normal
        isManual = manual
        let result = apply(target)
        Log.write("game layout on (\(reason)): \(result) \(target.origins)")
        switch result {
        case .applied, .unchanged:
            lastError = nil
            record("gamecontroller.fill", "\(reason): game layout on")
        case .mainDisplayChanged, .failed:
            settings.savedNormalLayout = nil
            isManual = false
            lastError = "macOS didn't accept the game layout (\(result))."
            record("exclamationmark.triangle.fill", "Couldn't apply the game layout")
        }
    }

    private func restoreNormalLayout(reason: String) {
        guard let normal = settings.savedNormalLayout else { return }
        let result = apply(normal)
        Log.write("normal layout restored (\(reason)): \(result) \(normal.origins)")
        settings.savedNormalLayout = nil
        isManual = false
        if case .failed = result {
            lastError = "macOS didn't accept the normal layout. Rearrange the displays in System Settings › Displays."
        } else {
            lastError = nil
        }
        record("arrow.uturn.backward.circle.fill", "\(reason): normal layout restored")
    }

    private func apply(_ arrangement: Arrangement) -> Displays.ApplyResult {
        #if DEBUG
        if DebugUI.usesSampleDisplays { return .unchanged }
        #endif
        let result = Displays.apply(arrangement)
        reloadDisplays()
        return result
    }

    private func record(_ symbol: String, _ text: String) {
        events.insert(Event(symbol: symbol, text: text), at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
    }

    private func reloadDisplays() {
        #if DEBUG
        if DebugUI.usesSampleDisplays {
            displays = DebugUI.sampleDisplays
            if events.isEmpty { events = DebugUI.sampleEvents }
            return
        }
        #endif
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        let updated = Displays.online().map {
            Display(id: $0.id, name: names[$0.displayID] ?? "Display", frame: $0.frame, isMain: $0.isMain)
        }
        if updated != displays { displays = updated }
    }
}

/// Called by Core Graphics when displays are added, removed or moved.
private nonisolated func displaysReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                              _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in GameMode.shared.displaysChanged() }
}

import AppKit
import SwiftUI

@main
struct GameEdgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: GameMode.shared.isActive ? "gamecontroller.fill" : "gamecontroller")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared
        // `kill`, `pkill` and launchd stop apps with a signal, which skips
        // applicationWillTerminate: quit normally so the layout is restored.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        #if DEBUG
        DebugUI.applyAppearance()
        #endif
        GameMode.shared.start()
        AppUpdater.shared.checkAtLaunch()
        var showWindow = !settings.hasLaunchedBefore
        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            #if !DEBUG
            if !LoginItem.shared.isEnabled { LoginItem.shared.set(true) }
            #endif
        }
        #if DEBUG
        if DebugUI.page != nil { showWindow = true }
        #endif
        if showWindow { MainWindowController.shared.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GameMode.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuBarMenu: View {
    private var mode = GameMode.shared
    private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings
        let status = AppStatus.current
        Text(status.detail.map { "\(status.title): \($0)" } ?? status.title)
        Divider()
        Button("Open GameEdge…") { MainWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        if mode.isActive {
            Button("Restore Normal Layout") { mode.restoreNow() }
        } else {
            Button("Use Game Layout Now") { mode.useGameLayoutNow() }
                .disabled(mode.displays.count < 2)
        }
        Toggle("Switch Automatically", isOn: $settings.automaticSwitching)
        Divider()
        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            .disabled(!AppUpdater.shared.canCheckForUpdates)
        Divider()
        Button("Quit GameEdge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Hosts `MainView` in a regular window. GameEdge is a menu bar app: it shows
/// in the Dock only while this window is open.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView())
            hosting.sceneBridgingOptions = [.title, .toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "GameEdge"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 860, height: 620))
            window.minSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("GameEdgeMainWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

#if DEBUG
/// Debug-only hooks for screenshots and design work:
/// - `GAMEEDGE_DEBUG_PAGE=layout` opens the window on a page.
/// - `GAMEEDGE_DEBUG_SAMPLE=1` shows three sample displays and never touches the real ones.
/// - `GAMEEDGE_DEBUG_APPEARANCE=dark|light` forces the appearance.
enum DebugUI {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var page: SidebarPage? {
        environment["GAMEEDGE_DEBUG_PAGE"].flatMap(SidebarPage.init(rawValue:))
    }

    static var usesSampleDisplays: Bool { environment["GAMEEDGE_DEBUG_SAMPLE"] == "1" }

    static func applyAppearance() {
        switch environment["GAMEEDGE_DEBUG_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static let sampleDisplays: [GameMode.Display] = [
        GameMode.Display(id: "main", name: "Gaming Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true),
        GameMode.Display(id: "left", name: "Left Display", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), isMain: false),
        GameMode.Display(id: "right", name: "Right Display", frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440), isMain: false),
    ]

    static let sampleEvents: [GameMode.Event] = [
        GameMode.Event(symbol: "arrow.uturn.backward.circle.fill", text: "League of Legends quit: normal layout restored"),
        GameMode.Event(symbol: "gamecontroller.fill", text: "League of Legends started: game layout on"),
    ]
}
#endif

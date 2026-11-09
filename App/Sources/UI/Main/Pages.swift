import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Overview

struct OverviewView: View {
    private var mode = GameMode.shared
    private var settings = AppSettings.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: mode.isActive ? "gamecontroller.fill" : "gamecontroller",
                     color: AppStatus.current.color, title: heroTitle, description: heroDescription) {
                Button(mode.isActive ? "Restore Normal Layout" : "Use Game Layout Now") {
                    mode.isActive ? mode.restoreNow() : mode.useGameLayoutNow()
                }
                .glassButtonStyle()
            }

            if let error = mode.lastError {
                NoticeCard(symbol: "exclamationmark.triangle.fill", color: .red,
                           title: "Something went wrong", message: error) {
                    Button("Display Settings") { NSWorkspace.shared.open(.displaySettings) }
                        .glassButtonStyle()
                }
            }

            if !settings.automaticSwitching {
                NoticeCard(symbol: "pause.fill", color: .orange, title: "Automatic switching is off",
                           message: "GameEdge won't change your displays when a game starts.") {
                    Button("Turn On") { settings.automaticSwitching = true }
                        .glassButtonStyle()
                }
            }

            SectionCard(title: "Displays now", footer: displaysFooter) {
                DisplayDiagram(frames: Dictionary(uniqueKeysWithValues: mode.displays.map { ($0.id, $0.frame) }),
                               displays: mode.displays, height: 170)
                    .padding(14)
            }

            SectionCard(title: "Recent activity") {
                if mode.events.isEmpty {
                    Text("Nothing yet. Layout changes appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                } else {
                    ForEach(Array(mode.events.prefix(6).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { RowDivider() }
                        SettingRow(symbol: event.symbol, color: event.symbol.hasPrefix("exclamation") ? .red : .blue,
                                   title: event.text) {
                            Text(GameEdgeFormat.time(event.date))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var gameNames: String {
        GameEdgeFormat.list(settings.watchedApps.filter(\.isEnabled).map(\.name))
    }

    private var heroTitle: String {
        switch mode.status {
        case .gameLayout: "Game layout on"
        case .cursorFree: "Cursor free"
        case .waiting: "Waiting for a game"
        case .paused: "Automatic switching off"
        }
    }

    private var heroDescription: String {
        switch mode.status {
        case .gameLayout(let game?):
            "\(game) is running. The other displays touch the game display only at a corner, so the cursor stays in the game. Your normal layout comes back when it quits."
        case .gameLayout(nil):
            "Turned on by hand: the game layout stays on until you restore the normal one."
        case .cursorFree(let game):
            "You switched away from \(game), so the displays are side by side again and the cursor moves freely. Go back to the game and the game layout returns."
        case .waiting:
            gameNames.isEmpty
                ? "Choose a game in Games: GameEdge will keep the cursor on its display while it runs."
                : "When \(gameNames) starts, GameEdge moves the other displays so they touch the game display only at a corner. The cursor can no longer slip out of the game."
        case .paused:
            "Turn on automatic switching to use the game layout whenever a game starts."
        }
    }

    private var displaysFooter: String {
        guard let gameID = mode.mainDisplayID else { return "" }
        if mode.displays.count < 2 { return "Only one display is connected: there's nothing to do." }
        let frames = Dictionary(uniqueKeysWithValues: mode.displays.map { ($0.id, $0.frame) })
        let open = Geometry.openEdges(frames: frames, game: gameID).map(\.edge.rawValue)
        if open.isEmpty { return "No display shares an edge with the game display: the cursor can't slip out of it." }
        return "Red: the cursor can leave the game display on the \(GameEdgeFormat.list(Array(Set(open)).sorted())) edge."
    }
}

// MARK: - Games

struct GamesView: View {
    private var mode = GameMode.shared
    private var settings = AppSettings.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "gamecontroller.fill", color: .purple, title: "Games",
                     description: "GameEdge uses the game layout while one of these apps is running, and brings back your normal layout when it quits.")

            SectionCard(title: "Watched apps",
                        footer: "Add any game that runs in fullscreen and lets the cursor slip onto another display.") {
                ForEach(Array(settings.watchedApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider() }
                    GameRow(app: app, isRunning: mode.runningGame?.id == app.id,
                            isOn: Binding(get: { app.isEnabled }, set: { setEnabled(app, $0) }),
                            remove: app.isBuiltIn ? nil : { remove(app) })
                }
            } accessory: {
                Button("Add App…", systemImage: "plus", action: addApp)
                    .glassButtonStyle()
                    .controlSize(.small)
            }
        }
    }

    private func setEnabled(_ app: WatchedApp, _ enabled: Bool) {
        guard let index = settings.watchedApps.firstIndex(where: { $0.id == app.id }) else { return }
        settings.watchedApps[index].isEnabled = enabled
        mode.refresh()
    }

    private func remove(_ app: WatchedApp) {
        settings.watchedApps.removeAll { $0.id == app.id }
        mode.refresh()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the games GameEdge should watch."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let app = WatchedApp(appURL: url), !settings.watchedApps.contains(where: { $0.id == app.id }) else { continue }
            settings.watchedApps.append(app)
        }
        mode.refresh()
    }
}

private struct GameRow: View {
    let app: WatchedApp
    let isRunning: Bool
    @Binding var isOn: Bool
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                    if isRunning { PillBadge(text: "Running", color: .green) }
                }
                Text(app.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let remove {
                HoverIconButton(symbol: "trash", help: "Remove \(app.name)", role: .destructive, action: remove)
                    .opacity(hovering || NSApplication.shared.isFullKeyboardAccessEnabled ? 1 : 0)
            }
            Toggle(app.name, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, DS.rowVPadding)
        .frame(minHeight: 46)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Layout

struct LayoutView: View {
    private var mode = GameMode.shared
    private var settings = AppSettings.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "rectangle.3.group.fill", color: .teal, title: "Game Layout",
                     description: "How your displays are arranged while you play. The game display is your main display, the one with the menu bar.")

            SectionCard(title: "Preview", footer: previewFooter) {
                HStack(spacing: 10) {
                    diagram("Normal", frames: mode.normalFrames)
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    diagram("While playing", frames: mode.gameFrames)
                }
                .padding(14)
            }

            SectionCard(title: "Layout",
                        footer: "The game layout lasts only while you play. Logging out or restarting always brings back your normal arrangement.") {
                ChoiceRow(symbol: "wand.and.stars", color: .purple, title: "Automatic",
                          subtitle: "Displays beside the game display move up into its corners.",
                          isSelected: settings.customLayout == nil) {
                    mode.useAutomaticLayout()
                } accessory: {
                    EmptyView()
                }
                RowDivider()
                ChoiceRow(symbol: "hand.draw.fill", color: .orange, title: "Custom",
                          subtitle: customSubtitle, isSelected: settings.customLayout != nil) {
                    if settings.customLayout == nil, !mode.isActive { mode.saveCurrentAsGameLayout() }
                } accessory: {
                    Button(settings.customLayout == nil ? "Save Current" : "Save Again") { mode.saveCurrentAsGameLayout() }
                        .glassButtonStyle()
                        .disabled(mode.isActive)
                        .help(mode.isActive ? "Restore the normal layout first." : "Save the current arrangement as the game layout.")
                }
                RowDivider()
                SettingRow(symbol: "display", color: .gray, title: "Display Settings",
                           subtitle: "Arrange your displays in System Settings › Displays.") {
                    Button("Open…") { NSWorkspace.shared.open(.displaySettings) }
                        .glassButtonStyle()
                }
            }
        }
    }

    private func diagram(_ title: String, frames: [String: CGRect]) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            DisplayDiagram(frames: frames, displays: mode.displays, height: 130, showsNames: false)
        }
        .frame(maxWidth: .infinity)
    }

    private var customSubtitle: String {
        guard settings.customLayout != nil else { return "Arrange the displays in System Settings, then save them as the game layout." }
        return mode.usableCustomLayout == nil
            ? "Saved for other displays: the automatic layout is used until you save again."
            : "Your saved arrangement."
    }

    private var previewFooter: String {
        guard let gameID = mode.mainDisplayID, mode.displays.count > 1 else {
            return "Connect a second display to see the game layout."
        }
        let open = Array(Set(Geometry.openEdges(frames: mode.gameFrames, game: gameID).map(\.edge.rawValue))).sorted()
        if open.isEmpty {
            return "While playing, the other displays touch the game display only at a corner: the cursor stays in the game unless you aim for that exact corner."
        }
        return "The cursor can still leave the game display on the \(GameEdgeFormat.list(open)) edge. Use the automatic layout, or save a different arrangement."
    }
}

/// A selectable row with a checkmark, like a radio group in System Settings.
private struct ChoiceRow<Accessory: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            HStack(spacing: 12) {
                accessory
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", select)
    }
}

// MARK: - General

struct GeneralView: View {
    private var settings = AppSettings.shared
    private var login = LoginItem.shared
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        @Bindable var settings = settings
        PageScroll {
            SectionCard(title: "General") {
                ToggleRow(symbol: "wand.and.stars", color: .purple, title: "Switch layouts automatically",
                          subtitle: "Use the game layout while a watched game is running.",
                          isOn: $settings.automaticSwitching)
                RowDivider()
                ToggleRow(symbol: "power", color: .green, title: "Open at login",
                          subtitle: "GameEdge lives in the menu bar and uses almost no resources.",
                          isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
            }
            .onAppear { login.refresh() }

            SectionCard(title: "While playing",
                        footer: ShakeToLocate.isSupported
                            ? "Shake to Locate is the macOS setting in Accessibility › Display › Pointer. GameEdge turns it back on as soon as the game layout ends, even after a crash."
                            : "This version of macOS doesn't let GameEdge change Shake to Locate.") {
                ToggleRow(symbol: "command", color: .indigo, title: "Free the cursor when you leave the game",
                          subtitle: "Switch to another app with ⌘Tab and the displays go back side by side. Return to the game and its layout comes back. The game keeps running.",
                          isOn: Binding(get: { settings.freeCursorOutsideGame },
                                        set: { settings.freeCursorOutsideGame = $0; GameMode.shared.refresh() }))
                RowDivider()
                ToggleRow(symbol: "option", color: .indigo, title: "⌥Tab works like ⌘Tab",
                          subtitle: "Like Alt+Tab on Windows: from the game to the app you used last, and back.",
                          isOn: Binding(get: { settings.altTabSwitches },
                                        set: { settings.altTabSwitches = $0; GameMode.shared.refresh() }))
                RowDivider()
                ToggleRow(symbol: "rectangle.inset.filled", color: .blue, title: "Full resolution and background picture",
                          subtitle: "For League of Legends, choose Borderless: the game draws directly while you play and stays visible when you switch apps. Windowed games use a video mirror, which can reduce fluidity. Needs Accessibility and Screen Recording access.",
                          isOn: Binding(get: { settings.fullResolutionWindowed },
                                        set: { settings.fullResolutionWindowed = $0; GameMode.shared.refresh() }))
                if settings.fullResolutionWindowed, !GameMirror.hasScreenRecording {
                    RowDivider()
                    SettingRow(symbol: "record.circle", color: .red, title: "Screen Recording access needed",
                               subtitle: "To show the game on the main display. Quit and reopen GameEdge after allowing it.") {
                        Button("Grant Access…") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .glassButtonStyle()
                    }
                }
                if settings.fullResolutionWindowed, !GameMirror.hasAccessibility {
                    RowDivider()
                    SettingRow(symbol: "hand.raised.fill", color: .orange, title: "Accessibility access needed",
                               subtitle: "To move the game window to the invisible display.") {
                        Button("Grant Access…") {
                            GameMirror.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .glassButtonStyle()
                    }
                }
                RowDivider()
                ToggleRow(symbol: "macwindow", color: .teal, title: "Fill the screen in Windowed mode",
                          subtitle: "Hides the menu bar and Dock while a game runs and covers the window's title bar in black. In Windowed mode the game then looks borderless and stays visible when you switch apps.",
                          isOn: Binding(get: { settings.fillScreenInWindowedMode },
                                        set: { settings.fillScreenInWindowedMode = $0; GameMode.shared.refresh() }))
                RowDivider()
                ToggleRow(symbol: "cursorarrow.motionlines", color: .pink, title: "Don't enlarge the pointer",
                          subtitle: "Turns off Shake to Locate while you play, so fast mouse movements don't make the pointer bigger.",
                          isOn: Binding(get: { settings.disableShakeToLocate },
                                        set: { settings.disableShakeToLocate = $0; GameMode.shared.refresh() }))
                    .disabled(!ShakeToLocate.isSupported)
            }

            SectionCard(title: "Updates",
                        footer: AppUpdater.isEnabled
                            ? "GameEdge checks for a new version at launch and once a day. Automatic updates are installed when you quit the app."
                            : "Development builds don’t update themselves.") {
                ToggleRow(symbol: "arrow.triangle.2.circlepath", color: .blue,
                          title: "Check for updates automatically",
                          isOn: $updater.automaticallyChecks)
                    .disabled(!AppUpdater.isEnabled)
                if updater.allowsAutomaticDownloads {
                    RowDivider()
                    ToggleRow(symbol: "arrow.down.circle.fill", color: .teal,
                              title: "Download and install automatically",
                              isOn: $updater.automaticallyDownloads)
                        .disabled(!updater.automaticallyChecks || !AppUpdater.isEnabled)
                }
                RowDivider()
                SettingRow(symbol: "shippingbox.fill", color: .orange,
                           title: "Version \(updater.versionDescription)") {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .glassButtonStyle()
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            .onAppear { updater.refresh() }

            SectionCard(title: "Troubleshooting") {
                SettingRow(symbol: "doc.text.fill", color: .gray, title: "Log",
                           subtitle: "When GameEdge changed the layout, and why. Attach it to a bug report.") {
                    Button("Open") { NSWorkspace.shared.open(Log.url) }
                        .glassButtonStyle()
                }
                RowDivider()
                SettingRow(symbol: "ladybug.fill", color: .red, title: "Report a problem",
                           subtitle: "Opens a new issue on GitHub.") {
                    Button("Open") { NSWorkspace.shared.open(.newIssue) }
                        .glassButtonStyle()
                }
            }

            AboutCard()
        }
    }
}

private struct AboutCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("GameEdge").font(.headline)
                Text("Keeps the cursor inside fullscreen games on Macs with more than one display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("No data leaves your Mac, except the daily update check on GitHub.",
                      systemImage: "lock.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardSurface()
    }
}

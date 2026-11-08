import SwiftUI

/// What GameEdge is doing right now, shared by the sidebar, the overview and the menu.
struct AppStatus {
    enum Kind { case active, free, ready, paused, error }

    let kind: Kind
    let title: String
    var detail: String?

    var color: Color {
        switch kind {
        case .active: .blue
        case .free: .teal
        case .ready: .green
        case .paused: .orange
        case .error: .red
        }
    }

    static var current: AppStatus {
        let mode = GameMode.shared
        if mode.lastError != nil {
            return AppStatus(kind: .error, title: "Something went wrong", detail: "See Overview")
        }
        switch mode.status {
        case .gameLayout(let game):
            return AppStatus(kind: .active, title: "Game layout on", detail: game ?? "Turned on by hand")
        case .cursorFree(let game):
            return AppStatus(kind: .free, title: "Cursor free", detail: "\(game) in the background")
        case .waiting:
            return AppStatus(kind: .ready, title: "Ready", detail: "Waiting for a game")
        case .paused:
            return AppStatus(kind: .paused, title: "Automatic switching off")
        }
    }
}

/// Coloured dot, pulsing while the game layout is on.
struct StatusDot: View {
    let status: AppStatus

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .frame(width: 8, height: 8)
            .background {
                Circle().fill(status.color.opacity(0.25)).frame(width: 14, height: 14)
            }
            .phaseAnimator([false, true], trigger: status.kind == .active) { dot, phase in
                dot.opacity(status.kind == .active && phase ? 0.45 : 1)
            }
            .frame(width: 14, height: 14)
    }
}

/// Icon of a watched app, or a coloured tile when the app isn't installed.
struct AppIconView: View {
    let app: WatchedApp
    var size: CGFloat = DS.rowIcon

    var body: some View {
        if let icon = GameDetector.icon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size + 4, height: size + 4)
                .frame(width: size, height: size)
        } else {
            IconTile(systemName: "gamecontroller.fill", color: .purple, size: size)
        }
    }
}

enum GameEdgeFormat {
    /// The UI is English-only, whatever the Mac's language.
    static let locale = Locale(identifier: "en_US")

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    /// "left and right", "left, top and right".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

extension URL {
    static let displaySettings = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
    static let newIssue = URL(string: "https://github.com/IGOLz/GameEdge/issues/new/choose")!
}

import SwiftUI

enum SidebarPage: String, Hashable, CaseIterable, Identifiable {
    case overview, games, layout, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .games: "Games"
        case .layout: "Game Layout"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house.fill"
        case .games: "gamecontroller.fill"
        case .layout: "rectangle.3.group.fill"
        case .general: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: .blue
        case .games: .purple
        case .layout: .teal
        case .general: .gray
        }
    }

    static let main: [SidebarPage] = [.overview, .games, .layout]
    static let settings: [SidebarPage] = [.general]
}

struct MainView: View {
    @State private var selection: SidebarPage? = .overview
    /// Back/forward navigation between pages, like System Settings.
    @State private var backStack: [SidebarPage] = []
    @State private var forwardStack: [SidebarPage] = []
    @State private var navigatingHistory = false

    init() {
        #if DEBUG
        if let page = DebugUI.page { _selection = State(initialValue: page) }
        #endif
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarPage.main) { page in
                        SidebarRow(page: page).tag(page)
                    }
                }
                Section("Settings") {
                    ForEach(SidebarPage.settings) { page in
                        SidebarRow(page: page).tag(page)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarStatus()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: selection ?? .overview)
                .id(selection)
                .transition(.opacity)
                // Every page has the same toolbar, so the window chrome never moves.
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .help("Back")
                            .keyboardShortcut("[", modifiers: .command)
                            .disabled(backStack.isEmpty)
                        Button("Forward", systemImage: "chevron.right", action: goForward)
                            .help("Forward")
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(forwardStack.isEmpty)
                    }
                }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .onChange(of: selection) { old, _ in
            if navigatingHistory {
                navigatingHistory = false
            } else if let old {
                backStack.append(old)
                forwardStack.removeAll()
            }
        }
        .background(WindowTitle(title: (selection ?? .overview).title))
        .frame(minWidth: 720, minHeight: 500)
    }

    private func goBack() {
        guard let page = backStack.popLast() else { return }
        if let selection { forwardStack.append(selection) }
        navigatingHistory = true
        selection = page
    }

    private func goForward() {
        guard let page = forwardStack.popLast() else { return }
        if let selection { backStack.append(selection) }
        navigatingHistory = true
        selection = page
    }

    @ViewBuilder
    private func detail(for page: SidebarPage) -> some View {
        switch page {
        case .overview: OverviewView()
        case .games: GamesView()
        case .layout: LayoutView()
        case .general: GeneralView()
        }
    }
}

private struct SidebarRow: View {
    let page: SidebarPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            IconTile(systemName: page.symbol, color: page.color, size: 22)
        }
    }
}

/// Live status at the bottom of the sidebar.
private struct SidebarStatus: View {
    var body: some View {
        let status = AppStatus.current
        HStack(spacing: 8) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .animation(.snappy, value: status.title)
    }
}

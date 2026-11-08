import AppKit
import SwiftUI

/// A System Settings–style coloured icon tile.
struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(color.gradient, in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.5)
            }
    }
}

/// A small coloured capsule label ("Recommended", "Not pasted"…).
struct PillBadge: View {
    let text: String
    var color: Color = .accentColor
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: .capsule)
    }
}

/// `MainView` lives in an `NSHostingController` that doesn't bridge
/// `.navigationTitle` to the window, so set the NSWindow title directly.
struct WindowTitle: NSViewRepresentable {
    let title: String
    var subtitle: String = ""

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.subtitle = subtitle
        view.apply()
    }

    final class TitleView: NSView {
        var title = ""
        var subtitle = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // MainWindowController assigns its own title right after creating
            // the window: re-apply once that has happened.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else { return }
            if window.title != title { window.title = title }
            if window.subtitle != subtitle { window.subtitle = subtitle }
        }
    }
}


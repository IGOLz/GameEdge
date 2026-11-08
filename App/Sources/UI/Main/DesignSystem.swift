import AppKit
import SwiftUI

// MARK: - Tokens

/// Shared spacing, radii and sizes, so every page has the same rhythm.
nonisolated enum DS {
    static let pagePadding: CGFloat = 24
    static let pageTop: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let headerSpacing: CGFloat = 8
    static let cardRadius: CGFloat = 14
    static let rowHPadding: CGFloat = 14
    static let rowVPadding: CGFloat = 11
    static let rowIcon: CGFloat = 26
    static let gridSpacing: CGFloat = 12
    static let maxContentWidth: CGFloat = 780
}

extension Color {
    /// Page background behind the cards: a soft grey in light mode, the window
    /// colour in dark mode.
    static let pageBackground = Color(nsColor: .dynamic(
        light: NSColor(calibratedWhite: 0.962, alpha: 1),
        dark: .windowBackgroundColor))

    /// Card surface: white in light mode, a lifted translucent grey in dark mode.
    static let cardFill = Color(nsColor: .dynamic(
        light: .white,
        dark: NSColor(calibratedWhite: 1, alpha: 0.055)))

    static let cardStroke = Color(nsColor: .dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.075),
        dark: NSColor(calibratedWhite: 1, alpha: 0.075)))

    /// Hover/pressed tint inside cards.
    static let rowHover = Color(nsColor: .dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.035),
        dark: NSColor(calibratedWhite: 1, alpha: 0.045)))
}

extension NSColor {
    nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Surfaces

struct CardSurface: ViewModifier {
    var radius: CGFloat = DS.cardRadius
    var highlighted = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(Color.cardFill)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.045), radius: 2, y: 1)
            }
            .overlay {
                shape.strokeBorder(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.cardStroke),
                                   lineWidth: highlighted ? 1.5 : 1)
            }
            .clipShape(shape)
    }
}

extension View {
    func cardSurface(radius: CGFloat = DS.cardRadius, highlighted: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, highlighted: highlighted))
    }

    /// Background of every sidebar page.
    func pageBackground() -> some View {
        background(Color.pageBackground.ignoresSafeArea())
    }
}

// MARK: - Page scaffolding

/// Scrollable, centred column used by every page.
struct PageScroll<Content: View>: View {
    var spacing: CGFloat = DS.sectionSpacing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, DS.pagePadding)
                .padding(.top, DS.pageTop)
                .padding(.bottom, 32)
                .frame(maxWidth: DS.maxContentWidth)
                .frame(maxWidth: .infinity)
                .background(OverlayScrollers())
        }
        .pageBackground()
    }
}

/// Uses overlay scrollers for the enclosing scroll view, so a legacy
/// (always visible) scroll bar doesn't take 15 pt from the content: every
/// page keeps the same width whether it scrolls or not.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerStyleView { ScrollerStyleView() }
    func updateNSView(_ view: ScrollerStyleView, context: Context) { view.apply() }

    final class ScrollerStyleView: NSView {
        private var observing = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard !observing else { return }
            observing = true
            // AppKit resets the style when the user preference changes.
            NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged),
                                                   name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                   object: nil)
        }

        @objc private func preferenceChanged() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }
    }
}

/// Large icon + title + description at the top of a page (System Settings style).
struct PageHero<Accessory: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let description: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(systemName: symbol, color: color, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

extension PageHero where Accessory == EmptyView {
    init(symbol: String, color: Color, title: String, description: String) {
        self.init(symbol: symbol, color: color, title: title, description: description) { EmptyView() }
    }
}

/// Section title (+ optional trailing accessory), a card with the rows, and an
/// optional footer.
struct SectionCard<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title { SectionTitle(title) }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .cardSurface()
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, content: content) { EmptyView() }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.leading, 4)
    }
}

/// A settings row: coloured icon, title, optional subtitle and a trailing control.
struct SettingRow<Trailing: View>: View {
    var symbol: String?
    var color: Color = .gray
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                IconTile(systemName: symbol, color: color, size: DS.rowIcon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, DS.rowVPadding)
        .frame(minHeight: 46)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(symbol: String? = nil, color: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A toggle row with a switch on the trailing edge.
struct ToggleRow: View {
    var symbol: String?
    var color: Color = .gray
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Hairline between rows of a card, inset past the row icon.
struct RowDivider: View {
    var inset: CGFloat = DS.rowHPadding + DS.rowIcon + 12

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Tinted call-out card (missing permissions, tips).
struct NoticeCard<Action: View>: View {
    let symbol: String
    var color: Color = .orange
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(14)
        .background(color.opacity(0.09), in: .rect(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        }
    }
}

/// Friendly placeholder inside a page (no data yet / no results).
struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 2)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(Color.cardStroke, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }
}

/// Small round icon button that appears on hover (copy, delete…).
struct HoverIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(role == .destructive && hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .background(hovering ? Color.rowHover : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}


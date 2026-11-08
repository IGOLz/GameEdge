import AppKit

/// Black bands over what a game in Windowed mode leaves visible on the game
/// display: its title bar, the strip below the window and the rounded corners.
/// Together with the hidden menu bar and Dock, the game looks borderless but,
/// unlike Borderless mode, stays on screen when you switch to another app.
/// Clicking a band brings you back to the game.
final class WindowedGameBands {
    static let shared = WindowedGameBands()

    /// Height of a standard title bar, measured from AppKit (32 pt on macOS 26+).
    private let titleBarHeight = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                                    styleMask: [.titled, .closable, .miniaturizable]).height - 100
    /// Corner radius of standard windows (generous, so no desktop shows through).
    private let cornerRadius: CGFloat = 18

    private var panels: [BandPanel] = []
    private var timer: Timer?
    private var game: NSRunningApplication?

    /// Shows the bands while `game` runs in Windowed mode on the game display; nil removes them.
    func follow(_ game: NSRunningApplication?) {
        self.game = game
        if game == nil {
            timer?.invalidate()
            timer = nil
            update()
            return
        }
        if timer == nil {
            // The game resizes itself when the menu bar and Dock hide: follow it.
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { WindowedGameBands.shared.update() }
            }
        }
        update()
    }

    private func update() {
        guard let game, !game.isTerminated, let window = gameWindowFrame(pid: game.processIdentifier) else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        let display = CGDisplayBounds(CGMainDisplayID())
        // A game window on the game display; a smaller 16:9 window (e.g. 2048×1152)
        // gets a black frame all around.
        guard window.width >= display.width * 0.5, display.contains(CGPoint(x: window.midX, y: window.midY)) else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        let content = CGRect(x: window.minX, y: window.minY + titleBarHeight,
                             width: window.width, height: window.height - titleBarHeight)
        var bands: [CGRect] = []
        if content.minY > display.minY {
            bands.append(CGRect(x: display.minX, y: display.minY, width: display.width, height: content.minY - display.minY))
        }
        let bottom = content.maxY - cornerRadius
        if display.maxY > bottom {
            bands.append(CGRect(x: display.minX, y: bottom, width: display.width, height: display.maxY - bottom))
        }
        if content.minX > display.minX {
            bands.append(CGRect(x: display.minX, y: display.minY, width: content.minX - display.minX, height: display.height))
        }
        if display.maxX > content.maxX {
            bands.append(CGRect(x: content.maxX, y: display.minY, width: display.maxX - content.maxX, height: display.height))
        }
        while panels.count < bands.count { panels.append(BandPanel()) }
        for (index, panel) in panels.enumerated() {
            guard index < bands.count else {
                panel.orderOut(nil)
                continue
            }
            panel.show(band: bands[index], gameContent: content, cornerRadius: cornerRadius,
                       onClick: { [weak self] in self?.game?.activate() })
        }
    }

    /// The game's main window (normal level, on screen), in global top-left coordinates.
    private func gameWindowFrame(pid: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        .max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// A borderless, non-activating black panel above normal windows.
private final class BandPanel: NSPanel {
    private let bandView = BandView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = bandView
    }

    // AppKit keeps windows below the menu bar area; the top band must cover it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `band` and `gameContent` are global top-left coordinates.
    func show(band: CGRect, gameContent: CGRect, cornerRadius: CGFloat, onClick: @escaping () -> Void) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? band.maxY
        let frame = NSRect(x: band.minX, y: primaryHeight - band.maxY, width: band.width, height: band.height)
        if self.frame != frame { setFrame(frame, display: false) }
        // The game's visible content, in this band's (bottom-left) coordinates.
        let content = NSRect(x: gameContent.minX - band.minX, y: band.maxY - gameContent.maxY,
                             width: gameContent.width, height: gameContent.height)
        if bandView.gameContent != content || bandView.cornerRadius != cornerRadius {
            bandView.gameContent = content
            bandView.cornerRadius = cornerRadius
            bandView.needsDisplay = true
        }
        bandView.onClick = onClick
        if !isVisible { orderFrontRegardless() }
    }
}

private final class BandView: NSView {
    var gameContent = NSRect.zero
    var cornerRadius: CGFloat = 0
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        // Black everywhere except the game picture, whose bottom corners are rounded.
        let path = NSBezierPath(rect: bounds)
        path.append(roundedBottomRect(gameContent, radius: cornerRadius))
        path.windingRule = .evenOdd
        NSColor.black.setFill()
        path.fill()
    }

    private func roundedBottomRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                       startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

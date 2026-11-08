import AppKit
import ApplicationServices
import QuartzCore
import ScreenCaptureKit

/// Full resolution for games in Windowed mode.
///
/// On a single display a windowed game can't be 2560×1440: macOS keeps its
/// 32 pt title bar on screen, so the picture loses 64 rows and the game
/// changes its aspect. GameEdge instead creates an invisible virtual display a
/// little taller than the main one, moves the game window there (where it
/// renders at full resolution), and shows the picture without the title bar
/// on the main display, live, through ScreenCaptureKit (like OBS). Unlike
/// Borderless mode, a windowed game keeps drawing when you switch apps, so it
/// stays visible while you work on the other displays.
///
/// While you play the cursor lives on the virtual display, which touches the
/// others only at a corner, so it can't slip out of the game. When you leave
/// the game it moves to the matching point of the main display; clicking the
/// picture brings you back.
final class GameMirror {
    static let shared = GameMirror()

    /// The extra height that leaves room for the virtual display's menu bar and the game's title bar.
    private static let extraHeight = 160
    private let titleBar: CGFloat = 32

    private(set) var isRunning = false
    private var game: NSRunningApplication?
    private var virtualDisplay: CGVirtualDisplay?
    private var virtualID: CGDirectDisplayID = 0
    private var panel: MirrorPanel?
    private var stream: SCStream?
    private let output = MirrorOutput()
    private var capturedWindowSize = CGSize.zero
    private var timer: Timer?
    private var content: CGRect?
    private var didAskForAccessibility = false

    // MARK: Permissions

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Whether `pid` shows a normal (windowed) game window, as opposed to Borderless.
    static func isWindowed(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width >= 1000 && rect.height >= 600
        }
    }

    // MARK: Lifecycle

    func start(game: NSRunningApplication) {
        guard !isRunning else { return }
        guard Self.hasAccessibility else {
            if !didAskForAccessibility {
                didAskForAccessibility = true
                Log.write("full resolution: Accessibility access needed to move the game window")
                Self.requestAccessibility()
            }
            return
        }
        let main = CGMainDisplayID()
        let bounds = CGDisplayBounds(main)
        let refresh = CGDisplayCopyDisplayMode(main)?.refreshRate ?? 60
        let width = UInt32(bounds.width), height = UInt32(bounds.height) + UInt32(Self.extraHeight)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "GameEdge Game Display"
        descriptor.maxPixelsWide = width
        descriptor.maxPixelsHigh = height
        // Same pixel density as a 27" 1440p panel.
        descriptor.sizeInMillimeters = CGSize(width: Double(width) * 0.2331, height: Double(height) * 0.2331)
        descriptor.vendorID = 0x4745
        descriptor.productID = 0x0001
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            Log.write("full resolution: couldn't create the virtual display")
            return
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: refresh > 0 ? refresh : 60)]
        guard display.apply(settings) else {
            Log.write("full resolution: the virtual display refused its mode")
            return
        }
        virtualDisplay = display
        virtualID = display.displayID
        Displays.excludedDisplayIDs.insert(virtualID)
        self.game = game
        isRunning = true
        Log.write("full resolution on: virtual display \(width)×\(height) @ \(Int(refresh)) Hz")

        showPanel(on: main)
        // The display needs a moment to come online before it can be arranged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { GameMirror.shared.tick() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        capturedWindowSize = .zero
        panel?.orderOut(nil)
        let main = CGDisplayBounds(CGMainDisplayID())
        if CGDisplayBounds(virtualID).contains(cursorLocation) {
            CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        // Releasing the object removes the display; macOS moves the game window back.
        virtualDisplay = nil
        Displays.excludedDisplayIDs.remove(virtualID)
        virtualID = 0
        game = nil
        content = nil
        Log.write("full resolution off")
    }

    // MARK: Focus

    /// Back in the game: the cursor goes to the same point of the game on the virtual display.
    func gameDidActivate() {
        guard isRunning else { return }
        let here = cursorLocation
        let virtualBounds = CGDisplayBounds(virtualID)
        guard !virtualBounds.contains(here) else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        if let target = toVirtual(main.contains(here) ? here : CGPoint(x: main.midX, y: main.midY)) {
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// Another app: the cursor comes back to the matching point of the main display.
    func gameDidDeactivate() {
        guard isRunning, CGDisplayBounds(virtualID).contains(cursorLocation),
              let target = toMain(cursorLocation) else { return }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func clickedPicture() {
        guard let game else { return }
        gameDidActivate()
        if !game.activate(options: []), let url = game.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    // MARK: Upkeep

    private func tick() {
        guard isRunning, let game, !game.isTerminated else { return }
        placeVirtualDisplay()
        moveGameWindowToVirtualDisplay()
        Task { await updateCapture() }
    }

    /// Keeps the virtual display touching the arrangement only at a corner,
    /// below the bottom-left display, so the cursor can't wander in or out.
    private func placeVirtualDisplay() {
        let physical = Displays.online().map(\.frame)
        guard let anchor = physical.max(by: { ($0.maxY, -$0.minX) < ($1.maxY, -$1.minX) }) else { return }
        let size = CGDisplayBounds(virtualID).size
        let target = CGPoint(x: anchor.minX - size.width, y: anchor.maxY)
        guard CGDisplayBounds(virtualID).origin != target else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, virtualID, Int32(target.x), Int32(target.y))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func moveGameWindowToVirtualDisplay() {
        guard let game, let window = gameAXWindow(pid: game.processIdentifier) else { return }
        let virtualBounds = CGDisplayBounds(virtualID)
        let frame = axFrame(window)
        if !virtualBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            var origin = virtualBounds.origin
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
            Log.write("full resolution: game window moved to the virtual display")
        }
        let moved = axFrame(window)
        content = CGRect(x: moved.minX, y: moved.minY + titleBar, width: moved.width, height: moved.height - titleBar)
    }

    private func updateCapture() async {
        guard isRunning, let game,
              let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = shareable.windows
                .filter({ $0.owningApplication?.processID == game.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        guard isRunning, window.frame.size != capturedWindowSize else { return }
        let configuration = streamConfiguration(for: window)
        do {
            if let stream {
                try await stream.updateConfiguration(configuration)
            } else {
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                      configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                self.stream = stream
            }
            capturedWindowSize = window.frame.size
            Log.write("full resolution: showing \(Int(window.frame.width))×\(Int(window.frame.height - titleBar))")
        } catch {
            Log.write("full resolution: capture failed (\(error.localizedDescription)); Screen Recording access may be needed")
        }
    }

    private func streamConfiguration(for window: SCWindow) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let picture = CGRect(x: 0, y: titleBar, width: window.frame.width, height: max(window.frame.height - titleBar, 1))
        configuration.sourceRect = picture
        configuration.width = Int(picture.width)
        configuration.height = Int(picture.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let refresh = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 60
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(refresh, 60).rounded()))
        configuration.queueDepth = 4
        configuration.showsCursor = true
        return configuration
    }

    // MARK: Panel

    private func showPanel(on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return }
        let panel = self.panel ?? MirrorPanel()
        self.panel = panel
        panel.mirrorView.onClick = { [weak self] in self?.clickedPicture() }
        output.layer = panel.mirrorView.layer
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Geometry

    private var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Where the picture sits on the main display (aspect fit).
    private func shownRect(for content: CGRect) -> CGRect {
        let main = CGDisplayBounds(CGMainDisplayID())
        let scale = min(main.width / content.width, main.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func toVirtual(_ point: CGPoint) -> CGPoint? {
        guard let content else { return nil }
        let shown = shownRect(for: content)
        let x = min(max(point.x, shown.minX), shown.maxX - 1), y = min(max(point.y, shown.minY), shown.maxY - 1)
        return CGPoint(x: content.minX + (x - shown.minX) * content.width / shown.width,
                       y: content.minY + (y - shown.minY) * content.height / shown.height)
    }

    private func toMain(_ point: CGPoint) -> CGPoint? {
        guard let content else { return nil }
        let shown = shownRect(for: content)
        return CGPoint(x: shown.minX + (point.x - content.minX) * shown.width / content.width,
                       y: shown.minY + (point.y - content.minY) * shown.height / content.height)
    }

    private func gameAXWindow(pid: pid_t) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            return subrole as? String == kAXStandardWindowSubrole
        }
    }

    private func axFrame(_ window: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}

/// Receives frames on its own queue and hands the IOSurface to the panel's layer (no copy).
private nonisolated final class MirrorOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.igol.GameEdge.mirror", qos: .userInteractive)
    nonisolated(unsafe) weak var layer: CALayer?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let box = SurfaceBox(surface: surface, layer: layer)
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            box.layer?.contents = box.surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { Log.write("full resolution: capture stopped (\(message))") }
    }
}

private nonisolated struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
    weak var layer: CALayer?
}

/// Black, borderless, non-activating, above the menu bar and the Dock.
private final class MirrorPanel: NSPanel {
    let mirrorView = MirrorView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        mirrorView.wantsLayer = true
        mirrorView.layer?.backgroundColor = NSColor.black.cgColor
        mirrorView.layer?.contentsGravity = .resizeAspect
        contentView = mirrorView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class MirrorView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

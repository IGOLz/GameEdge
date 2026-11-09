import AppKit
import ApplicationServices
import QuartzCore
import ScreenCaptureKit
import Metal

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
    /// Height of a standard title bar on this macOS (28 pt before macOS 26, 32 pt since).
    private let titleBar = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                              styleMask: [.titled, .closable, .miniaturizable]).height - 100
    private var mainDisplay: CGDirectDisplayID = 0

    private(set) var isRunning = false
    private var game: NSRunningApplication?
    private var virtualDisplay: CGVirtualDisplay?
    private var virtualID: CGDirectDisplayID = 0
    private var panel: MirrorPanel?
    private var stream: SCStream?
    private var output: MirrorOutput?
    private var generation = UUID()
    private var updatingCapture: UUID?
    private var capturedWindowID: CGWindowID?
    private var capturedWindowSize = CGSize.zero
    private var timer: Timer?
    private var content: CGRect?
    private var didAskForAccessibility = false
    private var didAskForScreenRecording = false

    // MARK: Permissions

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var hasPermissions: Bool { hasAccessibility && hasScreenRecording }

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
        // Without both permissions the game simply stays where it is (Windowed, with the black bands).
        guard Self.hasAccessibility else {
            if !didAskForAccessibility {
                didAskForAccessibility = true
                Log.write("full resolution: Accessibility access needed to move the game window")
                Self.requestAccessibility()
            }
            return
        }
        guard Self.hasScreenRecording else {
            if !didAskForScreenRecording {
                didAskForScreenRecording = true
                Log.write("full resolution: Screen Recording access needed to show the game")
                CGRequestScreenCaptureAccess()
            }
            return
        }
        let main = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(main) else { return }
        // Pixels, so Retina displays get the game at their native resolution.
        let width = UInt32(max(mode.pixelWidth, mode.width))
        let height = UInt32(max(mode.pixelHeight, mode.height) + Self.extraHeight)
        let refresh = Self.refreshRate(of: main, mode: mode)
        mainDisplay = main

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
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: refresh)]
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

        generation = UUID()
        guard showPanel(on: main) else {
            stop()
            return
        }
        // The display needs a moment to come online before it can be arranged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { GameMirror.shared.tick() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation = UUID()
        updatingCapture = nil
        timer?.invalidate()
        timer = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        output?.renderer.stop()
        output = nil
        capturedWindowID = nil
        capturedWindowSize = .zero
        panel?.orderOut(nil)
        panel = nil
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

    /// ProMotion and some built-in displays report 0 Hz: ask the screen instead.
    private static func refreshRate(of display: CGDirectDisplayID, mode: CGDisplayMode) -> Double {
        if mode.refreshRate > 0 { return mode.refreshRate }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        let fps = screen?.maximumFramesPerSecond ?? 60
        return Double(fps > 0 ? fps : 60)
    }

    private func tick() {
        guard isRunning, let game, !game.isTerminated else { return }
        // A different main display (plugged, unplugged, rearranged): start over on the new one.
        guard CGMainDisplayID() == mainDisplay else {
            Log.write("full resolution: the main display changed")
            stop()
            GameMode.shared.refresh()
            return
        }
        placeVirtualDisplay()
        moveGameWindowToVirtualDisplay()
        Task { await updateCapture() }
    }

    /// Keeps the virtual display touching the arrangement only at a corner,
    /// below the bottom-left display, so the cursor can't wander in or out.
    private func placeVirtualDisplay() {
        let size = CGDisplayBounds(virtualID).size
        guard size.width > 0, let target = Geometry.cornerOrigin(for: size, beside: Displays.online().map(\.frame)),
              CGDisplayBounds(virtualID).origin != target else { return }
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
        guard isRunning, updatingCapture == nil, let game, let output else { return }
        let session = generation
        updatingCapture = session
        defer { if updatingCapture == session { updatingCapture = nil } }
        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            guard isRunning, generation == session else { return }
            if !didAskForScreenRecording {
                didAskForScreenRecording = true
                Log.write("full resolution: Screen Recording access needed (\(error.localizedDescription))")
                panel?.mirrorView.showMessage("Allow Screen Recording for GameEdge",
                                              detail: "System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen GameEdge. Click here to go back to the game meanwhile.")
                CGRequestScreenCaptureAccess()
            }
            return
        }
        guard isRunning, generation == session,
              let window = shareable.windows
                .filter({ $0.owningApplication?.processID == game.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        guard window.frame.size != capturedWindowSize || window.windowID != capturedWindowID else { return }
        let configuration = streamConfiguration(for: window)
        do {
            if let stream {
                if capturedWindowID != window.windowID {
                    try await stream.updateContentFilter(SCContentFilter(desktopIndependentWindow: window))
                    guard isRunning, generation == session else { return }
                }
                try await stream.updateConfiguration(configuration)
            } else {
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                      configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                Log.write("capture creating \(ObjectIdentifier(stream)) session=\(session)")
                try await stream.startCapture()
                guard isRunning, generation == session else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                Log.write("capture started \(ObjectIdentifier(stream))")
            }
            guard isRunning, generation == session else { return }
            capturedWindowSize = window.frame.size
            capturedWindowID = window.windowID
            if let video = panel?.mirrorView.videoLayer {
                Log.write("Metal actual properties: transaction=\(video.presentsWithTransaction) sync=\(video.displaySyncEnabled) drawables=\(video.maximumDrawableCount), size=\(video.drawableSize) frame=\(video.frame) bounds=\(video.bounds) rasterize=\(video.shouldRasterize)")
            }
            panel?.mirrorView.showMessage(nil)
            Log.write("full resolution: showing \(Int(window.frame.width))×\(Int(window.frame.height - titleBar))")
        } catch {
            guard isRunning, generation == session else { return }
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
        // Native capture cadence, including fractional refresh rates and ProMotion.
        configuration.minimumFrameInterval = .zero
        configuration.queueDepth = 5
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        return configuration
    }

    // MARK: Panel

    private func showPanel(on display: CGDirectDisplayID) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return false }
        let panel = MirrorPanel()
        let renderer: MirrorRenderer
        do {
            renderer = try MirrorRenderer(layer: panel.mirrorView.videoLayer, refreshRate: Float(max(screen.maximumFramesPerSecond, 60))) { message in
                DispatchQueue.main.async { Log.write(message) }
            }
        } catch {
            Log.write("full resolution: Metal unavailable (\(error)); keeping the game in its window")
            return false
        }
        self.panel = panel
        panel.mirrorView.onClick = { [weak self] in self?.clickedPicture() }
        let session = generation
        output = MirrorOutput(renderer: renderer) { [weak self] message in
            guard let self, self.generation == session else { return }
            Log.write("full resolution: capture stopped (\(message))")
            self.stop()
        }
        panel.setFrame(screen.frame, display: true)
        panel.mirrorView.updateDrawableSize()
        panel.orderFrontRegardless()
        return true
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

/// Each stream owns its output; callbacks from a stopped session can't update a new one.
private nonisolated final class MirrorOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.igol.GameEdge.mirror", qos: .userInteractive)
    let renderer: MirrorRenderer
    let onStop: @MainActor @Sendable (String) -> Void

    init(renderer: MirrorRenderer, onStop: @escaping @MainActor @Sendable (String) -> Void) {
        self.renderer = renderer
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        renderer.submit(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.onStop(message) }
    }
}

/// Black, borderless, non-activating, above the menu bar and the Dock.
private final class MirrorPanel: NSWindow {
    let mirrorView = MirrorView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .normal
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = mirrorView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class MirrorView: NSView {
    var videoLayer: CAMetalLayer { layer as! CAMetalLayer }

    override var isOpaque: Bool { true }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    var onClick: (() -> Void)?
    private var message: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        videoLayer.device = MTLCreateSystemDefaultDevice()
        videoLayer.pixelFormat = .bgra8Unorm
        videoLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        videoLayer.framebufferOnly = true
        videoLayer.maximumDrawableCount = 3
        videoLayer.presentsWithTransaction = false
        videoLayer.displaySyncEnabled = true
        videoLayer.isOpaque = true
        videoLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
        videoLayer.drawableSize = size
    }

    /// A centred explanation over the black picture (nil hides it).
    func showMessage(_ title: String?, detail: String = "") {
        message?.removeFromSuperview()
        message = nil
        guard let title else { return }
        let label = NSTextField(wrappingLabelWithString: detail.isEmpty ? title : title + "\n\n" + detail)
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
        ])
        message = label
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

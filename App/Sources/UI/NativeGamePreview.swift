import AppKit
import QuartzCore
import Darwin

/// The game draws directly while playing; only its inactive window is copied.
final class NativeGamePreview {
    static let shared = NativeGamePreview()
    private var game: NSRunningApplication?
    private var windowID: CGWindowID?
    private var panel: PreviewPanel?
    private var timer: Timer?
    private var generation = UUID()
    private var capturing = false
    private var displayedFrames = 0
    private var reportedUnavailable = false
    private let queue = DispatchQueue(label: "dev.igol.GameEdge.background-preview", qos: .utility)
    private let capture = HiddenWindowCapture()
    private(set) var isRunning = false

    func follow(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { stop(); return }
        if game?.processIdentifier != app.processIdentifier {
            stop()
            game = app
        }
        isRunning = true
        if app.isActive {
            suspendCapture()
            return
        }
        guard CGPreflightScreenCaptureAccess(), capture != nil else {
            suspendCapture()
            if !reportedUnavailable {
                reportedUnavailable = true
                Log.write(capture == nil ? "native game: background capture API unavailable on this macOS" : "native game: Screen Recording access needed for the background preview")
            }
            return
        }
        guard let window = Self.window(pid: app.processIdentifier) else { suspendCapture(); return }
        if windowID != window {
            generation = UUID()
            capturing = false
            panel?.contentView?.layer?.contents = nil
        }
        windowID = window
        let panel = panel ?? PreviewPanel()
        self.panel = panel
        panel.onClick = { [weak self] in self?.activateGame() }
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }), panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
        guard timer == nil else { return }
        generation = UUID()
        displayedFrames = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawNextFrame() }
        }
        drawNextFrame()
        Log.write("native game: background preview started")
    }

    func stop() {
        suspendCapture()
        panel = nil
        game = nil
        windowID = nil
        isRunning = false
    }

    private func suspendCapture() {
        let wasCapturing = timer != nil
        timer?.invalidate()
        timer = nil
        generation = UUID()
        capturing = false
        panel?.orderOut(nil)
        panel?.contentView?.layer?.contents = nil
        if wasCapturing { Log.write("native game: preview stopped after \(displayedFrames) frames; direct presentation") }
    }

    private func drawNextFrame() {
        guard let game, !game.isTerminated else { stop(); return }
        guard !game.isActive else { suspendCapture(); return }
        guard !capturing, let capture, let windowID else { return }
        capturing = true
        let session = generation
        queue.async { [weak self] in
            let image = capture.image(windowID: windowID)
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.capturing = false
                guard self.game?.isActive == false, let image, let panel = self.panel else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                panel.contentView?.layer?.contents = image
                CATransaction.commit()
                self.displayedFrames += 1
                if !panel.isVisible { panel.orderBack(nil) }
            }
        }
    }

    private func activateGame() {
        guard let game else { return }
        suspendCapture()
        if !game.activate(options: []), let url = game.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private static func window(pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        return windows.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid &&
            $0[kCGWindowName as String] as? String == "League of Legends (TM) Client"
        }?[kCGWindowNumber as String] as? CGWindowID
    }
}

/// ScreenCaptureKit freezes ordered-out LoL windows; this capture path keeps updating.
/// Private API: if unavailable, leave native gameplay working without a preview.
nonisolated final class HiddenWindowCapture: @unchecked Sendable {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Capture = @convention(c) (UInt32, UnsafePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private let connection: UInt32
    private let capture: Capture
    private let handle: UnsafeMutableRawPointer

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let connection = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "SLSMainConnectionID"),
              let capture = dlsym(handle, "CGSHWCaptureWindowList") ?? dlsym(handle, "SLSHWCaptureWindowList") else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.connection = unsafeBitCast(connection, to: Connection.self)()
        self.capture = unsafeBitCast(capture, to: Capture.self)
    }

    deinit { dlclose(handle) }

    func image(windowID: CGWindowID) -> CGImage? {
        autoreleasepool {
            var id = windowID
            guard let result = capture(connection, &id, 1, 0x0200 | 0x0800) else { return nil }
            let images = result.takeRetainedValue() as NSArray
            guard images.count > 0, CFGetTypeID(images[0] as CFTypeRef) == CGImage.typeID else { return nil }
            return (images[0] as! CGImage)
        }
    }
}

private final class PreviewPanel: NSPanel {
    var onClick: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "League of Legends preview"
        level = .normal
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = PreviewView()
        view.onClick = { [weak self] in self?.onClick?() }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspect
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PreviewView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

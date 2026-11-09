import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit

/// Capture callbacks only replace the pending frame. Metal runs independently of AppKit.
nonisolated final class MirrorRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct Frame: @unchecked Sendable {
        let sample: CMSampleBuffer
        let sourceTime: Double?
        let receivedTime: Double
    }

    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let pending = LatestFrame<Frame>()
    private let lifecycleLock = NSLock()
    private var renderRunLoop: CFRunLoop?
    private var stopped = false
    private var displayLink: CAMetalDisplayLink?
    private let refreshRate: Float
    private let metrics = MirrorMetrics()
    private let report: @Sendable (String) -> Void

    enum SetupError: Error { case unavailable }

    init(layer: CAMetalLayer, refreshRate: Float, report: @escaping @Sendable (String) -> Void) throws {
        guard let device = layer.device, let commandQueue = device.makeCommandQueue() else { throw SetupError.unavailable }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard
              let vertex = library.makeFunction(name: "mirrorVertex"),
              let fragment = library.makeFunction(name: "mirrorFragment") else { throw SetupError.unavailable }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw SetupError.unavailable }
        textureCache = cache
        self.layer = layer
        self.commandQueue = commandQueue
        self.report = report
        self.refreshRate = refreshRate
        super.init()
        let thread = Thread { self.runDisplayLink() }
        thread.name = "GameEdge video presentation"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func submit(_ sample: CMSampleBuffer) {
        guard sample.isValid, sample.imageBuffer != nil,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int,
              status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue else { return }
        let now = CACurrentMediaTime()
        let time = (info[.displayTime] as? UInt64).flatMap { ticks -> Double? in
            guard ticks > 0 else { return nil }
            return Double(ticks) * Self.secondsPerTick
        }
        metrics.received(sourceTime: time, now: now)
        _ = pending.offer(Frame(sample: sample, sourceTime: time, receivedTime: now))
    }

    func stop() {
        pending.stop()
        lifecycleLock.lock()
        guard !stopped else { lifecycleLock.unlock(); return }
        stopped = true
        let runLoop = renderRunLoop
        lifecycleLock.unlock()
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                self.displayLink?.invalidate()
                self.displayLink = nil
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runDisplayLink() {
        let runLoop = CFRunLoopGetCurrent()!
        lifecycleLock.lock()
        guard !stopped else { lifecycleLock.unlock(); return }
        renderRunLoop = runLoop
        lifecycleLock.unlock()
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: refreshRate, maximum: refreshRate, preferred: refreshRate)
        displayLink = link
        link.add(to: .current, forMode: .common)
        CFRunLoopRun()
        lifecycleLock.lock()
        renderRunLoop = nil
        lifecycleLock.unlock()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            guard let frame = pending.take() else { return }
            if !encode(frame, drawable: update.drawable) { metrics.failed() }
        }
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private func encode(_ frame: Frame, drawable: CAMetalDrawable) -> Bool {
        guard let buffer = frame.sample.imageBuffer else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm,
                                                       width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped),
              let command = commandQueue.makeCommandBuffer() else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let targetWidth = Double(drawable.texture.width), targetHeight = Double(drawable.texture.height)
        let scale = min(targetWidth / Double(width), targetHeight / Double(height))
        let shownWidth = Double(width) * scale, shownHeight = Double(height) * scale
        encoder.setViewport(MTLViewport(originX: (targetWidth - shownWidth) / 2, originY: (targetHeight - shownHeight) / 2,
                                        width: shownWidth, height: shownHeight, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let sourceTime = frame.sourceTime, receivedTime = frame.receivedTime
        drawable.addPresentedHandler { [self] presented in
            if let summary = metrics.presented(sourceTime: sourceTime, receivedTime: receivedTime,
                                                time: presented.presentedTime) {
                report(summary + "; superseded=\(pending.takeReplacementCount())")
            }
        }
        // Retain the capture sample AND its texture wrapper until the GPU has finished reading.
        // Holding only the IOSurface doesn't prevent ScreenCaptureKit from recycling its pixels.
        let retained = GPUFrame(frame: frame, texture: wrapped)
        command.addCompletedHandler { [self, retained] completed in
            withExtendedLifetime(retained) {}
            if completed.status == .error { metrics.failed() }
        }
        command.present(drawable)
        command.commit()
        return true
    }

    private struct GPUFrame: @unchecked Sendable {
        let frame: Frame
        let texture: CVMetalTexture
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct MirrorVertex { float4 position [[position]]; float2 uv; };
    vertex MirrorVertex mirrorVertex(uint id [[vertex_id]]) {
        const float2 positions[] = { {-1, -1}, {3, -1}, {-1, 3} };
        float2 p = positions[id];
        return {float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5)};
    }
    fragment float4 mirrorFragment(MirrorVertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        return float4(image.sample(sample, v.uv).rgb, 1);
    }
    """
}

/// WindowServer-to-presentation timings, not mouse-to-photon latency.
private nonisolated final class MirrorMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var since = CACurrentMediaTime()
    private var receivedCount = 0, presentedCount = 0, errors = 0, notPresented = 0
    private var capture = [Double](), presentation = [Double](), delivery = [Double]()

    func received(sourceTime: Double?, now: Double) {
        lock.lock()
        defer { lock.unlock() }
        receivedCount += 1
        if let sourceTime, now >= sourceTime, capture.count < 10_000 { capture.append((now - sourceTime) * 1_000) }
    }

    func failed() {
        lock.lock()
        defer { lock.unlock() }
        errors += 1
    }

    func presented(sourceTime: Double?, receivedTime: Double, time: Double) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if time > 0 {
            presentedCount += 1
            if let sourceTime, time >= sourceTime { presentation.append((time - sourceTime) * 1_000) }
            if time >= receivedTime { delivery.append((time - receivedTime) * 1_000) }
        } else { notPresented += 1 }
        let now = CACurrentMediaTime(), elapsed = now - since
        guard elapsed >= 5 else { return nil }
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            return String(format: "%.2f/%.2f", sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        }
        let message = String(format: "mirror Metal display link: received=%.1f fps timestamp-confirmed=%.1f fps", Double(receivedCount) / elapsed, Double(presentedCount) / elapsed)
            + "; capture p50/p95=\(summary(capture)) ms; delivery p50/p95=\(summary(delivery)) ms"
            + "; source-to-present p50/p95=\(summary(presentation)) ms; errors=\(errors) timestamp-unavailable=\(notPresented)"
        since = now
        receivedCount = 0; presentedCount = 0; errors = 0; notPresented = 0
        capture.removeAll(keepingCapacity: true); presentation.removeAll(keepingCapacity: true); delivery.removeAll(keepingCapacity: true)
        return message
    }
}

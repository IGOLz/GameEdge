import CoreVideo
import QuartzCore
import ScreenCaptureKit

/// Coalesces capture callbacks before updating the AppKit-backed layer on the main queue.
nonisolated final class MirrorRenderer: @unchecked Sendable {
    private struct Frame: @unchecked Sendable { let sample: CMSampleBuffer; let received: Double }
    private let layer: CALayer
    private let queue = DispatchQueue.main
    private let pending = LatestFrame<Frame>()
    private var retained = [CMSampleBuffer]()
    private let report: @Sendable (String) -> Void
    private var since = CACurrentMediaTime()
    private var count = 0
    private var delays = [Double]()

    init(layer: CALayer, report: @escaping @Sendable (String) -> Void) {
        self.layer = layer
        self.report = report
    }

    func submit(_ sample: CMSampleBuffer) {
        guard sample.isValid, sample.imageBuffer != nil,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int,
              status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue else { return }
        if pending.offer(Frame(sample: sample, received: CACurrentMediaTime())) {
            queue.async { self.drawNext() }
        }
    }

    func stop() {
        pending.stop()
        queue.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = nil
            CATransaction.commit()
            CATransaction.flush()
            self.retained.removeAll()
        }
    }

    private func drawNext() {
        guard let frame = pending.take() else { return }
        autoreleasepool {
                guard let buffer = frame.sample.imageBuffer,
                      let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = surface
                CATransaction.commit()
                CATransaction.flush()
                // Keep the current and preceding sample alive across the layer commit.
                // A retained IOSurface alone does not reserve a capture-pool buffer.
                retained.append(frame.sample)
                if retained.count > 2 { retained.removeFirst() }
                let now = CACurrentMediaTime()
                count += 1
                delays.append((now - frame.received) * 1000)
                if now - since >= 5 {
                    let sorted = delays.sorted()
                    report(String(format: "mirror latest frame: submitted=%.1f fps; callback-to-commit p50/p95=%.2f/%.2f ms; superseded=%d",
                                  Double(count) / (now - since), sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], pending.takeReplacementCount()))
                    since = now; count = 0; delays.removeAll(keepingCapacity: true)
                }
        }
        // Yield between commits so a busy capture producer can't starve AppKit.
        queue.async { self.drawNext() }
    }
}

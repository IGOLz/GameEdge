// Observational comparison of a game window with GameEdge's output.
// Produces sampled RGB fingerprints and WindowServer timestamps, not video.
// swiftc -O -parse-as-library Tests/MirrorLatencyProbe.swift -o build/mirror-probe
// build/mirror-probe build/latency.json [seconds] [game-bundle-id]
import AppKit
import ScreenCaptureKit

final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "probe", qos: .userInteractive)
    var rows: [[String: Any]] = []
    var source: SCStream?
    var info = mach_timebase_info_data_t()
    override init() { super.init(); mach_timebase_info(&info) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let a = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              a[.status] as? Int == SCFrameStatus.complete.rawValue,
              let stamp = a[.displayTime] as? UInt64, let b = sample.imageBuffer,
              !CVPixelBufferIsPlanar(b), CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), stride = CVPixelBufferGetBytesPerRow(b)
        var pixels = [UInt8]()
        for y in Swift.stride(from: h / 8, to: h * 7 / 8, by: 6) {
            for x in Swift.stride(from: w / 8, to: w * 7 / 8, by: 6) {
                let i = y * stride + x * 4
                pixels.append(p[i]); pixels.append(p[i+1]); pixels.append(p[i+2])
            }
        }
        rows.append(["source": stream === source, "time": Double(stamp) * Double(info.numer) / Double(info.denom) / 1e9, "pixels": pixels])
    }
}
@main struct Probe {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: mirror-probe output.json [seconds] [game-bundle-id]")
            return
        }
        let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 20 : 20
        guard seconds > 0, seconds <= 120 else { throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Duration must be 0–120 seconds"]) }
        let bundle = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "com.riotgames.LeagueofLegends.GameClient"
        _ = NSApplication.shared
        let titleBar = NSWindow.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable]).height - 100
        let share = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let game = share.windows.filter({ $0.owningApplication?.bundleIdentifier == bundle && $0.windowLayer == 0 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let mirror = share.windows.first(where: { $0.owningApplication?.bundleIdentifier == "dev.igol.GameEdge" && $0.windowLayer == Int(CGWindowLevelForKey(.popUpMenuWindow)) && $0.frame.width >= 1000 && $0.frame.height >= 600 }) else { throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing game or mirror window"]) }
        print("source", game.windowID, game.frame, "mirror", mirror.windowID, mirror.frame)
        let output = Output()
        var streams = [SCStream]()
        for (i, w) in [game, mirror].enumerated() {
            let c = SCStreamConfiguration()
            c.width = 320; c.height = 180; c.showsCursor = false
            c.pixelFormat = kCVPixelFormatType_32BGRA
            c.sourceRect = CGRect(x: 0, y: i == 0 ? titleBar : 0, width: w.frame.width, height: w.frame.height - (i == 0 ? titleBar : 0))
            c.minimumFrameInterval = .zero; c.queueDepth = 3
            c.colorSpaceName = CGColorSpace.sRGB
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: c, delegate: nil)
            if i == 0 { output.source = s }
            try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            streams.append(s)
            try await s.startCapture()
        }
        try await Task.sleep(for: .seconds(seconds))
        for s in streams { try await s.stopCapture() }
        let data = try output.queue.sync { try JSONSerialization.data(withJSONObject: output.rows) }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Saved fingerprints to", CommandLine.arguments[1])
    }
}

// swiftc -O Tests/HiddenWindowProbe.swift -o build/hidden-window-probe
// build/hidden-window-probe --self-test; omit the flag for a 20-second live probe.
import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// Draw onto initialized opaque BGRA, then hash only packed RGB components.
// This excludes source padding, skipped/alpha bytes, and provider metadata.
func normalizedRGB(_ image: CGImage) -> Data? {
    let width = 320, height = 180, stride = width * 4
    var pixels = [UInt8](repeating: 0, count: stride * height)
    return pixels.withUnsafeMutableBytes { storage -> Data? in
        guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                        CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let source = y * stride + x * 4
                    let target = (y * width + x) * 3
                    out[target] = storage[source + 2]
                    out[target + 1] = storage[source + 1]
                    out[target + 2] = storage[source]
                }
            }
        }
        return rgb
    }
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// Verify the comparison ignores source row padding and unused bytes.
if CommandLine.arguments.contains("--self-test") {
    func sample(_ padding: UInt8, _ red: UInt8) -> CGImage {
        let bytes = Data([20, 40, red, padding, 20, 40, red, padding, padding, padding, padding, padding])
        return CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    precondition(normalizedRGB(sample(0, 80)) == normalizedRGB(sample(255, 80)))
    precondition(normalizedRGB(sample(0, 80)) != normalizedRGB(sample(0, 160)))
    precondition(normalizedRGB(sample(0, 80))?.count == 320 * 180 * 3)
    print("self-test passed: padding ignored, visible RGB change detected, packed RGB size correct")
    exit(0)
}

// Read-only experiment. Private API signature/flags are based on cmdcmd's
// SkyLightCapture.swift. No input, window changes, or permission requests.
let app = NSApplication.shared
setbuf(stdout, nil)
let duration = 20.0
let interval = 0.5
let options: UInt32 = 0x0200 | 0x0800

typealias Connection = @convention(c) () -> UInt32
typealias Capture = @convention(c) (UInt32, UnsafePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
    print("unavailable: SkyLight dlopen failed")
    exit(2)
}
guard let mainSymbol = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "SLSMainConnectionID"),
      let captureSymbol = dlsym(handle, "CGSHWCaptureWindowList") ?? dlsym(handle, "SLSHWCaptureWindowList") else {
    print("unavailable: capture or connection symbol missing")
    exit(2)
}
let connection = unsafeBitCast(mainSymbol, to: Connection.self)()
let capture = unsafeBitCast(captureSymbol, to: Capture.self)
let gamePIDs = Set(NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.riotgames.LeagueofLegends.GameClient"
}.map(\.processIdentifier))
guard !gamePIDs.isEmpty else { print("unavailable: no League game process"); exit(3) }
print("ready pid=\(gamePIDs.sorted()) access=\(CGPreflightScreenCaptureAccess()) options=\(options) interval=\(interval) duration=\(duration)")
let started = ProcessInfo.processInfo.systemUptime
var previousHash: String?
var previousRGB: Data?
var changes = 0
var images = 0
var selectedID: UInt32?
var nextTick = started
let runID = String(Int(Date().timeIntervalSince1970))
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
var savedSeconds = Set<Int>()
while ProcessInfo.processInfo.systemUptime - started < duration {
    autoreleasepool {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let matching = windows.compactMap { item -> (UInt32, CGRect, Int, Bool, pid_t)? in
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, gamePIDs.contains(pid),
                  let wid = item[kCGWindowNumber as String] as? UInt32,
                  item[kCGWindowName as String] as? String == "League of Legends (TM) Client",
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.height > 500 else { return nil }
            return (wid, rect, item[kCGWindowLayer as String] as? Int ?? -1,
                    item[kCGWindowIsOnscreen as String] as? Bool ?? false, pid)
        }
        let chosen = matching.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        if let chosen { selectedID = chosen.0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let front = NSWorkspace.shared.frontmostApplication
        guard var wid = selectedID else { print(String(format: "t=%.3f no-window", elapsed)); return }
        let captureStart = ProcessInfo.processInfo.systemUptime
        guard let unmanaged = withUnsafePointer(to: &wid, { capture(connection, $0, 1, options) }) else {
            print(String(format: "t=%.3f wid=%u onscreen=%@ capture=nil", elapsed, wid, String(chosen?.3 ?? false)))
            return
        }
        let array = unmanaged.takeRetainedValue() as NSArray
        guard array.count > 0, CFGetTypeID(array[0] as CFTypeRef) == CGImage.typeID else {
            print(String(format: "t=%.3f wid=%u onscreen=%@ images=%d no-CGImage", elapsed, wid, String(chosen?.3 ?? false), array.count))
            return
        }
        let image = array[0] as! CGImage
        guard let data = normalizedRGB(image) else { print("t=\(elapsed) wid=\(wid) normalization-failed"); return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var changedPixels = 0
        var absoluteDifference: UInt64 = 0
        if let previousRGB, previousRGB.count == data.count {
            for pixel in stride(from: 0, to: data.count, by: 3) {
                var different = false
                for channel in 0..<3 {
                    let difference = abs(Int(data[pixel + channel]) - Int(previousRGB[pixel + channel]))
                    absoluteDifference += UInt64(difference)
                    different = different || difference != 0
                }
                if different { changedPixels += 1 }
            }
        }
        let changed = previousHash != nil && previousHash != hash
        if changed { changes += 1 }
        previousHash = hash
        previousRGB = data
        images += 1
        let ms = (ProcessInfo.processInfo.systemUptime - captureStart) * 1000
        let pid = chosen?.4 ?? gamePIDs.first!
        let active = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let frame = chosen.map { "\($0.1.origin.x),\($0.1.origin.y),\($0.1.width),\($0.1.height)" } ?? "unknown"
        print(String(format: "t=%.3f wid=%u pid=%d active=%@ front=%@ layer=%d onscreen=%@ frame=%@ size=%dx%d rgbBytes=%d ms=%.3f changed=%@ changes=%d changedPixels=%d meanRGBDifference=%.5f sha256=%@", elapsed, wid, pid, String(active), front?.bundleIdentifier ?? "none", chosen?.2 ?? -1, String(chosen?.3 ?? false), frame, image.width, image.height, data.count, ms, String(changed), changes, changedPixels, Double(absoluteDifference) / Double(data.count), hash))
        for second in [4, 8] where elapsed >= Double(second) && !savedSeconds.contains(second) {
            savedSeconds.insert(second)
            let url = outputDirectory.appendingPathComponent("hw-capture-\(runID)-\(second)s.png")
            print("png t=\(elapsed) success=\(writePNG(image, to: url)) path=\(url.path)")
        }
    }
    nextTick += interval
    RunLoop.main.run(until: Date().addingTimeInterval(max(0, nextTick - ProcessInfo.processInfo.systemUptime)))
}
print("finished images=\(images) changes=\(changes)")

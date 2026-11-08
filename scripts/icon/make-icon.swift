#!/usr/bin/env swift
// GameEdge icon: glassy white game controller on a lime→teal→blue squircle.
// Same macOS grid as Flusso and brain: 824 body, continuous corners r≈185, shadow in margin.
// Usage: swift scripts/icon/make-icon.swift
//   writes .github/assets/icon.png and the AppIcon / AppIconDev (DEV badge) asset catalogs.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let symbolName = "gamecontroller.fill"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((h >> 16) & 0xFF)/255, CGFloat((h >> 8) & 0xFF)/255, CGFloat(h & 0xFF)/255, a])!
}
func grad(_ s: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: s.map { $0.1 } as CFArray, locations: s.map { $0.0 })!
}
func continuousRect(_ r: CGRect, radius: CGFloat, n: CGFloat = 3.3) -> CGPath {
    let s = min(radius * 1.528, min(r.width, r.height) / 2)
    let p = CGMutablePath(); var first = true
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - s, y: r.minY + s), -.pi/2), (CGPoint(x: r.maxX - s, y: r.maxY - s), 0),
        (CGPoint(x: r.minX + s, y: r.maxY - s), .pi/2), (CGPoint(x: r.minX + s, y: r.minY + s), .pi)]
    for (c, start) in corners {
        for i in 0...96 {
            let t = start + (.pi/2) * CGFloat(i)/96, ct = cos(t), st = sin(t)
            let pt = CGPoint(x: c.x + s * copysign(pow(abs(ct), 2/n), ct), y: c.y + s * copysign(pow(abs(st), 2/n), st))
            if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
        }
    }
    p.closeSubpath(); return p
}
func bitmap(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Glyph layer (1024 space): symbol alpha filled with a white→ice gradient.
func glyphLayer(px: Int) -> (CGImage, CGRect) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
    let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let maxSide: CGFloat = 540
    let sc = maxSide / max(sym.size.width, sym.size.height)
    let w = sym.size.width * sc, h = sym.size.height * sc
    let rect = CGRect(x: 512 - w/2, y: 512 - h/2 + 6, width: w, height: h)
    let ctx = bitmap(px); let k = CGFloat(px)/1024; ctx.scaleBy(x: k, y: k)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    sym.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(grad([(0, rgb(0xFFFFFF)), (0.55, rgb(0xF4FFFB)), (1, rgb(0xDDF3FF))]),
                           start: CGPoint(x: 512, y: rect.maxY), end: CGPoint(x: 512, y: rect.minY), options: [])
    // specular sheen on the upper half
    ctx.drawLinearGradient(grad([(0, rgb(0xFFFFFF, 0.0)), (1, rgb(0xFFFFFF, 0.0))]),
                           start: .zero, end: CGPoint(x: 0, y: 1), options: [])
    return (ctx.makeImage()!, rect)
}

func render(_ px: Int, dev: Bool = false) -> CGImage {
    let ctx = bitmap(px); let k = CGFloat(px)/1024
    ctx.interpolationQuality = .high; ctx.scaleBy(x: k, y: k)
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = continuousRect(bodyRect, radius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12*k), blur: 28*k, color: rgb(0, 0.32))
    ctx.addPath(body); ctx.setFillColor(rgb(0x0B3D3A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(grad([(0, rgb(0x7BE36A)), (0.45, rgb(0x16B89A)), (1, rgb(0x1D5FE0))]),
                           start: CGPoint(x: 230, y: 924), end: CGPoint(x: 800, y: 100), options: [])
    ctx.drawRadialGradient(grad([(0, rgb(0xE8FF8A, 0.45)), (1, rgb(0xE8FF8A, 0))]),
                           startCenter: CGPoint(x: 200, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 200, y: 900), endRadius: 480, options: [])
    ctx.drawRadialGradient(grad([(0, rgb(0x4A7CFF, 0.5)), (1, rgb(0x4A7CFF, 0))]),
                           startCenter: CGPoint(x: 880, y: 140), startRadius: 0,
                           endCenter: CGPoint(x: 880, y: 140), endRadius: 500, options: [])
    ctx.drawLinearGradient(grad([(0, rgb(0xFFFFFF, 0.16)), (1, rgb(0xFFFFFF, 0))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let (glyph, _) = glyphLayer(px: px)
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // soft glow + contact shadow
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -16*k), blur: 40*k, color: rgb(0x06332E, 0.45))
    ctx.draw(glyph, in: full)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46*k, color: rgb(0xE6FFF6, 0.55))
    ctx.draw(glyph, in: full)
    ctx.restoreGState()

    // glass rim on the body
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.addPath(body); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([(0, rgb(0xFFFFFF, 0.7)), (0.35, rgb(0xFFFFFF, 0.1)), (0.8, rgb(0xFFFFFF, 0.12)), (1, rgb(0xFFFFFF, 0.35))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    if dev { drawDevBadge(ctx) }
    return ctx.makeImage()!
}


/// "DEV" capsule across the bottom of the body, for the Debug app.
func drawDevBadge(_ ctx: CGContext) {
    let badge = CGRect(x: 262, y: 128, width: 500, height: 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: rgb(0, 0.35))
    ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 75, cornerHeight: 75, transform: nil))
    ctx.setFillColor(rgb(0xFF3B30)); ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 112, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: style, .kern: 6])
    text.draw(in: CGRect(x: badge.minX, y: badge.minY + 8, width: badge.width, height: 136))
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
writePNG(render(1024), to: root.appendingPathComponent(".github/assets/icon.png"))
let catalog = root.appendingPathComponent("App/Resources/Assets.xcassets")
for (name, dev) in [("AppIcon", false), ("AppIconDev", true)] {
    let folder = catalog.appendingPathComponent("\(name).appiconset")
    var images: [String] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            writePNG(render(size * scale, dev: dev), to: folder.appendingPathComponent(file))
            images.append(#"    { "idiom" : "mac", "size" : "\#(size)x\#(size)", "scale" : "\#(scale)x", "filename" : "\#(file)" }"#)
        }
    }
    let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
    try! json.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
try! "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n".write(
    to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icons written")

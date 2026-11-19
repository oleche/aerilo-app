// Draws the app icon (1024 px) and writes every size the asset catalog needs.
// Usage: swift scripts/make-icon.swift Aerilo/Assets.xcassets/AppIcon.appiconset
import AppKit

let dir = CommandLine.arguments[1]
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    func rgb(_ h: UInt32) -> CGColor { NSColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1).cgColor }
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [rgb(0xB9DDF7), rgb(0xD9CFF8), rgb(0xF9C9DA), rgb(0xFFDCC4)] as CFArray, locations: [0, 0.4, 0.75, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.85).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.5), startRadius: 0, endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.42, options: [])
    // Ripples spreading from a soft orb, the same release the app shows after a breath.
    let c = CGPoint(x: s * 0.5, y: s * 0.5)
    ctx.setShadow(offset: .zero, blur: s * 0.02, color: rgb(0x8D8AD6).copy(alpha: 0.35))
    for (radius, alpha, width) in [(0.335, 0.38, 0.016), (0.262, 0.62, 0.021), (0.19, 0.9, 0.027)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(s * width)
        ctx.strokeEllipse(in: CGRect(x: c.x - s * radius, y: c.y - s * radius, width: s * radius * 2, height: s * radius * 2))
    }
    let orb = CGGradient(colorsSpace: space, colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.92).cgColor] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - s * 0.105, y: c.y - s * 0.105, width: s * 0.21, height: s * 0.21)); ctx.clip()
    ctx.drawRadialGradient(orb, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.105, options: [])
    ctx.restoreGState()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! draw(pt * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(dir)/Contents.json"))

// Draws wide artwork for places that want a banner: the site's social preview, the GitHub
// repository card, and promotional requests from Apple.
// Usage: swift scripts/make-header.swift marketing
import AppKit
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])! }

func header(_ w: Int, _ h: Int, _ name: String) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    // The app's sky: four soft colours meeting in the middle.
    ctx.setFillColor(rgb(0xFBEEF0)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (x, y, colour) in [(0.1, 0.85, 0xF9C9DA), (0.9, 0.9, 0xFFDCC4), (0.12, 0.1, 0xB9DDF7), (0.9, 0.1, 0xD9CFF8), (0.55, 0.3, 0xC9EFE6)] as [(CGFloat, CGFloat, UInt32)] {
        let g = CGGradient(colorsSpace: space, colors: [rgb(colour), rgb(colour, 0)] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: W * x, y: H * y)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(W, H) * 0.55, options: [])
    }
    // Ripples and the orb, on the left third.
    let s = H * 0.62
    let c = CGPoint(x: W * 0.26, y: H * 0.5)
    for (radius, alpha, width) in [(0.62, 0.3, 0.012), (0.49, 0.5, 0.016), (0.37, 0.75, 0.02)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(0xFFFFFF, alpha)); ctx.setLineWidth(s * width)
        ctx.strokeEllipse(in: CGRect(x: c.x - s * radius, y: c.y - s * radius, width: s * radius * 2, height: s * radius * 2))
    }
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: rgb(0x8D8AD6, 0.3))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: c.x - s * 0.24, y: c.y - s * 0.24, width: s * 0.48, height: s * 0.48))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Name and line.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    let ink = NSColor(srgbRed: 0.12, green: 0.11, blue: 0.14, alpha: 1)
    ("Aerilo" as NSString).draw(at: CGPoint(x: W * 0.46, y: H * 0.47), withAttributes: [.font: font(H * 0.2, .semibold), .foregroundColor: ink])
    ("Let your Mac and your photos breathe." as NSString).draw(at: CGPoint(x: W * 0.463, y: H * 0.37), withAttributes: [.font: font(min(H * 0.05, W * 0.026), .regular), .foregroundColor: ink.withAlphaComponent(0.7)])
    NSGraphicsContext.current = nil
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
header(1920, 1080, "header-1920x1080.png")   // general banner, Apple promotional requests
header(4320, 1080, "header-4320x1080.png")   // ultra-wide (Apple TV style)
header(1280, 640, "social-1280x640.png")     // GitHub repository card and link previews
print("wrote headers to \(dir)")

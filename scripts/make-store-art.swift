// Turns the first three screenshots of a device into one piece of artwork for App Store search,
// where they are shown side by side: ripples and drifting motes run across all three, as if the
// breath in the first picture carried through the others. Nothing is framed; it is drawn over the
// app's own sky.
// Usage: swift scripts/make-store-art.swift <folder> <prefix>      e.g. fastlane/screenshots-ios/en-US iphone
import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = CommandLine.arguments[1], prefix = CommandLine.arguments[2]
let files = (try! FileManager.default.contentsOfDirectory(atPath: folder)).filter { $0.hasPrefix(prefix + "-") && $0.hasSuffix(".png") }.sorted().prefix(3)
guard files.count == 3 else { print("need three screenshots named \(prefix)-1…, -2…, -3…"); exit(1) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func unit(_ i: Int, _ salt: Int) -> CGFloat {
    var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
    x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB; x ^= x >> 31
    return CGFloat(x % 10_000) / 10_000
}

for (index, name) in files.enumerated() {
    let url = URL(fileURLWithPath: "\(folder)/\(name)")
    guard let source = NSBitmapImageRep(data: try! Data(contentsOf: url))?.cgImage else { continue }
    let w = source.width, h = source.height
    let W = CGFloat(w), H = CGFloat(h)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: W, height: H))
    // One centre for all three pictures: the orb of the first one. Later pictures only see the outer rings.
    let centre = CGPoint(x: W * 0.5 - CGFloat(index) * W, y: H * 0.545)
    ctx.setBlendMode(.softLight)
    for ring in 0..<14 {
        let radius = W * (0.62 + CGFloat(ring) * 0.21)
        let fade = max(0, 1 - CGFloat(ring) / 14)
        ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.55 * fade + 0.12])!)
        ctx.setLineWidth(W * (0.004 + 0.004 * fade))
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }
    ctx.setBlendMode(.normal)
    // Motes carried along the rings, thinning out to the right.
    for i in 0..<260 {
        let angle = unit(i, 1) * 2 * .pi
        let radius = W * (0.55 + unit(i, 2) * 2.6)
        let p = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius * 0.92)
        guard p.x > -20, p.x < W + 20, p.y > 0, p.y < H else { continue }
        let size = W * (0.0025 + unit(i, 3) * 0.006)
        let alpha = (0.25 + unit(i, 4) * 0.5) * max(0.25, 1 - radius / (W * 3.4))
        ctx.setShadow(offset: .zero, blur: size * 1.5, color: CGColor(colorSpace: space, components: [1, 1, 1, alpha])!)
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, alpha])!)
        ctx.fillEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
// A side-by-side preview of how the set reads in search results.
let reps = files.compactMap { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "\(folder)/\($0)")))?.cgImage }
let scale: CGFloat = 0.3, gap: CGFloat = 24
let tw = Int(CGFloat(reps[0].width) * scale), th = Int(CGFloat(reps[0].height) * scale)
let preview = CGContext(data: nil, width: tw * 3 + Int(gap) * 4, height: th + Int(gap) * 2, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
preview.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
preview.fill(CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
for (i, image) in reps.enumerated() {
    let rect = CGRect(x: gap + CGFloat(i) * (CGFloat(tw) + gap), y: gap, width: CGFloat(tw), height: CGFloat(th))
    preview.saveGState()
    preview.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)); preview.clip()
    preview.draw(image, in: rect)
    preview.restoreGState()
}
try! FileManager.default.createDirectory(atPath: "marketing", withIntermediateDirectories: true)
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "marketing/search-preview-\(prefix).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(out, preview.makeImage()!, nil)
CGImageDestinationFinalize(out)
print("styled \(files.joined(separator: ", ")); preview at marketing/search-preview-\(prefix).png")

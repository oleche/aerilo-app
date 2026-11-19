// Draws the photo library the simulator tests use. Usage: swift scripts/make-test-media.swift <folder>
import AppKit
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let stamp = DateFormatter()
stamp.dateFormat = "yyyy:MM:dd HH:mm:ss"

/// A drawn landscape. `scene` changes everything; `nudge` moves the sun a few pixels, like a second shot.
func picture(scene: Int, nudge: CGFloat, w: Int = 1600, h: Int = 1200, screenshot: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    let hue = CGFloat((scene * 37) % 100) / 100
    if screenshot {
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for row in 0..<12 {
            ctx.setFillColor(NSColor(white: row % 2 == 0 ? 0.85 : 0.75, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 60, y: H - 220 - CGFloat(row) * 180, width: W - 120 - CGFloat(row % 3) * 200, height: 60))
        }
        return ctx.makeImage()!
    }
    let sky = CGGradient(colorsSpace: space, colors: [NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1).cgColor,
                                                       NSColor(hue: hue + 0.1 > 1 ? hue - 0.9 : hue + 0.1, saturation: 0.3, brightness: 1, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: .zero, options: [])
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: W * (0.2 + CGFloat(scene % 5) * 0.12) + nudge, y: H * 0.62, width: 180, height: 180))
    for layer in 0..<4 {
        ctx.setFillColor(NSColor(hue: (hue + 0.4 + CGFloat(layer) * 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.8 - CGFloat(layer) * 0.15, alpha: 1).cgColor)
        ctx.move(to: CGPoint(x: 0, y: 0))
        for step in 0...16 {
            let x = W * CGFloat(step) / 16
            ctx.addLine(to: CGPoint(x: x, y: H * (0.5 - CGFloat(layer) * 0.11) + sin(CGFloat(step) * (0.6 + CGFloat(scene) * 0.21) + CGFloat(layer * scene)) * 70))
        }
        ctx.addLine(to: CGPoint(x: W, y: 0)); ctx.closePath(); ctx.fillPath()
    }
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String, taken: Date, type: UTType = .jpeg, comment: String? = nil) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL, type.identifier as CFString, 1, nil)!
    var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: stamp.string(from: taken), kCGImagePropertyExifDateTimeDigitized: stamp.string(from: taken)]
    if let comment { exif[kCGImagePropertyExifUserComment] = comment }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: exif, kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let day: TimeInterval = 86_400
let base = Date().addingTimeInterval(-10 * day)
// One picture that will be added twice: identical bytes, identical capture time.
save(picture(scene: 1, nudge: 0), "duplicate.jpg", taken: base)
// Three shots a second apart, the sun a few pixels over each time.
for i in 0..<3 { save(picture(scene: 2, nudge: CGFloat(i) * 6), "burst-\(i).jpg", taken: base.addingTimeInterval(3600 + Double(i))) }
// Three unrelated pictures, minutes apart: these must not be suggested.
for i in 0..<3 { save(picture(scene: 5 + i * 3, nudge: 0), "single-\(i).jpg", taken: base.addingTimeInterval(7200 + Double(i) * 600)) }
// One picture named the way WhatsApp names what it saves.
save(picture(scene: 21, nudge: 0), "IMG-20260101-WA0007.jpg", taken: base.addingTimeInterval(20_000))
// Five tall pictures under WhatsApp names: a tall picture once spilled out of its square and covered its neighbours.
for i in 0..<5 { save(picture(scene: 30 + i * 4, nudge: 0, w: 1170, h: 2532), "IMG-20260102-WA001\(i).jpg", taken: base.addingTimeInterval(30_000 + Double(i) * 900)) }
// A screenshot from 60 days ago, marked the way iOS marks its own.
save(picture(scene: 0, nudge: 0, w: 1320, h: 2868, screenshot: true), "screenshot.png", taken: Date().addingTimeInterval(-60 * day), type: .png, comment: "Screenshot")
print("wrote test pictures to \(dir)")

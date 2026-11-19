// Draws the full-bleed 1024 px icon for iPhone, iPad and Vision Pro (the system rounds the corners).
// Usage: swift scripts/make-icon-ios.swift AeriloMobile/Assets.xcassets/AppIcon.appiconset
import AppKit
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
let px = 1024
let s = CGFloat(px)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])! }
let base = CGGradient(colorsSpace: space, colors: [rgb(0xB9DDF7), rgb(0xD9CFF8), rgb(0xF9C9DA), rgb(0xFFDCC4)] as CFArray, locations: [0, 0.4, 0.75, 1])!
ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: s, y: s), options: [])
let c = CGPoint(x: s / 2, y: s / 2)
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.85), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.5, options: [])
ctx.setShadow(offset: .zero, blur: s * 0.02, color: rgb(0x8D8AD6, 0.35))
for (radius, alpha, width) in [(0.40, 0.38, 0.019), (0.31, 0.62, 0.025), (0.225, 0.9, 0.032)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setStrokeColor(rgb(0xFFFFFF, alpha))
    ctx.setLineWidth(s * width)
    ctx.strokeEllipse(in: CGRect(x: c.x - s * radius, y: c.y - s * radius, width: s * radius * 2, height: s * radius * 2))
}
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: c.x - s * 0.125, y: c.y - s * 0.125, width: s * 0.25, height: s * 0.25))
let url = URL(fileURLWithPath: "\(dir)/icon-1024.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
let json = #"{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)

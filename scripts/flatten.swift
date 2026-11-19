// Rewrites a PNG with no alpha channel, filling see-through pixels (a window's rounded corners)
// with the colour found just inside each corner. The App Store refuses screenshots with alpha.
// Usage: swift scripts/flatten.swift file.png
import AppKit
import ImageIO
import UniformTypeIdentifiers

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: url), let source = NSBitmapImageRep(data: data), let image = source.cgImage else {
    print("flatten: cannot read \(url.path)")
    exit(1)
}
let w = source.pixelsWide, h = source.pixelsHigh
guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    print("flatten: cannot create a drawing surface")
    exit(1)
}
let inset = 70
// colorAt counts rows from the top; Core Graphics draws from the bottom.
func fill(sampleX: Int, sampleY: Int, rect: CGRect) {
    let colour = (source.colorAt(x: sampleX, y: sampleY) ?? NSColor.white).usingColorSpace(.sRGB) ?? NSColor.white
    context.setFillColor(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent, alpha: 1)
    context.fill(rect)
}
let halfW = CGFloat(w) / 2, halfH = CGFloat(h) / 2
fill(sampleX: inset, sampleY: inset, rect: CGRect(x: 0, y: halfH, width: halfW, height: halfH))
fill(sampleX: w - inset, sampleY: inset, rect: CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
fill(sampleX: inset, sampleY: h - inset, rect: CGRect(x: 0, y: 0, width: halfW, height: halfH))
fill(sampleX: w - inset, sampleY: h - inset, rect: CGRect(x: halfW, y: 0, width: halfW, height: halfH))
context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

guard let flat = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    print("flatten: cannot write \(url.path)")
    exit(1)
}
CGImageDestinationAddImage(destination, flat, nil)
if !CGImageDestinationFinalize(destination) { exit(1) }

// Draws the layered icons Apple TV and Vision Pro require (a background and a foreground that move
// apart), plus the Apple TV top-shelf images. Usage:
//   swift scripts/make-icon-layers.swift AeriloMobile/Assets.xcassets
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = CommandLine.arguments[1]
let fm = FileManager.default
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])! }
let info = #""info":{"author":"xcode","version":1}"#

enum Layer { case back, front, both }

func draw(_ w: Int, _ h: Int, _ layer: Layer, to path: String) {
    let opaque = layer != .front
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    let W = CGFloat(w), H = CGFloat(h), s = min(W, H)
    let c = CGPoint(x: W / 2, y: H / 2)
    if layer != .front {
        let base = CGGradient(colorsSpace: space, colors: [rgb(0xB9DDF7), rgb(0xD9CFF8), rgb(0xF9C9DA), rgb(0xFFDCC4)] as CFArray, locations: [0, 0.4, 0.75, 1])!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: W, y: H), options: [])
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.8), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.55, options: [])
    }
    if layer != .back {
        ctx.setShadow(offset: .zero, blur: s * 0.02, color: rgb(0x8D8AD6, 0.35))
        for (radius, alpha, width) in [(0.40, 0.38, 0.019), (0.31, 0.62, 0.025), (0.225, 0.9, 0.032)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.setStrokeColor(rgb(0xFFFFFF, alpha))
            ctx.setLineWidth(s * width)
            ctx.strokeEllipse(in: CGRect(x: c.x - s * radius, y: c.y - s * radius, width: s * radius * 2, height: s * radius * 2))
        }
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: c.x - s * 0.125, y: c.y - s * 0.125, width: s * 0.25, height: s * 0.25))
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func write(_ json: String, _ path: String) { try! json.write(toFile: path, atomically: true, encoding: .utf8) }
func dir(_ path: String) { try! fm.createDirectory(atPath: path, withIntermediateDirectories: true) }

/// One layer folder holding an image set at the given scales.
func layerFolder(_ path: String, idiom: String, w: Int, h: Int, layer: Layer, scales: [Int]) {
    dir("\(path)/Content.imageset")
    write("{\(info)}", "\(path)/Contents.json")
    var images: [String] = []
    for scale in scales {
        let name = "layer\(scale == 1 ? "" : "@\(scale)x").png"
        draw(w * scale, h * scale, layer, to: "\(path)/Content.imageset/\(name)")
        images.append(#"{"filename":"\#(name)","idiom":"\#(idiom)","scale":"\#(scale)x"}"#)
    }
    write(#"{"images":[\#(images.joined(separator: ","))],\#(info)}"#, "\(path)/Content.imageset/Contents.json")
}

// Apple TV: brand assets with two icon stacks and two top-shelf images.
let brand = "\(root)/App Icon & Top Shelf Image.brandassets"
dir(brand)
write(#"""
{"assets":[
{"filename":"App Icon - App Store.imagestack","idiom":"tv","role":"primary-app-icon","size":"1280x768"},
{"filename":"App Icon.imagestack","idiom":"tv","role":"primary-app-icon","size":"400x240"},
{"filename":"Top Shelf Image Wide.imageset","idiom":"tv","role":"top-shelf-image-wide","size":"2320x720"},
{"filename":"Top Shelf Image.imageset","idiom":"tv","role":"top-shelf-image","size":"1920x720"}],\#(info)}
"""#, "\(brand)/Contents.json")
for (stack, w, h, scales) in [("App Icon - App Store", 1280, 768, [1]), ("App Icon", 400, 240, [1, 2])] {
    let path = "\(brand)/\(stack).imagestack"
    dir(path)
    write(#"{"layers":[{"filename":"Front.imagestacklayer"},{"filename":"Back.imagestacklayer"}],\#(info)}"#, "\(path)/Contents.json")
    layerFolder("\(path)/Front.imagestacklayer", idiom: "tv", w: w, h: h, layer: .front, scales: scales)
    layerFolder("\(path)/Back.imagestacklayer", idiom: "tv", w: w, h: h, layer: .back, scales: scales)
}
for (name, w, h) in [("Top Shelf Image Wide", 2320, 720), ("Top Shelf Image", 1920, 720)] {
    let path = "\(brand)/\(name).imageset"
    dir(path)
    draw(w, h, .both, to: "\(path)/shelf.png")
    draw(w * 2, h * 2, .both, to: "\(path)/shelf@2x.png")
    write(#"{"images":[{"filename":"shelf.png","idiom":"tv","scale":"1x"},{"filename":"shelf@2x.png","idiom":"tv","scale":"2x"}],\#(info)}"#, "\(path)/Contents.json")
}

// Vision Pro: three square layers.
let vision = "\(root)/AppIconVision.solidimagestack"
dir(vision)
write(#"{"layers":[{"filename":"Front.solidimagestacklayer"},{"filename":"Middle.solidimagestacklayer"},{"filename":"Back.solidimagestacklayer"}],\#(info)}"#, "\(vision)/Contents.json")
for (name, layer) in [("Front", Layer.front), ("Middle", Layer.front), ("Back", Layer.back)] {
    let path = "\(vision)/\(name).solidimagestacklayer"
    dir("\(path)/Content.imageset")
    write("{\(info)}", "\(path)/Contents.json")
    if name == "Middle" {
        // An empty middle layer: the icon has two planes, and the format needs three.
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(path)/Content.imageset/layer.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    } else {
        draw(1024, 1024, layer, to: "\(path)/Content.imageset/layer.png")
    }
    write(#"{"images":[{"filename":"layer.png","idiom":"vision","scale":"2x"}],\#(info)}"#, "\(path)/Content.imageset/Contents.json")
}
print("wrote Apple TV and Vision Pro icons")

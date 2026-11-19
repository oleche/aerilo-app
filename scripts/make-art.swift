// Draws Aerilo's App Store artwork.
//
//   swift scripts/make-art.swift shots    every raw screenshot in artwork/raw/<set>/ becomes a finished
//                                         picture in its fastlane folder: headline, description, and the
//                                         screen floating on the app's own sky, with no frame around it
//   swift scripts/make-art.swift header   banners and the social card in marketing/
//   swift scripts/make-art.swift duo      drawn artwork for the iPhone Duo's two screens in marketing/duo/
//   swift scripts/make-art.swift all
//
// Raw screenshots come from scripts/screenshots.sh, screenshots-ios.sh and screenshots-devices.sh.
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space])
let fm = FileManager.default

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
func white(_ a: CGFloat) -> CGColor { rgb(0xFFFFFF, a) }
func canvas(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}
func save(_ ctx: CGContext, _ path: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
func load(_ path: String) -> CGImage? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return NSBitmapImageRep(data: data)?.cgImage
}
func unit(_ i: Int, _ salt: Int) -> CGFloat {
    var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
    x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB; x ^= x >> 31
    return CGFloat(x % 10_000) / 10_000
}
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

// MARK: - Pieces

/// The app's sky, drawn from scratch: soft colour fields that meet in the middle.
func sky(_ ctx: CGContext, _ W: CGFloat, _ H: CGFloat, dark: Bool = false) {
    ctx.setFillColor(dark ? rgb(0x1A1B3D) : rgb(0xFBEEF0))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let fields: [(CGFloat, CGFloat, UInt32)] = dark
        ? [(0.05, 0.95, 0x2B2550), (0.95, 0.9, 0x5A2B4F), (0.1, 0.1, 0x14324A), (0.9, 0.08, 0x3B2152), (0.5, 0.2, 0x16404F)]
        : [(0.05, 0.95, 0xF9C9DA), (0.95, 0.92, 0xFFDCC4), (0.08, 0.08, 0xB9DDF7), (0.92, 0.06, 0xD9CFF8), (0.5, 0.18, 0xC9EFE6), (0.55, 0.62, 0xFFF1E3)]
    for (x, y, colour) in fields {
        let g = CGGradient(colorsSpace: space, colors: [rgb(colour), rgb(colour, 0)] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: W * x, y: H * y)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(W, H) * 0.62, options: [])
    }
}

/// Rings spreading from a point, strongest near it, with motes carried along them.
func ripples(_ ctx: CGContext, centre: CGPoint, first: CGFloat, step: CGFloat, count: Int, width: CGFloat, strength: CGFloat = 1, motes: Int = 0, seed: Int = 0) {
    ctx.saveGState()
    for ring in 0..<count {
        let radius = first + CGFloat(ring) * step
        let fade = pow(1 - CGFloat(ring) / CGFloat(count), 1.4)
        ctx.setStrokeColor(white((0.75 * fade + 0.08) * strength))
        ctx.setLineWidth(width * (0.5 + fade))
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }
    let reach = first + CGFloat(count) * step
    for i in 0..<motes {
        let angle = unit(i + seed, 1) * 2 * .pi
        let radius = first * 0.9 + unit(i + seed, 2) * (reach - first)
        let p = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        let size = width * (0.6 + unit(i + seed, 3) * 1.8)
        let alpha = (0.35 + unit(i + seed, 4) * 0.6) * max(0.15, 1 - (radius - first) / (reach - first)) * strength
        ctx.setShadow(offset: .zero, blur: size * 2, color: white(alpha))
        ctx.setFillColor(white(alpha))
        ctx.fillEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
    }
    ctx.restoreGState()
}

/// The glass orb: a soft glow, a body that is lighter at the top, a bright rim and a highlight.
func orb(_ ctx: CGContext, centre: CGPoint, radius r: CGFloat, label: String? = nil, sublabel: String? = nil, dark: Bool = false) {
    ctx.saveGState()
    let glow = CGGradient(colorsSpace: space, colors: [white(dark ? 0.35 : 0.95), white(0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: centre, startRadius: r * 0.6, endCenter: centre, endRadius: r * 1.75, options: [])
    let body = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
    ctx.setShadow(offset: CGSize(width: 0, height: -r * 0.08), blur: r * 0.28, color: rgb(dark ? 0x000000 : 0x7C6FB5, dark ? 0.5 : 0.28))
    ctx.setFillColor(dark ? rgb(0x4A4370) : rgb(0xFFFFFF))
    ctx.fillEllipse(in: body)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addEllipse(in: body); ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: dark ? [rgb(0x6A618F), rgb(0x3C365F)] as CFArray : [rgb(0xFFFFFF), rgb(0xF4ECFB), rgb(0xFBE9F1)] as CFArray,
                          locations: dark ? [0, 1] : [0, 0.6, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: centre.x - r * 0.4, y: centre.y + r), end: CGPoint(x: centre.x + r * 0.4, y: centre.y - r), options: [])
    let shine = CGGradient(colorsSpace: space, colors: [white(dark ? 0.28 : 0.95), white(0)] as CFArray, locations: [0, 1])!
    let s = CGPoint(x: centre.x - r * 0.3, y: centre.y + r * 0.45)
    ctx.drawRadialGradient(shine, startCenter: s, startRadius: 0, endCenter: s, endRadius: r * 0.8, options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(white(dark ? 0.35 : 0.9)); ctx.setLineWidth(max(2, r * 0.012)); ctx.strokeEllipse(in: body.insetBy(dx: r * 0.006, dy: r * 0.006))
    if let label {
        text(ctx, label, centre: CGPoint(x: centre.x, y: centre.y + r * (sublabel == nil ? 0 : 0.1)), width: r * 1.7, font: rounded(r * 0.33, .light), colour: dark ? .white : NSColor(srgbRed: 0.12, green: 0.11, blue: 0.14, alpha: 1))
    }
    if let sublabel {
        text(ctx, sublabel, centre: CGPoint(x: centre.x, y: centre.y - r * 0.2), width: r * 1.6, font: rounded(r * 0.115, .medium), colour: (dark ? NSColor.white : NSColor(srgbRed: 0.12, green: 0.11, blue: 0.14, alpha: 1)).withAlphaComponent(0.55))
    }
}

/// Centred text, wrapped to `width`, positioned by the centre of its block. Returns the block's height.
@discardableResult
func text(_ ctx: CGContext, _ string: String, centre: CGPoint, width: CGFloat, font: NSFont, colour: NSColor, align: NSTextAlignment = .center, tracking: CGFloat = 0) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byWordWrapping
    style.lineHeightMultiple = 0.98
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style, .kern: tracking])
    let box = attributed.boundingRect(with: CGSize(width: width, height: 1e5), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attributed.draw(with: CGRect(x: centre.x - width / 2, y: centre.y - box.height / 2, width: width, height: box.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    return box.height
}

/// A frosted panel with rows, for drawn (not photographed) interface.
func panel(_ ctx: CGContext, _ rect: CGRect, rows: [(String, String, String?)], dark: Bool = false) {
    let radius = rect.width * 0.07
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.02), blur: rect.width * 0.06, color: rgb(0x6A5FA8, 0.18))
    ctx.addPath(path); ctx.setFillColor(white(dark ? 0.12 : 0.62)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(white(dark ? 0.25 : 0.9)); ctx.setLineWidth(max(2, rect.width * 0.003)); ctx.strokePath()
    let ink = dark ? NSColor.white : NSColor(srgbRed: 0.12, green: 0.11, blue: 0.14, alpha: 1)
    let rowH = rect.height / CGFloat(rows.count)
    for (i, row) in rows.enumerated() {
        let y = rect.maxY - rowH * (CGFloat(i) + 0.5)
        if i > 0 {
            ctx.setStrokeColor(ink.withAlphaComponent(0.1).cgColor); ctx.setLineWidth(max(1, rect.width * 0.0018))
            ctx.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.maxY - rowH * CGFloat(i))); ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.maxY - rowH * CGFloat(i))); ctx.strokePath()
        }
        // Sizes follow the panel's width as well as the row height, so a narrow panel never overlaps.
        let unit = min(rowH, rect.width * 0.2)
        let left = rect.minX + rect.width * 0.07, w = rect.width * 0.58
        text(ctx, row.0, centre: CGPoint(x: left + w / 2, y: y + unit * 0.15), width: w, font: rounded(unit * 0.21, .semibold), colour: ink, align: .left)
        text(ctx, row.1, centre: CGPoint(x: left + w / 2, y: y - unit * 0.15), width: w, font: rounded(unit * 0.165, .regular), colour: ink.withAlphaComponent(0.55), align: .left)
        if let badge = row.2 {
            let font = rounded(unit * 0.14, .semibold)
            let size = (badge as NSString).size(withAttributes: [.font: font])
            let pill = CGRect(x: rect.maxX - rect.width * 0.07 - size.width - rowH * 0.24, y: y - rowH * 0.17, width: size.width + rowH * 0.24, height: rowH * 0.34)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.setFillColor(rgb(0x3B82F6, 0.16)); ctx.fillPath()
            text(ctx, badge, centre: CGPoint(x: pill.midX, y: pill.midY), width: pill.width, font: font, colour: NSColor(srgbRed: 0.15, green: 0.42, blue: 0.9, alpha: 1))
        }
    }
}

// MARK: - Finished screenshots

struct Caption { let headline: String; let detail: String }

let deviceCaptions: [String: Caption] = [
    "exhale": Caption(headline: "One tap tidies your photos", detail: "Aerilo looks through your library and gathers what you no longer need."),
    "result": Caption(headline: "See what could go", detail: "Duplicates, similar shots, old screenshots and large videos, counted and sized."),
    "similar": Caption(headline: "Keep the best, drop the rest", detail: "Aerilo suggests which shot to keep. You tick, you decide."),
    "videos": Caption(headline: "Find your largest videos", detail: "The biggest space savers. None are ever ticked for you."),
    "device": Caption(headline: "Know your device", detail: "Storage, memory, processor load, temperature and battery at a glance."),
    "log": Caption(headline: "Nothing happens in secret", detail: "Every look and every deletion goes into a log you can share."),
]
let macCaptions: [String: Caption] = [
    "breathe": Caption(headline: "One tap. Your Mac breathes.", detail: "Aerilo clears what your Mac no longer needs and tells you what is slowing it down."),
    "result": Caption(headline: "It thinks before it acts", detail: "On-device Apple Intelligence picks what helps most. Nothing leaves your Mac."),
    "activity": Caption(headline: "See what weighs on your Mac", detail: "Stuck apps and growing memory, with helpers counted under their app."),
    "network": Caption(headline: "Know what uses your connection", detail: "Live download and upload for every app."),
    "storage": Caption(headline: "Space back, safely", detail: "Measured first, and cleared only if it rebuilds itself."),
    "photos": Caption(headline: "Tidy your photos too", detail: "Duplicates, similar shots and large videos, reviewed before anything goes."),
    "log": Caption(headline: "Nothing happens in secret", detail: "A record of everything Aerilo did, ready to share or audit."),
    "dark": Caption(headline: "Calm in the dark, too", detail: "Aerilo follows your Mac's light or dark appearance."),
]

/// One finished picture: the sky continued from the screenshot itself, ripples from the top, a
/// headline and a line of detail, and below them the screen with its edges dissolving into the sky.
func finish(_ sourcePath: String, _ caption: Caption, to outPath: String, cropTop: CGFloat, screenScale: CGFloat) {
    guard let source = load(sourcePath) else { return }
    let w = source.width, h = source.height
    let W = CGFloat(w), H = CGFloat(h)
    let portrait = H > W
    let ctx = canvas(w, h)

    // 1. Sky: the screenshot itself, blurred until only its colours are left. The top bar is cut
    //    off first, or the clock and icons would leave a dark smudge.
    let lower = source.cropping(to: CGRect(x: 0, y: CGFloat(Int(H * max(cropTop, 0.07))), width: W, height: H * (1 - max(cropTop, 0.07))))!
    let stretched = CIImage(cgImage: lower).transformed(by: CGAffineTransform(scaleX: 1, y: H / CGFloat(lower.height)))
    let input = stretched.clampedToExtent()
    let blurred = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(W, H) * 0.11]).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    if let bg = ci.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: W, height: H)) { ctx.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H)) }

    // Is this a dark picture? Decide the ink from the middle of the top band.
    var probe = [UInt8](repeating: 0, count: 4)
    let one = CGContext(data: &probe, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    one.draw(ctx.makeImage()!, in: CGRect(x: -W * 0.5, y: -H * 0.9, width: W, height: H))
    let dark = (Int(probe[0]) + Int(probe[1]) + Int(probe[2])) / 3 < 110
    let ink = dark ? NSColor.white : NSColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 1)

    // 2. Ripples from above the picture, so the text sits inside the first rings.
    let base = min(W, H)
    ripples(ctx, centre: CGPoint(x: W / 2, y: H * (portrait ? 1.06 : 1.25)), first: base * (portrait ? 0.30 : 0.42), step: base * 0.115, count: 9,
            width: base * 0.0042, strength: dark ? 0.45 : 0.9, motes: 70, seed: caption.headline.count)

    // 3. Words.
    let headSize = portrait ? W * 0.092 : H * 0.082
    let textWidth = W * (portrait ? 0.86 : 0.8)
    let headY = H * (portrait ? 0.893 : 0.885)
    let headH = text(ctx, caption.headline, centre: CGPoint(x: W / 2, y: headY), width: textWidth, font: rounded(headSize, .bold), colour: ink, tracking: -headSize * 0.012)
    let detailSize = headSize * 0.42
    let detailH = text(ctx, caption.detail, centre: CGPoint(x: W / 2, y: headY - headH / 2 - detailSize * 1.35), width: textWidth * 0.94, font: rounded(detailSize, .regular), colour: ink.withAlphaComponent(0.62))
    let textBottom = headY - headH / 2 - detailSize * 1.35 - detailH / 2

    // 4. The screen, without its own top bar, its edges feathered so there is no frame.
    let cropped = source.cropping(to: CGRect(x: 0, y: CGFloat(Int(H * cropTop)), width: W, height: H * (1 - cropTop)))!
    let sw = W * screenScale, sh = CGFloat(cropped.height) * screenScale
    let top = textBottom - detailSize * (portrait ? 1.3 : 1.1)
    let rect = CGRect(x: (W - sw) / 2, y: top - sh, width: sw, height: sh)
    let feather = base * 0.045
    let solid = CIImage(color: .white).cropped(to: rect.insetBy(dx: feather, dy: 0).offsetBy(dx: 0, dy: -feather * 1.2))
    let maskImage = solid.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H)))
        .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather * 0.55]).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    let gray = CGColorSpaceCreateDeviceGray()
    if let mask = ci.createCGImage(maskImage, from: CGRect(x: 0, y: 0, width: W, height: H), format: .L8, colorSpace: gray) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H), mask: mask)
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: rect)
        ctx.restoreGState()
    }
    save(ctx, outPath)
}

/// Vision Pro pictures show the app window in a room. The room stays as it is; the words go on
/// a soft veil of light across the ceiling.
func finishInRoom(_ sourcePath: String, _ caption: Caption, to outPath: String) {
    guard let source = load(sourcePath) else { return }
    let W = CGFloat(source.width), H = CGFloat(source.height)
    let ctx = canvas(source.width, source.height)
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: W, height: H))
    let veil = CGGradient(colorsSpace: space, colors: [white(0.82), white(0.55), white(0)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(veil, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.66), options: [])
    let ink = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 1)
    let size = H * 0.078
    let hh = text(ctx, caption.headline, centre: CGPoint(x: W / 2, y: H * 0.875), width: W * 0.8, font: rounded(size, .bold), colour: ink, tracking: -size * 0.012)
    text(ctx, caption.detail, centre: CGPoint(x: W / 2, y: H * 0.875 - hh / 2 - size * 0.6), width: W * 0.76, font: rounded(size * 0.42, .regular), colour: ink.withAlphaComponent(0.66))
    save(ctx, outPath)
}

func shots() {
    // (raw folder, finished folder, captions, crop from the top, scale of the screen)
    let sets: [(String, String, [String: Caption], CGFloat, CGFloat)] = [
        ("artwork/raw/mac-store", "fastlane/screenshots/en-US", macCaptions, 0.062, 0.80),
        ("artwork/raw/mac", "marketing/screenshots", macCaptions, 0.062, 0.80),
        ("artwork/raw/ios", "fastlane/screenshots-ios/en-US", deviceCaptions, 0.058, 0.90),
        ("artwork/raw/tvos", "fastlane/screenshots-tvos/en-US", deviceCaptions, 0.12, 0.82),
        ("artwork/raw/visionos", "fastlane/screenshots-visionos/en-US", deviceCaptions, 0.0, 0.84),
    ]
    for (raw, out, captions, crop, scale) in sets {
        let files = ((try? fm.contentsOfDirectory(atPath: raw)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        guard !files.isEmpty else { print("no raw screenshots in \(raw); run the screenshot script first"); continue }
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: out)) ?? [] where old.hasSuffix(".png") { try? fm.removeItem(atPath: "\(out)/\(old)") }
        for file in files {
            // The last word of the file name says which screen it is: "iphone-2-result.png" -> "result".
            let key = String(file.dropLast(4).split(separator: "-").last ?? "")
            guard let caption = captions[key] else { print("no caption for \(file)"); continue }
            // iPad shows more around the content, so its screen can sit a little smaller.
            if raw.hasSuffix("visionos") { finishInRoom("\(raw)/\(file)", caption, to: "\(out)/\(file)"); continue }
            let s = file.hasPrefix("ipad") ? scale * 0.94 : scale
            finish("\(raw)/\(file)", caption, to: "\(out)/\(file)", cropTop: file.hasPrefix("ipad") ? 0.03 : crop, screenScale: s)
        }
        print("finished \(files.count) pictures in \(out)")
    }
    // How the first three look side by side, as App Store search shows them.
    for prefix in ["iphone", "ipad"] {
        let dir = "fastlane/screenshots-ios/en-US"
        let three = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix + "-") }.sorted().prefix(3).compactMap { load("\(dir)/\($0)") }
        guard three.count == 3 else { continue }
        let s: CGFloat = 0.3, gap: CGFloat = 26
        let tw = CGFloat(three[0].width) * s, th = CGFloat(three[0].height) * s
        let ctx = canvas(Int(tw * 3 + gap * 4), Int(th + gap * 2))
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in three.enumerated() {
            let rect = CGRect(x: gap + CGFloat(i) * (tw + gap), y: gap, width: tw, height: th)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: tw * 0.07, cornerHeight: tw * 0.07, transform: nil)); ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            ctx.restoreGState()
        }
        save(ctx, "marketing/search-preview-\(prefix).png")
    }
}

// MARK: - Header

func header(_ w: Int, _ h: Int, _ name: String) {
    let ctx = canvas(w, h)
    let W = CGFloat(w), H = CGFloat(h)
    sky(ctx, W, H)
    let wide = W / H > 2.5
    let r = H * 0.2
    let centre = CGPoint(x: W * (wide ? 0.2 : 0.27), y: H * 0.5)
    ripples(ctx, centre: centre, first: r * 1.55, step: r * 0.62, count: 9, width: H * 0.0055, motes: 110, seed: w)
    orb(ctx, centre: centre, radius: r, label: "Breathe")
    let ink = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 1)
    let left = W * (wide ? 0.4 : 0.52), width = W * (wide ? 0.5 : 0.44)
    let nameSize = H * 0.2
    text(ctx, "Aerilo", centre: CGPoint(x: left + width / 2, y: H * 0.62), width: width, font: rounded(nameSize, .bold), colour: ink, align: .left, tracking: -nameSize * 0.02)
    text(ctx, "One tap, and your Mac and your photos breathe again.", centre: CGPoint(x: left + width / 2, y: H * 0.415), width: width, font: rounded(H * 0.052, .regular), colour: ink.withAlphaComponent(0.7), align: .left)
    text(ctx, "MAC  ·  IPHONE  ·  IPAD  ·  APPLE TV  ·  VISION PRO", centre: CGPoint(x: left + width / 2, y: H * 0.27), width: width, font: rounded(H * 0.021, .semibold), colour: ink.withAlphaComponent(0.45), align: .left, tracking: H * 0.002)
    save(ctx, "marketing/\(name)")
}

// MARK: - iPhone Duo

/// Drawn artwork, not screenshots: the folded screen shows the one button; the unfolded screen
/// shows the button and what it found, side by side.
func duo() {
    let ink = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 1)
    let rows: [(String, String, String?)] = [
        ("Exact duplicates", "11 items · 46 MB", "6 suggested"), ("Similar shots", "22 items · 120 MB", "16 suggested"),
        ("Old screenshots", "48 items · 472 MB", "48 suggested"), ("Largest videos", "12 items · 17.8 GB", nil),
    ]
    // Folded: 1398 x 2034.
    do {
        let (w, h) = (1398, 2034)
        let W = CGFloat(w), H = CGFloat(h)
        for (index, variant) in ["breathe", "found"].enumerated() {
            let ctx = canvas(w, h)
            sky(ctx, W, H)
            let centre = CGPoint(x: W / 2, y: H * (index == 0 ? 0.40 : 0.60))
            let r = W * (index == 0 ? 0.25 : 0.15)
            ripples(ctx, centre: centre, first: r * 1.5, step: r * (index == 0 ? 0.5 : 0.7), count: 9, width: W * 0.0045, motes: 90, seed: index * 31)
            orb(ctx, centre: centre, radius: r, label: index == 0 ? "Breathe" : "586 MB", sublabel: index == 0 ? "one tap to tidy your photos" : "could be freed")
            let head = index == 0 ? "One tap tidies your photos" : "See what could go"
            let detail = index == 0 ? "Aerilo gathers duplicates, similar shots, old screenshots and large videos." : "You review everything. Nothing is deleted until you choose."
            let hh = text(ctx, head, centre: CGPoint(x: W / 2, y: H * 0.875), width: W * 0.86, font: rounded(W * 0.092, .bold), colour: ink, tracking: -W * 0.001)
            text(ctx, detail, centre: CGPoint(x: W / 2, y: H * 0.875 - hh / 2 - W * 0.075), width: W * 0.8, font: rounded(W * 0.039, .regular), colour: ink.withAlphaComponent(0.62))
            if index == 1 { panel(ctx, CGRect(x: W * 0.07, y: H * 0.07, width: W * 0.86, height: H * 0.36), rows: rows) }
            save(ctx, "marketing/duo/folded-\(index + 1)-\(variant).png")
        }
    }
    // Unfolded: 2007 x 2853, two panes like an open book.
    do {
        let (w, h) = (2007, 2853)
        let W = CGFloat(w), H = CGFloat(h)
        let ctx = canvas(w, h)
        sky(ctx, W, H)
        let centre = CGPoint(x: W * 0.27, y: H * 0.43)
        let r = W * 0.15
        ripples(ctx, centre: centre, first: r * 1.5, step: r * 0.62, count: 12, width: W * 0.0034, motes: 140, seed: 7)
        orb(ctx, centre: centre, radius: r, label: "Breathe", sublabel: "one tap to tidy your photos")
        let hh = text(ctx, "Room to breathe, on both sides", centre: CGPoint(x: W / 2, y: H * 0.885), width: W * 0.86, font: rounded(W * 0.07, .bold), colour: ink, tracking: -W * 0.0008)
        text(ctx, "Tap on the left. Review what Aerilo found on the right. Nothing is deleted until you choose.", centre: CGPoint(x: W / 2, y: H * 0.885 - hh / 2 - W * 0.06),
             width: W * 0.78, font: rounded(W * 0.03, .regular), colour: ink.withAlphaComponent(0.62))
        panel(ctx, CGRect(x: W * 0.51, y: H * 0.27, width: W * 0.44, height: H * 0.32), rows: rows)
        text(ctx, "Deleted items stay in Recently Deleted for 30 days.", centre: CGPoint(x: W * 0.735, y: H * 0.225), width: W * 0.4, font: rounded(W * 0.019, .regular), colour: ink.withAlphaComponent(0.5))
        save(ctx, "marketing/duo/unfolded-1-both-sides.png")
    }
    print("drew iPhone Duo artwork in marketing/duo")
}

// MARK: - Run

let what = CommandLine.arguments.dropFirst().first ?? "all"
if what == "shots" || what == "all" { shots() }
if what == "header" || what == "all" {
    header(1920, 1080, "header-1920x1080.png")
    header(4320, 1080, "header-4320x1080.png")
    header(1280, 640, "social-1280x640.png")
    print("drew headers in marketing")
}
if what == "duo" || what == "all" { duo() }

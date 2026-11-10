// Draws the TV Extend app icon and writes a macOS AppIcon.appiconset.
//
//   swift Tools/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset   (Mac)
//   swift Tools/make-icon.swift --android ../tv/app/src/main/res          (TV)
//
// Everything is drawn with Core Graphics on a 1024×1024 grid, then re-drawn at each
// size so small icons stay sharp.

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
    ctx.restoreGState()
}

/// Draws the icon in 1024-point coordinates (origin bottom-left).
func drawIcon(_ ctx: CGContext) {
    drawTile(ctx)
    drawTV(ctx)
}

/// Rounded indigo background tile with a soft shadow.
func drawTile(_ ctx: CGContext) {
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x312E81))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, path: tile, colors: [color(0x6D6AF5), color(0x2E2A7A)],
                 from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
}

/// The TV, window, pointer and wireless arcs. Content spans roughly x 192–832, y 214–874.
func drawTV(_ ctx: CGContext) {
    let bezelColor = color(0x0B1020)

    // Stand: neck + foot.
    ctx.setFillColor(bezelColor)
    ctx.addPath(roundedRect(CGRect(x: 482, y: 240, width: 60, height: 70), 8))
    ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: 382, y: 214, width: 260, height: 36), 18))
    ctx.fillPath()

    // TV body.
    let body = CGRect(x: 192, y: 296, width: 640, height: 404)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
    ctx.addPath(roundedRect(body, 46))
    ctx.setFillColor(bezelColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Screen with a cyan → violet gradient and a faint glare band.
    let screenRect = body.insetBy(dx: 26, dy: 26)
    let screen = roundedRect(screenRect, 24)
    fillGradient(ctx, path: screen, colors: [color(0x22D3EE), color(0x6366F1), color(0xA855F7)],
                 from: CGPoint(x: screenRect.minX, y: screenRect.maxY),
                 to: CGPoint(x: screenRect.maxX, y: screenRect.minY))
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    let glare = CGMutablePath()
    glare.move(to: CGPoint(x: screenRect.minX + 300, y: screenRect.maxY))
    glare.addLine(to: CGPoint(x: screenRect.minX + 470, y: screenRect.maxY))
    glare.addLine(to: CGPoint(x: screenRect.minX + 230, y: screenRect.minY))
    glare.addLine(to: CGPoint(x: screenRect.minX + 60, y: screenRect.minY))
    glare.closeSubpath()
    ctx.addPath(glare)
    ctx.setFillColor(color(0xFFFFFF, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // A window sliding onto the TV — the "extended display" idea.
    let window = CGRect(x: 262, y: 410, width: 300, height: 196)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.30))
    ctx.addPath(roundedRect(window, 20))
    ctx.setFillColor(color(0xFFFFFF, 0.96))
    ctx.fillPath()
    ctx.restoreGState()
    // Title bar strip and traffic lights.
    ctx.saveGState()
    ctx.addPath(roundedRect(window, 20))
    ctx.clip()
    ctx.setFillColor(color(0xE2E8F0))
    ctx.fill(CGRect(x: window.minX, y: window.maxY - 40, width: window.width, height: 40))
    ctx.restoreGState()
    for (index, hex) in [UInt32(0xF87171), 0xFBBF24, 0x34D399].enumerated() {
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: window.minX + 20 + CGFloat(index) * 30, y: window.maxY - 29, width: 18, height: 18))
    }
    // Content lines.
    ctx.setFillColor(color(0xCBD5E1))
    for (index, width) in [CGFloat(220), 170, 200].enumerated() {
        ctx.addPath(roundedRect(CGRect(x: window.minX + 24, y: window.maxY - 82 - CGFloat(index) * 36, width: width, height: 16), 8))
        ctx.fillPath()
    }

    // Mouse pointer dragging the window.
    let pointer = CGMutablePath()
    let tip = CGPoint(x: 530, y: 452)
    let p: [CGPoint] = [(0, 0), (0, -132), (34, -100), (58, -152), (82, -141), (58, -91), (104, -91)]
        .map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) }
    pointer.addLines(between: p)
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.35))
    ctx.addPath(pointer)
    ctx.setFillColor(color(0x0B1020))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // Wireless arcs above the TV.
    let center = CGPoint(x: 512, y: 742)
    ctx.setStrokeColor(color(0xFFFFFF, 0.95))
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    for radius in [CGFloat(62), 114] {
        ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.27, endAngle: .pi * 0.73, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - 17, y: center.y - 3, width: 34, height: 34))
}

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

func renderPNG(pixels: Int) -> Data {
    render(width: pixels, height: pixels) { ctx in
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(ctx)
    }
}

/// Android TV launcher banner (320×180 at xhdpi): gradient, TV on the left, name on the right.
func renderBanner() -> Data {
    render(width: 320, height: 180) { ctx in
        let full = CGRect(x: 0, y: 0, width: 320, height: 180)
        fillGradient(ctx, path: CGPath(rect: full, transform: nil),
                     colors: [color(0x6D6AF5), color(0x2E2A7A)],
                     from: CGPoint(x: 0, y: 180), to: CGPoint(x: 320, y: 0))

        // TV artwork, scaled to fit a ~140pt square on the left.
        ctx.saveGState()
        let scale: CGFloat = 140 / 680
        ctx.translateBy(x: 82 - 512 * scale, y: 90 - 545 * scale)
        ctx.scaleBy(x: scale, y: scale)
        drawTV(ctx)
        ctx.restoreGState()

        // App name.
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        for (text, y, size, weight, alpha) in [("TV", CGFloat(96), CGFloat(40), NSFont.Weight.heavy, CGFloat(1)),
                                               ("Extend", CGFloat(56), CGFloat(32), NSFont.Weight.semibold, CGFloat(0.9))] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                fromContext: true,
            ]))
            ctx.setFillColor(color(0xFFFFFF, alpha))
            ctx.textPosition = CGPoint(x: 168, y: y)
            CTLineDraw(line, ctx)
        }
    }
}

// Android mode: swift Tools/make-icon.swift --android ../tv/app/src/main/res
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--android" {
    let res = URL(fileURLWithPath: CommandLine.arguments[2])
    let densities: [(String, Int)] = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
    for (density, pixels) in densities {
        let dir = res.appendingPathComponent("mipmap-\(density)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try renderPNG(pixels: pixels).write(to: dir.appendingPathComponent("ic_launcher.png"))
    }
    let drawable = res.appendingPathComponent("drawable-xhdpi")
    try FileManager.default.createDirectory(at: drawable, withIntermediateDirectories: true)
    try renderBanner().write(to: drawable.appendingPathComponent("banner.png"))
    print("Wrote Android launcher icons and banner to \(res.path)")
    exit(0)
}

// macOS icon slots: point size × scale.
let slots: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let filename = "icon_\(slot.size)x\(slot.size)\(suffix).png"
    try renderPNG(pixels: slot.size * slot.scale).write(to: outDir.appendingPathComponent(filename))
    images.append(["idiom": "mac", "size": "\(slot.size)x\(slot.size)", "scale": "\(slot.scale)x", "filename": filename])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))

// The asset catalog itself needs a Contents.json too.
let catalog = outDir.deletingLastPathComponent()
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!
    .write(to: catalog.appendingPathComponent("Contents.json"))

print("Wrote \(slots.count) icons to \(outDir.path)")

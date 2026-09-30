// Renders Resources/AppIcon.icns. Run from the repo root: swift scripts/make-icon.swift
// Artwork is drawn from paths (no emoji or SF Symbols, whose licenses exclude app icons),
// in the website's palette: near-black body, green accent.
import AppKit

let outputICNS = URL(fileURLWithPath: "Resources/AppIcon.icns")
let previewPNG = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/MacSlapApp-icon.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func starPath(center: CGPoint, points: Int, outer: CGFloat, inner: CGFloat, rotation: CGFloat,
              jitter: [CGFloat] = []) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<(points * 2) {
        let angle = rotation + CGFloat(i) * .pi / CGFloat(points)
        var radius = i.isMultiple(of: 2) ? outer : inner
        if i.isMultiple(of: 2), !jitter.isEmpty { radius *= jitter[(i / 2) % jitter.count] }
        let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824pt body centered on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0A0A0A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    let bg = CGGradient(colorsSpace: space, colors: [color(0x1B1F1C), color(0x0A1A0F)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    let center = CGPoint(x: 540, y: 490)
    let glow = CGGradient(colorsSpace: space, colors: [color(0x4ADE80, 0.35), color(0x4ADE80, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420,
                           options: [])

    // Motion arcs: the swing coming in from the upper left.
    ctx.setLineCap(.round)
    for (i, radius) in [CGFloat(322), 372, 422].enumerated() {
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: .pi * 0.63, endAngle: .pi * 0.87, clockwise: false)
        ctx.addPath(arc)
        ctx.setStrokeColor(color(0x4ADE80, 0.85 - CGFloat(i) * 0.25))
        ctx.setLineWidth(28 - CGFloat(i) * 6)
        ctx.strokePath()
    }

    // Impact burst.
    let jitter: [CGFloat] = [1.0, 0.86, 0.97, 0.8, 1.04, 0.9, 0.95, 0.82, 1.0, 0.88, 0.93, 0.84]
    let outer = starPath(center: center, points: 12, outer: 285, inner: 150, rotation: 0.12, jitter: jitter)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.5))
    ctx.addPath(outer)
    ctx.setFillColor(color(0x22C55E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(outer)
    ctx.clip()
    let burst = CGGradient(colorsSpace: space, colors: [color(0x86EFAC), color(0x4ADE80), color(0x16A34A)] as CFArray,
                           locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(burst, start: CGPoint(x: center.x - 200, y: center.y + 260),
                           end: CGPoint(x: center.x + 200, y: center.y - 260), options: [])
    ctx.restoreGState()

    let inner = starPath(center: center, points: 12, outer: 150, inner: 88, rotation: 0.38)
    ctx.addPath(inner)
    ctx.setFillColor(color(0xF0FDF4))
    ctx.fillPath()

    // Glass rim.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(pixels: 1024).write(to: previewPNG)

try fm.createDirectory(at: outputICNS.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputICNS.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("Wrote \(outputICNS.path) and preview \(previewPNG.path)")

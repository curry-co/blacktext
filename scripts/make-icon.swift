// Draws the BlackText icon (a white "bt" on a black square).
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns     (Mac: a rounded tile, as an .icns)
//        swift scripts/make-icon.swift path/to/AppIcon.png        (iOS: a full-bleed 1024 square; iOS rounds it)
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iOS = output.hasSuffix(".png")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blacktext.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let letters = "bt"
let weight = NSFont.Weight.medium

func line(size: CGFloat) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    return CTLineCreateWithAttributedString(NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: NSColor.white]))
}

func inkBounds(_ line: CTLine, in context: CGContext) -> CGRect {
    CTLineGetImageBounds(line, context)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    let tile: NSRect
    if iOS {
        // iOS masks the corners itself, so the black fills the whole square.
        tile = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        NSColor.black.setFill()
        tile.fill()
    } else {
        // The macOS icon grid: an 824-point rounded square centered on a 1024 canvas.
        tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        // Shadows ignore the context's scale, so scale them by hand or they're clipped at small sizes.
        shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        shadow.shadowBlurRadius = 28 * scale
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A faint rim so the black tile still reads on a dark Dock.
        NSColor(white: 1, alpha: 0.10).setStroke()
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
        rim.lineWidth = 4
        rim.stroke()
    }

    // "bt", sized so its ink is at most 380 tall and 540 wide on the Mac's 824 tile (scaled up for iOS's
    // full square), and centered by its ink rather than its line box.
    let k = tile.width / 824
    let probe = inkBounds(line(size: 100), in: context)
    let size = min(380 * k / probe.height, 540 * k / probe.width) * 100
    let text = line(size: size)
    let ink = inkBounds(text, in: context)
    context.textPosition = CGPoint(x: tile.midX - ink.midX, y: tile.midY - ink.midY)
    CTLineDraw(text, context)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if iOS {
    // One opaque 1024 PNG; Xcode makes the other sizes.
    let png = render(1024)
    let image = NSBitmapImageRep(data: png)!
    let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                  samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 32)! // 32 bits with the alpha byte skipped: drawable, no alpha
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: opaque)
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
    try opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("Wrote \(output)")
    exit(0)
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")

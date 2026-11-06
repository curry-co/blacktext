// Draws the BlackText icon (a white "bt" on a black square) and writes an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
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

    // The macOS icon grid: an 824-point rounded square centered on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
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

    // "bt", sized so its ink is at most 380 tall and 540 wide, and centered by its ink rather than its line box.
    let probe = inkBounds(line(size: 100), in: context)
    let size = min(380 / probe.height, 540 / probe.width) * 100
    let text = line(size: size)
    let ink = inkBounds(text, in: context)
    context.textPosition = CGPoint(x: tile.midX - ink.midX, y: tile.midY - ink.midY)
    CTLineDraw(text, context)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
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

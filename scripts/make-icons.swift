// Draws the cDownloader icon (blue rounded square with a white download arrow) at every size needed.
// Usage: swift scripts/make-icons.swift <output folder>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    let side = CGFloat(size)
    let inset = side * 0.09
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), NSColor(red: 0.08, green: 0.28, blue: 0.85, alpha: 1)])!
        .draw(in: shape, angle: -90)
    // Arrow: a shaft and a head pointing down onto a tray line.
    NSColor.white.setFill()
    let w = rect.width
    let cx = rect.midX
    let shaft = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.07, y: rect.minY + w * 0.40, width: w * 0.14, height: w * 0.36), xRadius: w * 0.03, yRadius: w * 0.03)
    shaft.fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx - w * 0.22, y: rect.minY + w * 0.47))
    head.line(to: NSPoint(x: cx + w * 0.22, y: rect.minY + w * 0.47))
    head.line(to: NSPoint(x: cx, y: rect.minY + w * 0.25))
    head.close()
    head.fill()
    let tray = NSBezierPath(roundedRect: NSRect(x: rect.minX + w * 0.22, y: rect.minY + w * 0.15, width: w * 0.56, height: w * 0.07), xRadius: w * 0.035, yRadius: w * 0.035)
    tray.fill()
    NSGraphicsContext.restoreGraphicsState()
    return pixels.representation(using: .png, properties: [:])!
}

// macOS app icon set
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// Browser add-on icons
for size in [16, 32, 48, 128] {
    try! render(size: size).write(to: output.appendingPathComponent("icon\(size).png"))
}
print("icons written to \(output.path)")

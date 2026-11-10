import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(red: 0.12, green: 0.30, blue: 0.54, alpha: 1),
                   ending: NSColor(red: 0.04, green: 0.12, blue: 0.26, alpha: 1))!.draw(in: background, angle: -90)
        NSColor.white.setStroke()
        let display = NSBezierPath(roundedRect: NSRect(x: 220, y: 360, width: 584, height: 398), xRadius: 35, yRadius: 35)
        display.lineWidth = 38
        display.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 360)); stand.line(to: NSPoint(x: 512, y: 260))
        stand.move(to: NSPoint(x: 380, y: 250)); stand.line(to: NSPoint(x: 644, y: 250))
        stand.lineWidth = 38; stand.lineCapStyle = .round; stand.stroke()
        NSColor(red: 0.44, green: 0.92, blue: 0.69, alpha: 1).setStroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 394, y: 555)); check.line(to: NSPoint(x: 477, y: 472)); check.line(to: NSPoint(x: 644, y: 645))
        check.lineWidth = 46; check.lineJoinStyle = .round; check.lineCapStyle = .round; check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

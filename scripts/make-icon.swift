import AppKit
import Foundation

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Sense.iconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create context") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let side = CGFloat(pixels)
        let bounds = NSRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84)
        NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.19, yRadius: side * 0.19).fill()
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: side * 0.23, y: side * 0.5))
        wave.line(to: NSPoint(x: side * 0.34, y: side * 0.5))
        wave.curve(to: NSPoint(x: side * 0.43, y: side * 0.72), controlPoint1: NSPoint(x: side * 0.39, y: side * 0.5), controlPoint2: NSPoint(x: side * 0.38, y: side * 0.72))
        wave.curve(to: NSPoint(x: side * 0.56, y: side * 0.28), controlPoint1: NSPoint(x: side * 0.49, y: side * 0.72), controlPoint2: NSPoint(x: side * 0.50, y: side * 0.28))
        wave.curve(to: NSPoint(x: side * 0.66, y: side * 0.5), controlPoint1: NSPoint(x: side * 0.61, y: side * 0.28), controlPoint2: NSPoint(x: side * 0.61, y: side * 0.5))
        wave.line(to: NSPoint(x: side * 0.77, y: side * 0.5))
        wave.lineWidth = side * 0.045; wave.lineCapStyle = .round
        NSColor.white.setStroke(); wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
    }
}

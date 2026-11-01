import AppKit
import SwiftUI

// The menu bar symbol on a light tile: the island with three playback bars cut out of it.
// The tile follows Apple's macOS icon grid, an 824 pt rounded square on a 1024 pt canvas.
func draw(in context: CGContext, side: CGFloat) {
    let inset = side * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let tilePath = Path(roundedRect: tile, cornerRadius: tile.width * 0.2237, style: .continuous).cgPath
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.024, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(tilePath); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath); context.clip()
    let colors = [CGColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1), CGColor(srgbRed: 0.82, green: 0.84, blue: 0.89, alpha: 1)] as CFArray
    context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    context.restoreGState()

    // The same proportions as the menu bar symbol: 17 by 10 units, with the bars at 5.75, 8 and 10.25.
    let unit = tile.width * 0.74 / 17
    let island = CGRect(x: tile.midX - 8.5 * unit, y: tile.midY - 5 * unit, width: 17 * unit, height: 10 * unit)
    let symbol = CGMutablePath()
    symbol.addRoundedRect(in: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2)
    for (index, height) in [3.0, 6, 4].enumerated() {
        symbol.addRoundedRect(in: CGRect(x: island.minX + (5.75 + CGFloat(index) * 2.25) * unit, y: island.midY - CGFloat(height) * unit / 2, width: 1.25 * unit, height: CGFloat(height) * unit), cornerWidth: 0.625 * unit, cornerHeight: 0.625 * unit)
    }
    context.addPath(symbol); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath(using: .evenOdd)
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Brim.iconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create context") }
        draw(in: context, side: CGFloat(pixels))
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
    }
}

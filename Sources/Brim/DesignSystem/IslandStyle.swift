import AppKit
import SwiftUI

/// A color for the playback bars taken from the artwork, as the iPhone's island does. Colorful pixels count for more
/// than dark or gray ones, so a splash of color on a black cover still sets the tone. Art with no color gives a soft white.
enum ArtworkTint {
    struct RGB: Equatable, Sendable {
        var red: Double, green: Double, blue: Double
        /// The bars' green until there's artwork to go by.
        static let standard = RGB(red: 0.25, green: 0.85, blue: 0.35)
        func mixed(fromGray gray: Double, by amount: Double) -> Color {
            Color(red: gray + (red - gray) * amount, green: gray + (green - gray) * amount, blue: gray + (blue - gray) * amount)
        }
    }
    static func rgb(of image: NSImage?) -> RGB {
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .standard }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .standard }
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for start in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[start]) / 255, g = Double(pixels[start + 1]) / 255, b = Double(pixels[start + 2]) / 255
            let colorfulness = max(r, g, b) - min(r, g, b)
            let weight = colorfulness * colorfulness
            red += r * weight; green += g * weight; blue += b * weight; total += weight
        }
        // Barely any color anywhere: a gray or black-and-white cover.
        guard total > 0.5 else { return RGB(red: 0.88, green: 0.88, blue: 0.88) }
        let mean = NSColor(deviceRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        mean.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Bright enough to read on the black island, whatever the cover's mood.
        let readable = NSColor(deviceHue: hue, saturation: min(0.75, max(0.45, saturation)), brightness: max(0.92, brightness), alpha: 1)
        return RGB(red: Double(readable.redComponent), green: Double(readable.greenComponent), blue: Double(readable.blueComponent))
    }
    #if DEBUG
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in color.setFill(); rect.fill(); return true }
    }
    #endif
}

/// The island's few shared values. Everything inside the island picks from these, so radii, fills and motion
/// stay consistent; the island's own open/close spring and the pane cross-fade are tuned separately.
enum IslandStyle {
    /// Buttons, tiles and cards.
    static let smallRadius: CGFloat = 12
    /// Large panels such as the drop zones and the empty shelf.
    static let largeRadius: CGFloat = 18
    /// Resting tiles and tracks.
    static let tileFill = Color.white.opacity(0.07)
    /// Selected or raised elements on a tile.
    static let raisedFill = Color.white.opacity(0.14)
    /// Hairline borders.
    static let hairline = Color.white.opacity(0.1)
    /// Selection, hover and small state changes.
    static let quick = Animation.snappy(duration: 0.18)
    /// Content that changes in place (a new track title, a different symbol).
    static let standard = Animation.smooth(duration: 0.3)
    /// The island opening, with the give of the iPhone's. The panel leaves room for the overshoot.
    static let open = Animation.spring(duration: 0.44, bounce: 0.24)
    /// The island settling back to its compact size.
    static let settle = Animation.spring(duration: 0.36, bounce: 0.14)
    /// A second activity parting from the island, and the height changing between sections.
    static let part = Animation.spring(duration: 0.5, bounce: 0.28)
    static let resize = Animation.spring(duration: 0.34, bounce: 0.12)
    /// Progress that should move at an even pace. The timer ring steps once a second with a short glide, then rests:
    /// an animation that never ends would redraw the island at the display's full frame rate the whole time.
    static let progress = Animation.linear(duration: 0.25)
}

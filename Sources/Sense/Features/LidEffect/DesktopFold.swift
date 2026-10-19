import AppKit
import SwiftUI
import QuartzCore
import ScreenCaptureKit

/// A vertical closing fold: top and bottom halves share a recessed hinge, while the outside edges remain nearer.
/// The flat pose is exactly the original desktop, avoiding a jump when capture first appears.
struct DesktopFold {
    let progress: Double
    var phase: Double { let p = min(1, max(0, progress)); return p * p * (3 - 2 * p) }
    var opacity: Double { 1 - max(0, (min(1, max(0, progress)) - 0.9) / 0.1) }
    func corners(size: CGSize, bottom: Bool) -> [CGPoint] {
        let w = size.width, h = size.height, p = phase
        let outerY = h * 0.42 * pow(p, 1.2)
        let outerX = w * 0.055 * p
        let hingeX = w * 0.26 * p
        // Top/bottom panels contract vertically and share a horizontal recessed hinge.
        if bottom {
            return [CGPoint(x: hingeX, y: 0), CGPoint(x: w - hingeX, y: 0),
                    CGPoint(x: w - outerX, y: h / 2 - outerY), CGPoint(x: outerX, y: h / 2 - outerY)]
        }
        return [CGPoint(x: outerX, y: outerY), CGPoint(x: w - outerX, y: outerY),
                CGPoint(x: w - hingeX, y: h / 2), CGPoint(x: hingeX, y: h / 2)]
    }
}

/// Homography maps all four corners, so the two panels meet with no gap at every lid angle.
struct FoldProjection: GeometryEffect {
    var progress: Double
    var bottom: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let corners = DesktopFold(progress: progress).corners(size: CGSize(width: size.width, height: size.height * 2), bottom: bottom)
        return ProjectionTransform(Self.matrix(size: size, corners: corners))
    }
    static func matrix(size: CGSize, corners: [CGPoint]) -> CATransform3D {
        guard size.width > 0, size.height > 0, corners.count == 4 else { return CATransform3DIdentity }
        let a = corners[0], b = corners[1], c = corners[2], d = corners[3]
        let dx1 = b.x - c.x, dx2 = d.x - c.x, sx = a.x - b.x + c.x - d.x
        let dy1 = b.y - c.y, dy2 = d.y - c.y, sy = a.y - b.y + c.y - d.y
        let determinant = dx1 * dy2 - dx2 * dy1
        let g: CGFloat, h: CGFloat
        if abs(sx) + abs(sy) < 0.000001 { g = 0; h = 0 }
        else {
            guard abs(determinant) > 0.000001 else { return CATransform3DIdentity }
            g = (sx * dy2 - dx2 * sy) / determinant
            h = (dx1 * sy - sx * dy1) / determinant
        }
        var matrix = CATransform3DIdentity
        matrix.m11 = (b.x - a.x + g * b.x) / size.width
        matrix.m12 = (b.y - a.y + g * b.y) / size.width
        matrix.m14 = g / size.width
        matrix.m21 = (d.x - a.x + h * d.x) / size.height
        matrix.m22 = (d.y - a.y + h * d.y) / size.height
        matrix.m24 = h / size.height
        matrix.m41 = a.x; matrix.m42 = a.y
        return matrix
    }
}

struct DesktopFoldView: View {
    let snapshot: NSImage
    var progress: Double
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fold = DesktopFold(progress: progress)
            ZStack {
                Color.black
                VStack(spacing: 0) {
                    half(size: size, bottom: false, phase: fold.phase)
                    half(size: size, bottom: true, phase: fold.phase)
                }.opacity(fold.opacity)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
    private func half(size: CGSize, bottom: Bool, phase: Double) -> some View {
        Image(nsImage: snapshot).resizable().frame(width: size.width, height: size.height)
            .blur(radius: (bottom ? 0.5 : 4) * phase)
            .offset(y: bottom ? -size.height / 2 : 0)
            .frame(width: size.width, height: size.height / 2, alignment: .top)
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity((bottom ? 0.22 : 0.12) * phase), .black.opacity((bottom ? 0.04 : 0.42) * phase)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: bottom ? .top : .bottom) {
                Rectangle().fill(.white.opacity(0.09 * phase)).frame(height: 1)
            }
            .modifier(FoldProjection(progress: progress, bottom: bottom))
    }
}

// Renders only Sense's own UI at fixed fold poses for inspection; never substitutes a sensor reading.
extension DesktopFoldView {
    @MainActor static func exportPreviews(to directory: URL) async -> [String] {
        guard #available(macOS 14.4, *), let snapshot = NSImage(contentsOf: directory.appendingPathComponent("general-dark.png")) else { return [] }
        let frame = CGRect(x: 80, y: 100, width: 960, height: 620)
        let panel = FloatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false
        defer { panel.orderOut(nil) }
        var names: [String] = []
        for progress in [0.0, 0.5, 0.85] {
            let view = NSHostingView(rootView: DesktopFoldView(snapshot: snapshot, progress: progress))
            view.sizingOptions = []; panel.contentView = view; panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(250))
            if let content = try? await SCShareableContent.currentProcess,
               let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = 1920; configuration.height = 1240; configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    let name = "duo-fold-\(Int(progress * 100)).png"
                    try? data.write(to: directory.appendingPathComponent(name)); names.append(name)
                }
            }
        }
        return names
    }
}

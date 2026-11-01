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

/// How the desktop closes with the lid.
enum LidFoldStyle: String, CaseIterable, Identifiable {
    case duo, fold, doors, shrink
    var id: String { rawValue }
    var title: String {
        switch self { case .duo: String(localized: "Duo"); case .fold: String(localized: "Fold"); case .doors: String(localized: "Doors"); case .shrink: String(localized: "Shrink") }
    }
    var detail: String {
        switch self {
        case .duo: String(localized: "The screen tips back as the lid closes, softening and darkening toward its edges.")
        case .fold: String(localized: "Top and bottom meet at a recessed hinge.")
        case .doors: String(localized: "Left and right panels swing shut.")
        case .shrink: String(localized: "The desktop gently recedes and dims.")
        }
    }
}

extension DesktopFold {
    /// The Duo pose: one panel hinged at the bottom edge. The top edge recedes (narrower and lower)
    /// as if the screen were being pushed away, while the bottom stays put at the hinge.
    func pushBackCorners(size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height, p = phase
        let topInset = w * 0.16 * p, topDrop = h * 0.34 * pow(p, 1.1), bottomInset = w * 0.02 * p
        return [CGPoint(x: topInset, y: topDrop), CGPoint(x: w - topInset, y: topDrop),
                CGPoint(x: w - bottomInset, y: h), CGPoint(x: bottomInset, y: h)]
    }
    enum Panel { case top, bottom, leading, trailing }
    /// Corners of one panel in its own frame. `size` is the full desktop size.
    /// Side panels reuse the vertical fold with the axes swapped.
    func corners(size: CGSize, panel: Panel) -> [CGPoint] {
        switch panel {
        case .top: return corners(size: size, bottom: false)
        case .bottom: return corners(size: size, bottom: true)
        case .leading, .trailing:
            let q = corners(size: CGSize(width: size.height, height: size.width), bottom: panel == .trailing)
                .map { CGPoint(x: $0.y, y: $0.x) }
            // Swapping axes mirrors the quad, so restore top-left, top-right, bottom-right, bottom-left.
            return [q[0], q[3], q[2], q[1]]
        }
    }
}

/// Homography maps all four corners, so the two panels meet with no gap at every lid angle.
struct FoldProjection: GeometryEffect {
    var progress: Double
    var panel: DesktopFold.Panel
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let full = (panel == .top || panel == .bottom) ? CGSize(width: size.width, height: size.height * 2) : CGSize(width: size.width * 2, height: size.height)
        return ProjectionTransform(Self.matrix(size: size, corners: DesktopFold(progress: progress).corners(size: full, panel: panel)))
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

/// Applies the Duo pose to a full-size view.
struct PushBackProjection: GeometryEffect {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(FoldProjection.matrix(size: size, corners: DesktopFold(progress: progress).pushBackCorners(size: size)))
    }
}

struct DesktopFoldView: View {
    let snapshot: NSImage
    var progress: Double
    var style: LidFoldStyle = .duo
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fold = DesktopFold(progress: progress)
            ZStack {
                Color.black
                switch style {
                case .duo:
                    pushBack(size: size, phase: fold.phase).opacity(fold.opacity)
                case .fold:
                    VStack(spacing: 0) {
                        half(size: size, panel: .top, phase: fold.phase)
                        half(size: size, panel: .bottom, phase: fold.phase)
                    }.opacity(fold.opacity)
                case .doors:
                    HStack(spacing: 0) {
                        half(size: size, panel: .leading, phase: fold.phase)
                        half(size: size, panel: .trailing, phase: fold.phase)
                    }.opacity(fold.opacity)
                case .shrink:
                    Image(nsImage: snapshot).resizable().frame(width: size.width, height: size.height)
                        .overlay(Color.black.opacity(0.55 * fold.phase))
                        .clipShape(RoundedRectangle(cornerRadius: 30 * fold.phase, style: .continuous))
                        .scaleEffect(1 - 0.18 * fold.phase)
                        .blur(radius: 5 * fold.phase)
                        .opacity(fold.opacity)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
    /// Sharp in the middle, blurred and darker toward the outer edges, then tipped back as one panel.
    private func pushBack(size: CGSize, phase: Double) -> some View {
        let edge = RadialGradient(colors: [.clear, .clear, .white], center: .center,
                                  startRadius: 0, endRadius: max(size.width, size.height) * 0.62)
        return ZStack {
            Image(nsImage: snapshot).resizable().frame(width: size.width, height: size.height)
            Image(nsImage: snapshot).resizable().frame(width: size.width, height: size.height)
                .blur(radius: 18 * phase).mask(edge)
            edge.opacity(0.55 * phase).colorMultiply(.black)
            Color.black.opacity(0.28 * phase)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 22 * phase, style: .continuous))
        .modifier(PushBackProjection(progress: progress))
    }
    private func half(size: CGSize, panel: DesktopFold.Panel, phase: Double) -> some View {
        let vertical = panel == .top || panel == .bottom
        let far = panel == .bottom || panel == .trailing
        return Image(nsImage: snapshot).resizable().frame(width: size.width, height: size.height)
            .blur(radius: (far ? 0.5 : 4) * phase)
            .offset(x: vertical || !far ? 0 : -size.width / 2, y: vertical && far ? -size.height / 2 : 0)
            .frame(width: vertical ? size.width : size.width / 2, height: vertical ? size.height / 2 : size.height, alignment: .topLeading)
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity((far ? 0.22 : 0.12) * phase), .black.opacity((far ? 0.04 : 0.42) * phase)],
                               startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
            }
            .overlay(alignment: vertical ? (far ? .top : .bottom) : (far ? .leading : .trailing)) {
                Rectangle().fill(.white.opacity(0.09 * phase))
                    .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
            }
            .modifier(FoldProjection(progress: progress, panel: panel))
    }
}

// Renders only Brim's own UI at fixed fold poses for inspection; never substitutes a sensor reading.
#if DEBUG
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
               let window = content.windows.first(where: { $0.windowID == panel.windowID }) {
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
#endif

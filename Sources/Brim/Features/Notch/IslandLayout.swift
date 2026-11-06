import SwiftUI
import AppKit

extension NSWindow {
    /// The window server's ID, or nil before the window has one. `windowNumber` is negative until a
    /// window is first shown, and converting that to `CGWindowID` traps.
    var windowID: CGWindowID? { windowNumber > 0 ? CGWindowID(exactly: windowNumber) : nil }
}

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandPanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

enum IslandTab { case music, files, clipboard, timer, transfers }

/// Camera clearance is measured separately from the visible activity on either side.
struct IslandLayout {
    var cutoutWidth: CGFloat
    var menuBarHeight: CGFloat
    var hasHardwareNotch: Bool
    var compactSize: CGSize {
        hasHardwareNotch
            ? CGSize(width: cutoutWidth + 104, height: menuBarHeight)
            : CGSize(width: 196, height: 38)
    }
    func surfaceSize(for presentation: IslandPresentation, reveal: Double = 1, notice: Bool = false, paneHeight: CGFloat? = nil) -> CGSize {
        let camera = CGSize(width: cutoutWidth, height: menuBarHeight)
        let target = presentation == .expanded ? (notice ? noticeSize : fittedSize(paneHeight)) : (presentation == .hidden && hasHardwareNotch ? camera : compactSize)
        guard hasHardwareNotch else { return target }
        let progress = min(1, max(0, reveal.isFinite ? reveal : 1))
        return CGSize(width: camera.width + (target.width - camera.width) * progress,
                      height: camera.height + (target.height - camera.height) * progress)
    }
    var expandedSize: CGSize { CGSize(width: max(408, compactSize.width), height: headerHeight + 202) }
    /// As tall as its contents, as on iPhone, up to the full island. The panel behind it never resizes.
    func fittedSize(_ paneHeight: CGFloat?) -> CGSize {
        guard let paneHeight else { return expandedSize }
        let fitted = headerHeight + Self.paneTopGap + paneHeight.rounded(.up) + Self.paneBottomGap
        return CGSize(width: expandedSize.width, height: min(expandedSize.height, fitted))
    }
    /// Room around the open island for a spring's overshoot, which the panel's edge would otherwise cut off flat.
    static let overshootRoom: CGFloat = 24
    func panelFrame(on screen: CGRect) -> CGRect {
        let open = frame(on: screen, expanded: true)
        return CGRect(x: open.minX - Self.overshootRoom, y: open.minY - Self.overshootRoom,
                      width: open.width + Self.overshootRoom * 2, height: open.height + Self.overshootRoom)
    }
    static let paneTopGap: CGFloat = 4
    static let paneBottomGap: CGFloat = 22
    /// A line of news only needs a line's worth of island, as on iPhone.
    var noticeSize: CGSize { CGSize(width: max(340, compactSize.width), height: headerHeight + Self.noticeContentHeight + 18) }
    static let noticeContentHeight: CGFloat = 44
    static let bubbleGap: CGFloat = 6
    var headerHeight: CGFloat { hasHardwareNotch ? menuBarHeight : 38 }
    func idleHoverFrame(on screen: CGRect) -> CGRect {
        // Exactly the camera housing: browser tabs and menus sit right beside and below it.
        let width = hasHardwareNotch ? cutoutWidth : compactSize.width
        let height = hasHardwareNotch ? headerHeight : compactSize.height
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - topGap - height, width: width, height: height)
    }
    var topGap: CGFloat { hasHardwareNotch ? 0 : 8 }
    func frame(on screen: CGRect, expanded: Bool, notice: Bool = false, paneHeight: CGFloat? = nil) -> CGRect {
        let size = expanded ? (notice ? noticeSize : fittedSize(paneHeight)) : compactSize
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - topGap - size.height, width: size.width, height: size.height)
    }
}

enum IslandHitRegion {
    static func contains(_ point: CGPoint, frame: CGRect, radius: CGFloat, roundedTop: Bool) -> Bool {
        // A pointer thrown at the top of the screen sits on its very edge, which a rectangle doesn't count as inside.
        let point = CGPoint(x: point.x, y: point.y == frame.maxY ? frame.maxY - 0.5 : point.y)
        guard frame.contains(point) else { return false }
        let r = min(radius, min(frame.width, frame.height) / 2)
        let lower = point.y < frame.minY + r
        let upper = roundedTop && point.y > frame.maxY - r
        guard lower || upper else { return true }
        let centerY = lower ? frame.minY + r : frame.maxY - r
        let centerX: CGFloat
        if point.x < frame.minX + r { centerX = frame.minX + r }
        else if point.x > frame.maxX - r { centerX = frame.maxX - r }
        else { return true }
        return pow(point.x - centerX, 2) + pow(point.y - centerY, 2) <= r * r
    }
}

/// Selects the display whose window the user is working in, from on-screen window bounds.
/// Bounds need no Screen Recording permission; titles and contents are never read.
enum ActiveDisplay {
    static func frontWindowBounds(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { continue }
            return rect
        }
        return nil
    }
    /// Converts a Quartz window rectangle (top-left origin) to AppKit space and picks the display it covers most.
    static func frame(for windowBounds: CGRect, in frames: [CGRect]) -> CGRect? {
        guard let primary = frames.first else { return nil }
        let flipped = CGRect(x: windowBounds.minX, y: primary.maxY - windowBounds.maxY, width: windowBounds.width, height: windowBounds.height)
        let best = frames.max { $0.intersection(flipped).area < $1.intersection(flipped).area }
        return best.flatMap { $0.intersects(flipped) ? $0 : nil }
    }
    static func current() -> NSScreen? {
        let screens = NSScreen.screens
        if let app = NSWorkspace.shared.frontmostApplication, let bounds = frontWindowBounds(pid: app.processIdentifier),
           let frame = frame(for: bounds, in: screens.map(\.frame)) { return screens.first { $0.frame == frame } }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Where a dragged file lands: the shelf (left half) or AirDrop (right half).
enum DropZone: Equatable {
    case shelf, airDrop
    static func at(x: CGFloat, width: CGFloat, airDropAvailable: Bool) -> Self {
        airDropAvailable && x > width / 2 ? .airDrop : .shelf
    }
}

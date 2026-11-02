import AppKit
import ApplicationServices

/// The iPhone's island has nothing beside it; the Mac's sits in a menu bar. An app with many menus or a crowded row of
/// status icons can end up under the compact island's wings, so the island steps aside when the pointer reaches for one.
enum MenuBarClearance {
    /// The parts of the compact island beside the camera. The camera itself covers nothing anyone could click.
    static func wings(of frame: CGRect, cutoutWidth: CGFloat) -> [ClosedRange<CGFloat>] {
        let inset = max(0, (frame.width - cutoutWidth) / 2)
        return [frame.minX...(frame.minX + inset), (frame.maxX - inset)...frame.maxX]
    }
    /// Reaching a covered item starts it. Once aside, the island stays out of the way anywhere over its wings, so moving
    /// along the menu bar doesn't make it flicker, and returns when the pointer leaves them.
    static func stepsAside(aside: Bool, x: CGFloat, wings: [ClosedRange<CGFloat>], covered: [ClosedRange<CGFloat>]) -> Bool {
        guard wings.contains(where: { $0.contains(x) }) else { return false }
        return aside || covered.contains { $0.contains(x) }
    }
    /// Where the menu bar's items are, side to side. Status icons need no permission. The front app's menus come from
    /// Accessibility, used only if already allowed: this never asks, it just knows less. Only positions are read, never names.
    @MainActor static func itemSpans(on display: CGRect) -> [ClosedRange<CGFloat>] {
        // Window and Accessibility rectangles measure from the top of the primary display.
        let top = (NSScreen.screens.first?.frame.maxY ?? display.maxY) - display.maxY
        func onThisBar(_ rect: CGRect) -> Bool { abs(rect.minY - top) < 5 && rect.width > 0 && rect.height < 50 }
        var rects = statusIconFrames().filter(onThisBar)
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            rects += menuFrames(of: app.processIdentifier).filter(onThisBar)
        }
        return rects.map { $0.minX...$0.maxX }
    }
    private static func statusIconFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width < 300 else { return nil }
            return rect
        }
    }
    private static func menuFrames(of pid: pid_t) -> [CGRect] {
        let application = AXUIElementCreateApplication(pid)
        // Asked on the main thread as the pointer arrives, so a stuck app can't hold the pointer up for long.
        AXUIElementSetMessagingTimeout(application, 0.05)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(bar, to: AXUIElement.self), kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return [] }
        return items.compactMap { item in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success, let position,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin)
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
            return CGRect(origin: origin, size: extent)
        }
    }
}

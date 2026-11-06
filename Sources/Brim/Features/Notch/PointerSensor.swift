import AppKit

/// Feels for the pointer only where the island can be hovered, instead of watching every mouse move on the Mac. An
/// invisible window lies exactly over that spot (the camera housing while the island is hidden, under the island
/// while it shows) and macOS reports the pointer entering, crossing and leaving it. Moving the mouse anywhere else
/// doesn't wake Brim. It's nearly transparent rather than fully, because a fully transparent window lets the
/// pointer through; under the camera, or under the island itself, there's nothing else to point at.
@MainActor final class PointerSensor {
    private var window: FloatingPanel?
    private let onPointer: @MainActor (CGPoint) -> Void
    init(onPointer: @escaping @MainActor (CGPoint) -> Void) { self.onPointer = onPointer }
    var frame: CGRect? { window?.isVisible == true ? window?.frame : nil }

    /// Puts the sensor over `frame`, under the island's own window so the island keeps its clicks. Nil takes it away.
    func place(_ frame: CGRect?, below island: NSWindow?) {
        guard let frame, frame.width >= 1, frame.height >= 1 else { window?.orderOut(nil); return }
        let window = self.window ?? make()
        if window.frame != frame { window.setFrame(frame, display: false) }
        guard !window.isVisible else { return }
        if let island, island.isVisible { window.order(.below, relativeTo: island.windowNumber) } else { window.orderFrontRegardless() }
    }
    func remove() { window?.orderOut(nil); window = nil }

    private func make() -> FloatingPanel {
        let window = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.hasShadow = false; window.animationBehavior = .none
        window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        // Where the island is, on every Space, and out of Mission Control and the window cycle, like the island.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isMovable = false; window.hidesOnDeactivate = false
        window.contentView = SensorView(onPointer: onPointer)
        self.window = window
        return window
    }
}

private final class SensorView: NSView {
    private let onPointer: @MainActor (CGPoint) -> Void
    init(onPointer: @escaping @MainActor (CGPoint) -> Void) { self.onPointer = onPointer; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTrackingAreas() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func report(_ event: NSEvent) {
        onPointer(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    // Where the pointer was when it left: `NSEvent.mouseLocation` can still say where it was a moment before.
    override func mouseExited(with event: NSEvent) { report(event) }
}

/// The island's own window reports the pointer crossing and leaving it while the pointer is on the island, so leaving
/// in one quick flick never goes unnoticed. Held by the controller: a tracking area doesn't keep its owner alive.
final class PointerEdge: NSResponder {
    private let onPointer: @MainActor (CGPoint) -> Void
    init(onPointer: @escaping @MainActor (CGPoint) -> Void) { self.onPointer = onPointer; super.init() }
    required init?(coder: NSCoder) { nil }
    func watch(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func report(_ event: NSEvent) { onPointer(event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { report(event) }
}

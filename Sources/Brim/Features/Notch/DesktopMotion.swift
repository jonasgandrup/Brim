import AppKit

/// When the desktop has come to rest after a trackpad gesture. A slide that changes Space ends with the Space
/// notification, which can arrive before or after the fingers lift; one that doesn't (a cancelled swipe, a tap)
/// sends nothing, so a short wait stands in. Mission Control keeps the desktop "moving" for as long as it's open.
enum DesktopSettle {
    static let afterSpaceChange: TimeInterval = 0.12
    static let withoutSpaceChange: TimeInterval = 0.7
    static func settled(began: TimeInterval, lifted: TimeInterval, spaceChanged: TimeInterval?, now: TimeInterval, overviewOpen: Bool) -> Bool {
        guard !overviewOpen else { return false }
        if let spaceChanged, spaceChanged >= began { return now - max(lifted, spaceChanged) >= afterSpaceChange }
        return now - lifted >= withoutSpaceChange
    }
}

/// Mission Control and App Exposé are the Dock's layer-18 window. Owner, layer and nothing else: no titles or images.
enum DesktopOverview {
    static let layer = 18
    nonisolated static func isOpen() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == dock && ($0[kCGWindowLayer as String] as? Int) == layer }
    }
}

/// Tells the island when the desktop starts to move under it and when it has settled again. macOS says nothing
/// until a Space slide is over, so the start is the system gesture's fingers landing on the trackpad. Nothing
/// runs between gestures; the window list is read only after one, until the desktop is still.
@MainActor final class DesktopMotionMonitor {
    private let touches = MultitouchMonitor.shared
    private var fingers = 0
    private var began: TimeInterval = 0
    private var lifted: TimeInterval?
    private var spaceChanged: TimeInterval?
    private var settleTask: Task<Void, Never>?
    private var onChange: @MainActor (Bool) -> Void = { _ in }
    private(set) var moving = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        if fingers == 0 { watch() }
    }
    func stop() {
        touches.stopGestures(); fingers = 0
        settleTask?.cancel(); settleTask = nil; lifted = nil; moving = false
    }
    func spaceDidChange() {
        spaceChanged = now
        touches.refreshDevices()
        // The Trackpad settings may have moved the system gestures to four fingers, or back.
        if !moving, SystemGestureFingers.current() != fingers { watch() }
    }
    private func watch() {
        fingers = SystemGestureFingers.current()
        touches.watchGestures(fingers: fingers) { [weak self] down in self?.fingersChanged(down) }
    }
    private func fingersChanged(_ down: Bool) {
        if down {
            settleTask?.cancel(); began = now; lifted = nil
            if !moving { moving = true; onChange(true) }
        } else {
            lifted = now; waitForRest()
        }
    }
    private func waitForRest() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let overview = await Task.detached(priority: .userInitiated) { DesktopOverview.isOpen() }.value
                guard !Task.isCancelled, let self, let lifted = self.lifted else { return }
                if DesktopSettle.settled(began: self.began, lifted: lifted, spaceChanged: self.spaceChanged, now: self.now, overviewOpen: overview) {
                    self.moving = false; self.onChange(false); return
                }
            }
        }
    }
}

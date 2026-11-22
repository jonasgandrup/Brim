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
/// until a Space slide is over, so the start is the system gesture's fingers landing on the trackpad. The trackpad
/// is only felt while there's an island to tuck away: with nothing in the notch, Brim hears no touches at all.
@MainActor final class DesktopMotionMonitor {
    private let touches = MultitouchMonitor.shared
    private var fingers = 0
    private var wanted = false
    private var began: TimeInterval = 0
    private var lifted: TimeInterval?
    private var spaceChanged: TimeInterval?
    private var settleTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var onChange: @MainActor (Bool) -> Void = { _ in }
    private(set) var moving = false
    /// Whether the trackpad is being felt now.
    var listening: Bool { fingers != 0 }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }
    /// On while something shows in the notch (or it's tucked away, waiting for the desktop to settle). Off waits a
    /// few seconds, so a brief notice coming and going doesn't open and close the trackpad each time.
    func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        releaseTask?.cancel(); releaseTask = nil
        if on { if !listening { watch() } } else { releaseSoon() }
    }
    func stop() {
        wanted = false; releaseTask?.cancel(); releaseTask = nil
        release()
        settleTask?.cancel(); settleTask = nil; lifted = nil; moving = false
    }
    func spaceDidChange() {
        spaceChanged = now
        guard listening else { return }
        touches.refreshDevices()
        // The Trackpad settings may have moved the system gestures to four fingers, or back.
        if !moving, SystemGestureFingers.current() != fingers { watch() }
    }
    private func watch() {
        fingers = SystemGestureFingers.current()
        touches.watchGestures(fingers: fingers) { [weak self] down in self?.fingersChanged(down) }
    }
    private func release() { if listening { touches.stopGestures(); fingers = 0 } }
    private func releaseSoon() {
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.wanted, !self.moving else { return }
            self.releaseTask = nil; self.release()
        }
    }
    private func fingersChanged(_ down: Bool) {
        if down {
            settleTask?.cancel(); began = now; lifted = nil
            if !moving { moving = true; onChange(true) }
        } else {
            lifted = now; waitForRest()
        }
    }
    /// The timing alone says when a slide is over; the window list is read only then, to see whether Mission Control
    /// is still open, and while it is, a few times a second rather than ten.
    private func waitForRest() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            var wait = Duration.milliseconds(100)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self, let lifted = self.lifted else { return }
                guard DesktopSettle.settled(began: self.began, lifted: lifted, spaceChanged: self.spaceChanged, now: self.now, overviewOpen: false) else { continue }
                let overview = await Task.detached(priority: .userInitiated) { DesktopOverview.isOpen() }.value
                guard !Task.isCancelled, self.lifted != nil else { return }
                if overview { wait = .milliseconds(300); continue }
                self.moving = false; self.onChange(false)
                if !self.wanted { self.releaseSoon() }
                return
            }
        }
    }
}

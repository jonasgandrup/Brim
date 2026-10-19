import AppKit
import CoreGraphics

struct DesktopOverlay: Sendable {
    let layer: Int
    let bounds: CGRect
    var fillsDisplay = false
    var windowID: CGWindowID = 0
}

enum DesktopOverlayDetection {
    static func containsSwitcher(_ overlays: [DesktopOverlay]) -> Bool {
        // Ignore the ordinary Dock strip, wallpaper, tooltips and desktop widgets.
        overlays.contains {
            $0.bounds.width >= 200 && $0.bounds.height >= 120 &&
                ($0.layer == 18 || ($0.layer > 18 && !$0.fillsDisplay))
        }
    }
}

/// Space swipes use full-display Dock surfaces that ordinary switcher detection must ignore.
/// Track their creation/removal instead of treating the persistent desktop backdrop as a switcher.
struct SpaceSlideTracker {
    private var baseline: Set<CGWindowID>?
    private var previous: Set<CGWindowID> = []
    private var beganAt: TimeInterval?
    private var changedAt: TimeInterval = 0
    private var completedAt: TimeInterval?
    private var wasOverview = false
    mutating func spaceDidChange(at now: TimeInterval) {
        completedAt = now
        if beganAt == nil { beganAt = now; changedAt = now }
    }
    mutating func update(surfaces: Set<CGWindowID>, at now: TimeInterval, overviewActive: Bool = false) -> Bool {
        if overviewActive {
            wasOverview = true; baseline = surfaces; previous = surfaces
            beganAt = nil; completedAt = nil; changedAt = now
            return false
        }
        if wasOverview {
            wasOverview = false; baseline = surfaces; previous = surfaces
            beganAt = now; completedAt = now; changedAt = now
        }
        guard let baseline else { self.baseline = surfaces; previous = surfaces; return false }
        if surfaces != previous {
            if beganAt == nil { beganAt = now }
            previous = surfaces; changedAt = now
        }
        guard let beganAt else { return false }
        let returnedToStart = surfaces == baseline
        let completionObserved = completedAt != nil || returnedToStart
        let quietSince = max(changedAt, completedAt ?? changedAt)
        // A held gesture can have one perfectly still surface. Quiet alone never completes it.
        if now - beganAt >= 12 || (completionObserved && now - quietSince >= 0.6) {
            self.baseline = surfaces; self.beganAt = nil; completedAt = nil; return false
        }
        return true
    }
}

/// Uses public window metadata only: owner PID, layer and bounds. No window titles or images.
private actor DesktopOverlayProbe {
    func snapshot(ownerPIDs: Set<pid_t>, screenSizes: [CGSize]) -> [DesktopOverlay]? {
        guard !ownerPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let overlays = windows.compactMap { info -> DesktopOverlay? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, ownerPIDs.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            let fillsDisplay = screenSizes.contains { bounds.width >= $0.width * 0.9 && bounds.height >= $0.height * 0.85 }
            return DesktopOverlay(layer: layer, bounds: bounds, fillsDisplay: fillsDisplay, windowID: info[kCGWindowNumber as String] as? CGWindowID ?? 0)
        }
        return overlays
    }
}

@MainActor final class DesktopTransitionMonitor {
    private var task: Task<Void, Never>?
    private let probe = DesktopOverlayProbe()
    private var shortcutModifier: CGEventFlags?
    private var active = false
    private var slides = SpaceSlideTracker()
    private(set) var spaceSlideCount = 0
    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self, probe] in
            var owners = Set<pid_t>()
            var wasSliding = false
            var nextOwnerRefresh = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date() >= nextOwnerRefresh {
                    let bundles: Set<String> = ["com.apple.dock", "com.lwouis.alt-tab-macos"]
                    owners = Set(NSWorkspace.shared.runningApplications.filter { bundles.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
                    nextOwnerRefresh = Date().addingTimeInterval(2)
                }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if let modifier = self.shortcutModifier, !flags.contains(modifier) { self.shortcutModifier = nil }
                // Only shortcut state is sampled. Never collect text or request keyboard permissions.
                if CGEventSource.keyState(.combinedSessionState, key: 48) {
                    if flags.contains(.maskCommand) { self.shortcutModifier = .maskCommand }
                    else if flags.contains(.maskAlternate) { self.shortcutModifier = .maskAlternate }
                }
                guard let windows = await probe.snapshot(ownerPIDs: owners, screenSizes: NSScreen.screens.map { $0.frame.size }) else {
                    try? await Task.sleep(for: .milliseconds(80)); continue
                }
                guard !Task.isCancelled else { return }
                let overview = DesktopOverlayDetection.containsSwitcher(windows)
                let slide = self.slides.update(surfaces: Set(windows.filter { $0.fillsDisplay && $0.layer > 18 }.map(\.windowID)), at: Date().timeIntervalSinceReferenceDate, overviewActive: overview)
                if slide && !wasSliding { self.spaceSlideCount += 1 }
                wasSliding = slide
                let next = slide || overview || self.shortcutModifier != nil
                if next != self.active { self.active = next; onChange(next) }
                try? await Task.sleep(for: .milliseconds(next ? 16 : 40))
            }
        }
    }
    func spaceDidChange() { slides.spaceDidChange(at: Date().timeIntervalSinceReferenceDate) }
    func stop() { task?.cancel(); task = nil; active = false; shortcutModifier = nil; slides = SpaceSlideTracker() }
}

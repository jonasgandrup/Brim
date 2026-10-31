import AppKit
import SwiftUI
import ScreenCaptureKit

enum LidFoldReadiness: Equatable {
    case disabled, permissionNeeded, reduceMotion, sensorUnavailable, openLid, ready
    static func resolve(enabled: Bool, screenRecording: Bool, reduceMotion: Bool, angle: Double?) -> Self {
        if !enabled { return .disabled }
        if !screenRecording { return .permissionNeeded }
        if reduceMotion { return .reduceMotion }
        guard let angle, angle.isFinite else { return .sensorUnavailable }
        return angle < 30 ? .openLid : .ready
    }
    var message: String {
        switch self {
        case .disabled: "Turn on Lid Fold and Duo lid closing above."
        case .permissionNeeded: "Screen Recording permission is needed for Sense to fold your desktop."
        case .reduceMotion: "Paused while macOS Reduce Motion is enabled."
        case .sensorUnavailable: "Waiting for a compatible hinge sensor. Check the sensor status above."
        case .openLid: "Open the lid to your normal working angle. Sense calibrates automatically."
        case .ready: "Close the lid slowly to see the fold. Reopening reverses it."
        }
    }
}

enum LidCaptureCheck: Equatable {
    case unverified, checking, verified, failed(String)
    var title: String {
        switch self {
        case .unverified, .checking: "Checking desktop access…"
        case .verified: "Ready"
        case .failed: "Desktop capture needs attention"
        }
    }
}

struct LidSetupStatus: Equatable {
    let title: String
    let detail: String
    let ready: Bool
    init(readiness: LidFoldReadiness, capture: LidCaptureCheck) {
        ready = readiness == .ready && capture == .verified
        switch readiness {
        case .disabled: title = "Off"; detail = "Turn on Lid fold to get started."
        case .permissionNeeded: title = "Allow desktop access"; detail = "Allow Screen Recording for Sense so it can fold your desktop."
        case .reduceMotion: title = "Paused by Reduce Motion"; detail = "Turn off Reduce Motion in macOS Accessibility settings to use the fold."
        case .sensorUnavailable: title = "Checking the hinge sensor"; detail = "A compatible MacBook hinge sensor is required."
        case .openLid: title = "Open your MacBook"; detail = "Open the lid normally. Calibration is automatic."
        case .ready:
            title = capture.title
            switch capture {
            case .unverified, .checking: detail = "Checking that Sense can capture the built-in display."
            case .verified: detail = "Close the lid slowly to see the fold. Opening it reverses the effect."
            case .failed(let message): detail = message
            }
        }
    }
}

@MainActor @Observable
final class LidEffectService {
    /// Injected by the app so every check shares one permission truth (preflight or a real capture probe).
    var hasScreenAccess: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    var style: LidFoldStyle = .duo
    var angle: Double?
    var referenceAngle: Double?
    var progress: Double = 0
    private(set) var renderedProgress: Double = 0
    private var snapshotReadyAt: Date?
    var status = "Off"
    var snapshot: NSImage?
    var captureMessage: String?
    private(set) var captureCheck = LidCaptureCheck.unverified
    private var setupProbeTask: Task<Void, Never>?
    private let reader = LidAngleReader()
    private var task: Task<Void, Never>?
    private var readerCloseTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var captureAttempted = false
    private var captureRetryAfter = Date.distantPast
    private var generation = 0
    private var lastSeenAngle: Double?
    private var lastMovedAt = Date()

    func start() {
        guard task == nil else { return }
        generation += 1
        let currentGeneration = generation
        status = "Checking hinge sensor…"
        installObservers()
        let closing = readerCloseTask
        task = Task { [weak self, reader] in
            await closing?.value
            guard !Task.isCancelled else { return }
            if let error = await reader.open() {
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                self?.status = error; self?.task = nil; return
            }
            var lastAngle: Double?
            var movingUntil = Date.distantPast
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.generation == currentGeneration else { break }
                if self.suspended {
                    try? await Task.sleep(for: .milliseconds(250)); continue
                }
                if let angle = await reader.read() {
                    guard !Task.isCancelled, self.generation == currentGeneration else { break }
                    failures = 0
                    if let lastAngle, abs(angle - lastAngle) >= 0.5 { movingUntil = Date().addingTimeInterval(0.8) }
                    lastAngle = angle
                    self.update(angle: angle)
                } else {
                    failures += 1
                    if failures >= 8 {
                        self.progress = 0; self.panel?.orderOut(nil)
                        self.angle = nil; self.status = "Hinge readings unavailable. Effect paused."
                        self.snapshot = nil; self.captureAttempted = false; self.captureTask?.cancel()
                    }
                }
                try? await Task.sleep(for: .seconds(Date() < movingUntil ? 1.0 / 60 : 1.0 / 8))
            }
        }
    }
    func stop() {
        setupProbeTask?.cancel(); setupProbeTask = nil; captureCheck = .unverified
        generation += 1; task?.cancel(); task = nil
        captureTask?.cancel(); captureTask = nil
        panel?.orderOut(nil); panel = nil; progress = 0; snapshot = nil
        angle = nil; referenceAngle = nil; status = "Off"; captureAttempted = false
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        readerCloseTask = Task { [reader] in await reader.close() }
    }
    /// Verify the same real desktop capture used by the fold, without drawing an overlay.
    /// The image is discarded immediately; an API permission flag alone never means Ready.
    func verifyDesktopCapture(force: Bool = false) {
        guard task != nil, !suspended, angle != nil, hasScreenAccess(),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !AppEnvironment.isSmokeTest, setupProbeTask == nil,
              force || captureCheck == .unverified else { return }
        let ticket = generation
        captureCheck = .checking
        setupProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket { self.setupProbeTask = nil } }
            do {
                _ = try await self.desktopImage()
                guard !Task.isCancelled, self.generation == ticket, !self.suspended else { return }
                self.captureCheck = .verified; self.captureMessage = nil
            } catch {
                guard !Task.isCancelled, self.generation == ticket else { return }
                self.captureCheck = .failed(error.localizedDescription)
            }
        }
    }
    private func update(angle: Double) {
        self.angle = angle
        let now = Date()
        if lastSeenAngle.map({ abs($0 - angle) >= 1 }) ?? true { lastSeenAngle = angle; lastMovedAt = now }
        // Establish the real resting angle before drawing anything. Never start with a frozen overlay.
        referenceAngle = HingeMotion.openReference(angle: angle, previous: referenceAngle)
        if let reference = referenceAngle {
            referenceAngle = HingeMotion.settledReference(angle: angle, reference: reference, stillFor: now.timeIntervalSince(lastMovedAt))
        }
        let next = HingeMotion.progress(angle: angle, reference: referenceAngle ?? angle)
        status = "Live hinge · \(Int(angle))°"
        verifyDesktopCapture()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            progress = 0; panel?.orderOut(nil); snapshot = nil; captureAttempted = false
            captureTask?.cancel(); return
        }
        guard !AppEnvironment.isSmokeTest else { return }
        progress = next
        // Enter from an exactly flat snapshot if capture arrives after the lid has begun moving.
        // Subsequent sensor samples catch up smoothly, rather than jumping to an already folded pose.
        if let snapshotReadyAt, snapshot != nil {
            renderedProgress = next * min(1, max(0, Date().timeIntervalSince(snapshotReadyAt) / 0.12))
        } else { renderedProgress = 0 }
        let movingClosed = (referenceAngle ?? angle) - angle > 2
        if !movingClosed {
            panel?.orderOut(nil); snapshot = nil; captureAttempted = false
            captureTask?.cancel(); return
        }
        guard !suspended else { return }
        // A real desktop transform requires a captured image. Never substitute a blur-only imitation.
        guard hasScreenAccess() else {
            panel?.orderOut(nil); snapshot = nil
            captureMessage = "Enable Screen Recording for Sense in macOS System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        if panel == nil { makePanel() }
        if !captureAttempted && Date() >= captureRetryAfter { captureAttempted = true; captureDesktop() }
        if next > 0.001 && snapshot != nil { panel?.orderFrontRegardless() }
        else { panel?.orderOut(nil) }
    }
    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
    private func makePanel() {
        guard let screen = builtInScreen else { return }
        let panel = FloatingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSHostingView(rootView: LidEffectView(service: self))
        view.sizingOptions = []; panel.contentView = view; panel.setFrame(screen.frame, display: true)
        self.panel = panel
    }
    private enum CaptureFailure: LocalizedError {
        case noBuiltInDisplay
        var errorDescription: String? { "The built-in display is unavailable. Open your MacBook and try again." }
    }
    private func desktopImage() async throws -> NSImage {
        guard let screen = builtInScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { throw CaptureFailure.noBuiltInDisplay }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureFailure.noBuiltInDisplay }
        try Task.checkCancellation()
        let ownOverlayIDs = Set(NSApp.windows.filter { $0.level.rawValue >= NSWindow.Level.statusBar.rawValue }.compactMap(\.windowID))
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ownOverlayIDs.contains($0.windowID) })
        let config = SCStreamConfiguration()
        config.width = min(display.width, 2560)
        config.height = Int(Double(config.width) * Double(display.height) / Double(max(display.width, 1)))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: image, size: screen.frame.size)
    }
    private func captureDesktop() {
        let currentGeneration = generation
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.desktopImage()
                guard !Task.isCancelled, self.generation == currentGeneration, !self.suspended, hasScreenAccess() else { return }
                self.renderedProgress = 0; self.snapshotReadyAt = Date()
                self.snapshot = image; self.captureCheck = .verified; self.captureMessage = nil
                if self.progress > 0.001 { self.panel?.orderFrontRegardless() }
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.captureAttempted = false; self.captureRetryAfter = Date().addingTimeInterval(3)
                self.captureCheck = .failed(error.localizedDescription)
                self.captureMessage = "Desktop capture failed. Check the setup status above."
                self.panel?.orderOut(nil)
            }
        }
    }
    private func installObservers() {
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let locked = note.name.rawValue.hasSuffix("IsLocked")
                Task { @MainActor in self?.suspended = locked; self?.resetVisuals() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resetVisuals() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resetVisuals(); self?.panel = nil }
        })
    }
    private func resetVisuals() {
        setupProbeTask?.cancel(); setupProbeTask = nil; captureCheck = .unverified
        progress = 0; renderedProgress = 0; snapshotReadyAt = nil; referenceAngle = nil; snapshot = nil; captureAttempted = false; captureRetryAfter = .distantPast
        captureTask?.cancel(); panel?.orderOut(nil)
    }
}

private struct LidEffectView: View {
    let service: LidEffectService
    var body: some View {
        Group {
            if let snapshot = service.snapshot {
                DesktopFoldView(snapshot: snapshot, progress: service.renderedProgress, style: service.style)
            }
        }.animation(.smooth(duration: 0.09, extraBounce: 0), value: service.renderedProgress)
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

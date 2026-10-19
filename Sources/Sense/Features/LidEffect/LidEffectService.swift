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
        case .disabled: "Turn on Lid Fold & Lock and Duo lid closing above."
        case .permissionNeeded: "Screen Recording permission is needed for Sense to fold your desktop."
        case .reduceMotion: "Paused while macOS Reduce Motion is enabled."
        case .sensorUnavailable: "Waiting for a compatible hinge sensor. Check the sensor status above."
        case .openLid: "Open the lid to your normal working angle, then choose Set Open Position."
        case .ready: "Ready. Set Open Position, then close the lid more than 6° to see the vertical fold."
        }
    }
}

@MainActor @Observable
final class LidEffectService {
    var angle: Double?
    var referenceAngle: Double?
    var progress: Double = 0
    private(set) var renderedProgress: Double = 0
    private var snapshotReadyAt: Date?
    var status = "Off"
    var snapshot: NSImage?
    var captureMessage: String?
    private let reader = LidAngleReader()
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var captureAttempted = false
    private var generation = 0

    func start() {
        guard task == nil else { return }
        generation += 1
        let currentGeneration = generation
        status = "Checking hinge sensor…"
        installObservers()
        task = Task { [weak self, reader] in
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
        Task { [reader] in await reader.close() }
    }
    func calibrateOpenPosition() {
        guard let angle, angle > 30 else { return }
        referenceAngle = angle; progress = 0; panel?.orderOut(nil); snapshot = nil; captureAttempted = false
        captureTask?.cancel()
    }
    private func update(angle: Double) {
        self.angle = angle
        // Establish the real resting angle before drawing anything. Never start with a frozen overlay.
        if referenceAngle == nil || ((referenceAngle ?? 0) < 30 && angle >= 60) { referenceAngle = angle }
        let next = HingeMotion.progress(angle: angle, reference: referenceAngle ?? angle)
        status = "Live hinge · \(Int(angle))°"
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            progress = 0; panel?.orderOut(nil); snapshot = nil; captureAttempted = false
            captureTask?.cancel(); return
        }
        guard !CommandLine.arguments.contains("--smoke-test") else { return }
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
        guard CGPreflightScreenCaptureAccess() else {
            panel?.orderOut(nil); snapshot = nil
            captureMessage = "Enable Screen Recording for Sense in macOS System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        if panel == nil { makePanel() }
        if !captureAttempted { captureAttempted = true; captureDesktop() }
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
    private func captureDesktop() {
        guard let screen = builtInScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let currentGeneration = generation
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let overlayID = self?.panel?.windowNumber
                // Prewarm while the overlay is still hidden; it may not be listed as an on-screen window yet.
                let ownOverlayIDs = Set(NSApp.windows.filter { $0.level.rawValue >= NSWindow.Level.statusBar.rawValue }.map { CGWindowID($0.windowNumber) })
                let overlays = content.windows.filter { Int($0.windowID) == overlayID || ownOverlayIDs.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: overlays)
                let config = SCStreamConfiguration()
                config.width = min(display.width, 2560); config.height = Int(Double(config.width) * Double(display.height) / Double(max(display.width, 1)))
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, let self, self.generation == currentGeneration, !self.suspended, CGPreflightScreenCaptureAccess() else { return }
                self.renderedProgress = 0; self.snapshotReadyAt = Date()
                self.snapshot = NSImage(cgImage: image, size: screen.frame.size)
                self.captureMessage = nil
                if self.progress > 0.001 { self.panel?.orderFrontRegardless() }
            } catch {
                guard !Task.isCancelled else { return }
                self?.captureMessage = "Desktop capture unavailable. The depth effect stays off until Screen Recording is available."
                self?.panel?.orderOut(nil)
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
        progress = 0; referenceAngle = nil; snapshot = nil; captureAttempted = false
        captureTask?.cancel(); panel?.orderOut(nil)
    }
}

private struct LidEffectView: View {
    let service: LidEffectService
    var body: some View {
        Group {
            if let snapshot = service.snapshot {
                DesktopFoldView(snapshot: snapshot, progress: service.renderedProgress)
            }
        }.animation(.smooth(duration: 0.09, extraBounce: 0), value: service.renderedProgress)
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

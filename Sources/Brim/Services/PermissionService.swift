import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor @Observable
final class PermissionService {
    var accessibility = AXIsProcessTrusted()
    /// Asked at least once this session but still not trusted: macOS may be holding an approval from an earlier build.
    private(set) var accessibilityRequested = false
    private(set) var resettingAccessibility = false
    private var accessibilityPoll: Task<Void, Never>?
    private(set) var screenRecordingRequested = false
    var screenRecording = CGPreflightScreenCaptureAccess()
    private var probeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// CGPreflightScreenCaptureAccess can keep reporting "denied" for a signed local build that macOS shows as
    /// allowed (and that can capture). Its "denied" is never trusted on its own: a real ScreenCaptureKit query
    /// decides, and until it answers the last known state stands, so features don't flicker into "Allow…".
    func refresh() {
        accessibility = AXIsProcessTrusted()
        if CGPreflightScreenCaptureAccess() { screenRecording = true } else { probeScreenRecording() }
    }
    func probeScreenRecording() {
        guard probeTask == nil else { return }
        probeTask = Task { [weak self] in
            let usable = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.displays.isEmpty == false
            guard let self else { return }
            self.probeTask = nil
            self.screenRecording = usable
            if usable { self.pollTask?.cancel(); self.pollTask = nil }
        }
    }
    /// After the user opens the privacy pane, notice the grant without a manual refresh.
    private func pollForScreenRecording() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, !self.screenRecording else { return }
                self.refresh()
            }
        }
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        guard !accessibility else { return }
        accessibilityRequested = true
        openPrivacy("Privacy_Accessibility")
        // Notice the switch being turned on without asking the user to come back and refresh.
        accessibilityPoll?.cancel()
        accessibilityPoll = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if AXIsProcessTrusted() { self.accessibility = true; self.onAccessibilityGranted(); return }
            }
        }
    }
    /// Called once Accessibility turns on, so features waiting for it can start.
    @ObservationIgnored var onAccessibilityGranted: () -> Void = {}
    /// macOS ties an approval to the exact build it was given to. An approval from an earlier, differently
    /// signed Sense still shows as on in System Settings but no longer applies, and the switch can't fix it.
    /// Resetting removes only Sense's own entry, then asks again so the current build can be approved.
    func resetAccessibility() {
        guard !resettingAccessibility, let bundleID = Bundle.main.bundleIdentifier else { return }
        resettingAccessibility = true
        Task { [weak self] in
            let result = await ProcessRunner.run("/usr/bin/tccutil", arguments: ["reset", "Accessibility", bundleID], timeout: 10)
            guard let self else { return }
            self.resettingAccessibility = false
            if !result.succeeded { Log.app.error("Resetting Accessibility failed") }
            self.requestAccessibility()
        }
    }
    func requestScreenRecording() {
        screenRecordingRequested = true
        screenRecording = CGRequestScreenCaptureAccess()
        if !screenRecording { openPrivacy("Privacy_ScreenCapture"); pollForScreenRecording() }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

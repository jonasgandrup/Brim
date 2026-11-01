import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor @Observable
final class PermissionService {
    var accessibility = AXIsProcessTrusted()
    private var accessibilityPoll: Task<Void, Never>?
    private(set) var screenRecordingRequested = false
    var screenRecording = CGPreflightScreenCaptureAccess()
    private var probeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// What a real capture query said, once per launch. CGPreflightScreenCaptureAccess can report "denied" for a
    /// signed local build that can in fact capture, but the query itself can raise macOS's permission prompt. So it
    /// runs only after the user has pressed Allow, never just because Brim came to the front.
    private var probeResult: Bool?
    private var probeAllowed: Bool {
        get { AppEnvironment.defaults.bool(forKey: "screenCaptureProbeAllowed") }
        set { AppEnvironment.defaults.set(newValue, forKey: "screenCaptureProbeAllowed") }
    }
    func refresh() {
        accessibility = AXIsProcessTrusted()
        if CGPreflightScreenCaptureAccess() { screenRecording = true }
        else if let probeResult { screenRecording = probeResult }
        else if probeAllowed && !screenRecordingRequested { probeScreenRecording() }
        else { screenRecording = false }
    }
    private func probeScreenRecording() {
        guard probeTask == nil else { return }
        probeTask = Task { [weak self] in
            let usable = await Self.captureWorks()
            guard let self else { return }
            self.probeTask = nil; self.probeResult = usable; self.screenRecording = usable
            if !usable { self.probeAllowed = false }
        }
    }
    static func captureWorks() async -> Bool {
        (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.displays.isEmpty == false
    }
    /// macOS ties an approval to the signing identity it was given to. One from an earlier, differently signed
    /// Brim still shows as on in System Settings but no longer applies, and flipping the switch can't fix it.
    /// So asking always clears Brim's own entry first; it isn't working anyway, or nobody could press Allow.
    private func clearOldApproval(_ service: String, then ask: @escaping @MainActor () -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier else { ask(); return }
        Task {
            let result = await ProcessRunner.run("/usr/bin/tccutil", arguments: ["reset", service, bundleID], timeout: 10)
            if !result.succeeded { Log.app.error("Clearing the old approval failed") }
            ask()
        }
    }
    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { accessibility = true; return }
        clearOldApproval("Accessibility") { [weak self] in
            guard let self else { return }
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            self.accessibility = AXIsProcessTrustedWithOptions(options)
            guard !self.accessibility else { return }
            self.openPrivacy("Privacy_Accessibility")
            // Notice the switch being turned on without asking the user to come back and refresh.
            self.accessibilityPoll?.cancel()
            self.accessibilityPoll = Task { [weak self] in
                for _ in 0..<90 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    if AXIsProcessTrusted() { self.accessibility = true; self.onAccessibilityGranted(); return }
                }
            }
        }
    }
    /// Called once Accessibility turns on, so features waiting for it can start.
    @ObservationIgnored var onAccessibilityGranted: () -> Void = {}
    func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { screenRecording = true; return }
        screenRecordingRequested = true
        probeAllowed = true
        clearOldApproval("ScreenCapture") { [weak self] in
            guard let self else { return }
            self.screenRecording = CGRequestScreenCaptureAccess()
            guard !self.screenRecording else { return }
            self.openPrivacy("Privacy_ScreenCapture")
            // macOS often applies this grant only after a restart; the setup list offers one meanwhile.
            self.pollTask?.cancel()
            self.pollTask = Task { [weak self] in
                for _ in 0..<150 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, !self.screenRecording else { return }
                    self.screenRecording = CGPreflightScreenCaptureAccess()
                }
            }
        }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

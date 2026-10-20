import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor @Observable
final class PermissionService {
    var accessibility = AXIsProcessTrusted()
    private(set) var screenRecordingRequested = false
    var screenRecording = CGPreflightScreenCaptureAccess()
    private var probeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// CGPreflightScreenCaptureAccess can keep reporting "denied" in a running process after macOS
    /// shows "allowed". A real ScreenCaptureKit query is the source of truth, so ask it too.
    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        if !screenRecording { probeScreenRecording() }
    }
    func probeScreenRecording() {
        guard probeTask == nil else { return }
        probeTask = Task { [weak self] in
            let usable = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.displays.isEmpty == false
            guard let self else { return }
            self.probeTask = nil
            if usable { self.screenRecording = true; self.pollTask?.cancel(); self.pollTask = nil }
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
        openPrivacy("Privacy_Accessibility")
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

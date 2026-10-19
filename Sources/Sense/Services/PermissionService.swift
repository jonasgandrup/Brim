import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor @Observable
final class PermissionService {
    var accessibility = AXIsProcessTrusted()
    var screenRecording = CGPreflightScreenCaptureAccess()
    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func requestScreenRecording() {
        screenRecording = CGRequestScreenCaptureAccess()
        if !screenRecording { openPrivacy("Privacy_ScreenCapture") }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

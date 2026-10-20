import AppKit
import Intents
import Darwin

/// Decides when the island should step aside on its own: while a Focus is on, or while the screen is being
/// shared or mirrored. Focus uses Apple's Focus Status API (you approve it once). Sharing has no public
/// "is being shared" flag, so it is detected from what macOS and conferencing apps expose: mirrored
/// displays and the helper processes that only run during a share. Apps that share without either
/// (for example a browser-based meeting) can't be detected.
enum SharingDetection {
    /// Processes that run only while a share is live: Zoom's share host and macOS Screen Sharing.
    static let shareProcessNames: Set<String> = ["CptHost", "screensharingd"]
    static func isSharing(processNames: Set<String>, displaysMirrored: Bool) -> Bool {
        displaysMirrored || !processNames.isDisjoint(with: shareProcessNames)
    }
    static func runningProcessNames() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var names: Set<String> = []
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(String(cString: buffer)) }
        }
        return names
    }
    static func displaysMirrored() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}

@MainActor @Observable final class AutoHideMonitor {
    private(set) var reason: String?
    private(set) var focusAuthorized = false
    private(set) var focusDenied = false
    private var watchFocus = false
    private var watchSharing = false
    private var task: Task<Void, Never>?
    @ObservationIgnored private var onChange: (String?) -> Void = { _ in }

    func configure(focus: Bool, sharing: Bool, onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
        let focusWasOff = !watchFocus
        watchFocus = focus; watchSharing = sharing
        guard focus || sharing else { stop(); return }
        if focus && focusWasOff { requestFocusAccess() }
        guard task == nil else { evaluate(); return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.evaluate()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        evaluate()
    }
    func stop() {
        task?.cancel(); task = nil; watchFocus = false; watchSharing = false
        if reason != nil { reason = nil; onChange(nil) }
    }
    private func requestFocusAccess() {
        let center = INFocusStatusCenter.default
        refreshAuthorization(center.authorizationStatus)
        guard center.authorizationStatus == .notDetermined else { return }
        center.requestAuthorization { [weak self] status in
            Task { @MainActor in self?.refreshAuthorization(status); self?.evaluate() }
        }
    }
    private func refreshAuthorization(_ status: INFocusStatusAuthorizationStatus) {
        focusAuthorized = status == .authorized
        focusDenied = status == .denied || status == .restricted
    }
    func evaluate() {
        var next: String?
        if watchFocus, INFocusStatusCenter.default.authorizationStatus == .authorized {
            focusAuthorized = true
            if INFocusStatusCenter.default.focusStatus.isFocused == true { next = "Focus is on" }
        }
        if next == nil, watchSharing,
           SharingDetection.isSharing(processNames: SharingDetection.runningProcessNames(), displaysMirrored: SharingDetection.displaysMirrored()) {
            next = "Screen is shared"
        }
        guard next != reason else { return }
        reason = next; onChange(next)
    }
}

import AppKit
import SwiftUI

@MainActor @Observable
final class LockScreenService {
    var error: String?
    var locked = false
    private var observers: [NSObjectProtocol] = []
    private var preferences: Preferences?
    private weak var notch: NotchController?
    private var panel: NSPanel?
    private var lockTask: Task<Void, Never>?
    func configure(preferences: Preferences, notch: NotchController) {
        self.preferences = preferences; self.notch = notch
        guard observers.isEmpty else { return }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] notification in
                let locked = notification.name.rawValue.hasSuffix("IsLocked")
                Task { @MainActor in
                    guard let self else { return }
                    self.locked = locked
                    if locked { self.panel?.orderOut(nil); self.panel = nil }
                    else if self.preferences?.lockEnabled == true { self.notch?.showFeedback("Welcome back.", symbol: "lock.open") }
                }
            })
        }
    }
    func lock() {
        guard preferences?.lockEnabled == true else { return }
        guard AXIsProcessTrusted() else { error = "Allow Accessibility in Permissions so Sense can send macOS’s Lock Screen shortcut. You can always lock with Control–Command–Q."; return }
        guard lockTask == nil else { return }
        error = nil
        showTransition()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            // Hand off to macOS. No credentials or authentication are handled by Sense.
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false)
            down?.flags = [.maskControl, .maskCommand]; up?.flags = [.maskControl, .maskCommand]
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(800))
            self?.panel?.orderOut(nil); self?.panel = nil; self?.lockTask = nil
        }
    }
    private func showTransition() {
        guard let screen = NSScreen.main else { return }
        let panel = FloatingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: LockTransition())
        self.panel = panel; panel.orderFrontRegardless()
    }
}

@MainActor @Observable
final class LockTransitionState { var appeared = false }

struct LockTransition: View {
    private let state = LockTransitionState()
    var body: some View {
        ZStack {
            Color.black.opacity(state.appeared ? 0.3 : 0)
            Image(systemName: state.appeared ? "lock.fill" : "lock.open.fill")
                .contentTransition(.symbolEffect(.replace)).font(.system(size: 42, weight: .light))
                .foregroundStyle(.white).padding(35).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
                .scaleEffect(state.appeared ? 1 : 0.9).opacity(state.appeared ? 1 : 0)
        }.onAppear { withAnimation(.easeInOut(duration: 0.35)) { state.appeared = true } }
    }
}

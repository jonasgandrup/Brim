import AppKit
import SwiftUI
import Carbon

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
                    else if self.preferences?.lockEnabled == true { self.notch?.showFeedback(String(localized: "Welcome back."), symbol: "lock.open") }
                }
            })
        }
    }
    func lock() {
        guard preferences?.lockEnabled == true else { return }
        guard AXIsProcessTrusted() else { error = String(localized: "Allow Accessibility in Permissions so Sense can send macOS’s Lock Screen shortcut. You can always lock with Control–Command–Q."); return }
        guard lockTask == nil else { return }
        error = nil
        showTransition()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            // Hand off to macOS. No credentials or authentication are handled by Sense.
            let source = CGEventSource(stateID: .hidSystemState)
            // Menu shortcuts match the character, so find the key that types "q" on this keyboard (A on AZERTY).
            let key = LockShortcutKey.keyCode(for: "q") ?? CGKeyCode(kVK_ANSI_Q)
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
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

/// Physical key codes are positional; characters depend on the active keyboard layout.
enum LockShortcutKey {
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        // Command held: layouts such as "Dvorak – QWERTY ⌘" switch to QWERTY for shortcuts.
        let modifiers = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1).lowercased() == character { return CGKeyCode(code) }
            }
            return nil
        }
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

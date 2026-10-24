import AppKit
import SwiftUI
import ApplicationServices
import ScreenCaptureKit

@MainActor @Observable
final class SwitcherWindow: Identifiable {
    let id = UUID()
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
    let frame: CGRect
    let minimized: Bool
    var thumbnail: NSImage?
    init(element: AXUIElement, app: NSRunningApplication, title: String, frame: CGRect, minimized: Bool) {
        self.element = element; self.app = app; self.title = title; self.frame = frame; self.minimized = minimized
    }
}

enum SwitcherFilter {
    /// Matches each word of the query against the window title or app name, ignoring case and accents.
    static func matches(query: String, title: String, app: String) -> Bool {
        let words = query.split(separator: " ").map(String.init)
        let haystack = (title + " " + app)
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

enum SwitcherSelection {
    static func next(_ current: Int, count: Int, backwards: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (current + (backwards ? -1 : 1) + count) % count
    }
}

@MainActor @Observable
final class WindowSwitcher {
    var windows: [SwitcherWindow] = []
    /// Type-to-search: `/` or F while the switcher is open. The modifier can then be released.
    private(set) var query = ""
    private(set) var searching = false
    var shown: [SwitcherWindow] {
        query.isEmpty ? windows : windows.filter { SwitcherFilter.matches(query: query, title: $0.title, app: $0.app.localizedName ?? "") }
    }
    var onVisibilityChanged: (Bool) -> Void = { _ in }
    var selected = 0
    var visible = false
    var status = "Off"
    private var panel: NSPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureTask: Task<Void, Never>?
    private var preferences: Preferences?
    private var swallowedTab = false
    private var awaitingPresentation = false
    private var activateWhenReady = false
    private var pendingSteps = 0
    /// Same source of truth as the rest of the app, so a stale preflight flag can't hide thumbnails.
    var hasScreenAccess: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// Most recently activated first, so one Tab always reaches the previous app.
    private var recentApps: [pid_t] = []
    private var activationObserver: NSObjectProtocol?
    private func noteActivated(_ pid: pid_t) { recentApps.removeAll { $0 == pid }; recentApps.insert(pid, at: 0); if recentApps.count > 64 { recentApps.removeLast() } }

    func configure(preferences: Preferences) {
        self.preferences = preferences
        guard preferences.switcherEnabled else { stop(); status = "Off"; return }
        guard AXIsProcessTrusted() else { stop(); status = "Accessibility permission required"; return }
        guard tap == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, recentApps.isEmpty { noteActivated(front) }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.noteActivated(pid) }
            }
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let handled = MainActor.assumeIsolated {
                let controller = Unmanaged<WindowSwitcher>.fromOpaque(context).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { status = "Could not intercept shortcut. Check Accessibility and Input Monitoring."; return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = "Ready"
    }
    func stop() {
        awaitingPresentation = false; activateWhenReady = false; pendingSteps = 0
        dismiss(activate: false)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; swallowedTab = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            dismiss(activate: false)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let modifier: CGEventFlags = switch preferences?.shortcut ?? .command {
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        }
        let otherHeld = [CGEventFlags.maskCommand, .maskAlternate, .maskControl].filter { $0 != modifier }.contains { event.flags.contains($0) }
        let held = event.flags.contains(modifier)
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            if !held && !searching {
                if awaitingPresentation { activateWhenReady = true }
                else if visible { Task { @MainActor in self.dismiss(activate: true) } }
            }
            return false
        }
        if type == .keyUp && code == 48 && swallowedTab { swallowedTab = false; return true }
        if type == .keyUp && visible && (searching || Self.actionKeys.contains(code)) { return true }
        guard type == .keyDown else { return false }
        if code == 48 && held && !otherHeld {
            let backwards = event.flags.contains(.maskShift)
            if awaitingPresentation { pendingSteps += backwards ? -1 : 1 }
            else if !visible {
                awaitingPresentation = true; activateWhenReady = false; pendingSteps = 0
                // Accessibility IPC and capture setup must never run inside an event-tap callback.
                Task { @MainActor in
                    guard self.awaitingPresentation else { return }
                    await self.present(backwards: backwards)
                    self.awaitingPresentation = false
                    if self.activateWhenReady { self.dismiss(activate: true) }
                }
            } else { move(backwards: backwards) }
            swallowedTab = true
            return true
        }
        if visible && searching { return handleSearchKey(code: code, event: event) }
        if visible && held {
            switch code {
            case 44, 3: searching = true; query = ""; selected = 0; return true   // "/" or F
            case 12: closeSelected(app: true); return true                          // Q quits the app
            case 13: closeSelected(app: false); return true                         // W closes the window
            case 4: hideSelectedApp(); return true                                  // H hides the app
            default: break
            }
        }
        if awaitingPresentation && code == 53 { awaitingPresentation = false; activateWhenReady = false; return true }
        guard visible else { return false }
        switch code {
        case 53: dismiss(activate: false); return true
        case 36: dismiss(activate: true); return true
        case 123, 126: move(backwards: true); return true
        case 124, 125: move(backwards: false); return true
        default: return false
        }
    }
    private static let actionKeys: Set<Int64> = [44, 3, 12, 13, 4]
    private func handleSearchKey(code: Int64, event: CGEvent) -> Bool {
        switch code {
        case 53:
            // Escape clears the search first, then closes the switcher.
            if query.isEmpty { dismiss(activate: false) } else { query = ""; selected = 0 }
        case 36: dismiss(activate: true)
        case 51: if !query.isEmpty { query.removeLast(); selected = 0 }
        case 48, 125, 124: move(backwards: event.flags.contains(.maskShift))
        case 126, 123: move(backwards: true)
        default:
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &characters)
            let typed = String(utf16CodeUnits: characters, count: length)
            if let first = typed.unicodeScalars.first, first.value >= 32, first.value != 127 { query += typed; selected = 0 }
        }
        return true
    }
    private func closeSelected(app: Bool) {
        let list = shown
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
        if app {
            target.app.terminate()
            windows.removeAll { $0.app.processIdentifier == target.app.processIdentifier }
        } else {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(target.element, kAXCloseButtonAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(unsafeDowncast(value, to: AXUIElement.self), kAXPressAction as CFString)
            }
            windows.removeAll { $0.id == target.id }
        }
        afterRemoval()
    }
    private func hideSelectedApp() {
        let list = shown
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
        target.app.hide()
        windows.removeAll { $0.app.processIdentifier == target.app.processIdentifier }
        afterRemoval()
    }
    private func afterRemoval() {
        if windows.isEmpty { dismiss(activate: false); return }
        selected = min(selected, max(0, shown.count - 1))
    }
    nonisolated private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    nonisolated static func rank(_ pid: pid_t, frontmost: pid_t?, recent: [pid_t]) -> Int {
        if pid == frontmost { return 0 }
        return (recent.firstIndex(of: pid) ?? recent.count) + 1
    }
    /// Plain window data read off the main thread; Accessibility calls can stall on unresponsive apps.
    struct RawWindow: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let title: String?
        let frame: CGRect
        let minimized: Bool
    }
    nonisolated private static func scan(pids: [pid_t], includeMinimized: Bool) -> [RawWindow] {
        var result: [RawWindow] = []
        for pid in pids {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.06)
            guard let elements = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for element in elements {
                let subrole = attribute(element, kAXSubroleAttribute) as? String
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let minimized = attribute(element, kAXMinimizedAttribute) as? Bool ?? false
                if minimized && !includeMinimized { continue }
                var origin = CGPoint.zero; var size = CGSize.zero
                if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &origin)
                }
                if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
                }
                guard size.width > 80, size.height > 50 else { continue }
                result.append(RawWindow(element: element, pid: pid, title: attribute(element, kAXTitleAttribute) as? String,
                                        frame: CGRect(origin: origin, size: size), minimized: minimized))
            }
        }
        return result
    }
    private func enumerate() async -> [SwitcherWindow] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { Self.rank($0.processIdentifier, frontmost: frontmost, recent: recentApps) < Self.rank($1.processIdentifier, frontmost: frontmost, recent: recentApps) }
        let pids = apps.map(\.processIdentifier)
        let includeMinimized = preferences?.includeMinimized != false
        let raw = await Task.detached(priority: .userInitiated) { Self.scan(pids: pids, includeMinimized: includeMinimized) }.value
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        return raw.compactMap { window in
            guard let app = byPID[window.pid] else { return nil }
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Untitled"
            return SwitcherWindow(element: window.element, app: app, title: title, frame: window.frame, minimized: window.minimized)
        }
    }
    func present(backwards: Bool = false) async {
        guard AXIsProcessTrusted() else { status = "Accessibility permission required"; return }
        let found = await enumerate()
        // Escape (or the tap being torn down) while windows were loading cancels the presentation.
        guard awaitingPresentation else { return }
        windows = found
        guard !windows.isEmpty else { return }
        selected = backwards ? windows.count - 1 : min(1, windows.count - 1)
        if !windows.isEmpty { selected = ((selected + pendingSteps) % windows.count + windows.count) % windows.count }
        visible = true; onVisibilityChanged(true)
        if activateWhenReady { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { dismiss(activate: false); return }
        let width = min(screen.visibleFrame.width - 64, 1020)
        let panel = FloatingPanel(contentRect: NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - 170, width: width, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SwitcherView(controller: self))
        self.panel = panel; panel.orderFrontRegardless()
        captureTask?.cancel()
        captureTask = Task { await loadThumbnails() }
    }
    private func loadThumbnails() async {
        guard hasScreenAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            for window in windows {
                guard !Task.isCancelled, visible else { return }
                // Public AX has no window ID. Match pid, title and bounds; omit ambiguous thumbnails.
                let matches = content.windows.filter { candidate in
                    candidate.owningApplication?.processID == window.app.processIdentifier &&
                    candidate.title == window.title && abs(candidate.frame.width - window.frame.width) < 3 && abs(candidate.frame.minX - window.frame.minX) < 3 && abs(candidate.frame.minY - window.frame.minY) < 3
                }
                guard matches.count == 1, let capturedWindow = matches.first, !window.minimized else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
                let configuration = SCStreamConfiguration()
                let scale = min(520 / max(window.frame.width, 1), 320 / max(window.frame.height, 1))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                    guard !Task.isCancelled else { return }
                    window.thumbnail = NSImage(cgImage: image, size: .zero)
                }
            }
        } catch { status = "Thumbnails unavailable. Window switching still works." }
    }
    func move(backwards: Bool) { selected = SwitcherSelection.next(selected, count: shown.count, backwards: backwards) }
    func choose(_ index: Int) { selected = index; dismiss(activate: true) }
    func dismiss(activate: Bool) {
        let list = shown
        let target = activate && list.indices.contains(selected) ? list[selected] : nil
        query = ""; searching = false
        visible = false; onVisibilityChanged(false); panel?.orderOut(nil); panel = nil; captureTask?.cancel(); windows.removeAll()
        guard let target else { return }
        if target.minimized { AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        target.app.activate()
        AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}

struct SwitcherView: View {
    @Bindable var controller: WindowSwitcher
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Windows").font(.headline)
                Text("\(controller.shown.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.searching {
                    Label(controller.query.isEmpty ? "Type to search" : controller.query, systemImage: "magnifyingglass")
                        .font(.callout).foregroundStyle(controller.query.isEmpty ? .secondary : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary.opacity(0.5), in: Capsule())
                    Text("↩ to switch · esc to clear").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("← → navigate · / search · Q quit · W close · H hide · esc dismiss").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(controller.shown.enumerated()), id: \.element.id) { index, window in
                            Button { controller.choose(index) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                                        if let thumbnail = window.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
                                        else {
                                            VStack(spacing: 8) {
                                                if let icon = window.app.icon { Image(nsImage: icon).resizable().frame(width: 40, height: 40) }
                                                Text(window.minimized ? "Minimized" : "Preview unavailable").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.frame(height: 145)
                                    HStack(spacing: 7) {
                                        if let icon = window.app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                        Text(window.app.localizedName ?? "Application").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    }
                                    Text(window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(12).frame(width: 234)
                                    .background(controller.selected == index ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(controller.selected == index ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: controller.selected == index ? 2 : 1))
                            }.buttonStyle(.plain).id(index)
                        }
                    }.padding(2)
                }
                .onChange(of: controller.selected) { _, selection in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection, anchor: .center) } }
            }
        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

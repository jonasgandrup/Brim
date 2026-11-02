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
    /// The window server's number for this window, which pairs it exactly with its screen image.
    let windowID: CGWindowID?
    var thumbnail: NSImage?
    init(element: AXUIElement, app: NSRunningApplication, title: String, frame: CGRect, minimized: Bool, windowID: CGWindowID? = nil) {
        self.element = element; self.app = app; self.title = title; self.frame = frame; self.minimized = minimized; self.windowID = windowID
    }
}

/// Accessibility has no public window number, so previews used to be matched by title and position,
/// which fails whenever an app reports a different title to each API. `_AXUIElementGetWindow` is the
/// long-standing call window managers use for this; it's looked up at runtime and simply skipped if absent.
enum AXWindowNumber {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let function: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }
    static func of(_ element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}

enum ThumbnailMatch {
    struct Candidate: Equatable { let windowID: CGWindowID; let pid: pid_t; let title: String?; let frame: CGRect }
    /// Exact window number first. Otherwise the same app's window with the closest bounds, preferring a
    /// matching title, and only when it's clearly the one (within a few points, and no tie).
    static func pick(windowID: CGWindowID?, pid: pid_t, title: String, frame: CGRect, from candidates: [Candidate]) -> CGWindowID? {
        if let windowID, candidates.contains(where: { $0.windowID == windowID }) { return windowID }
        func distance(_ other: CGRect) -> CGFloat {
            abs(other.minX - frame.minX) + abs(other.minY - frame.minY) + abs(other.width - frame.width) + abs(other.height - frame.height)
        }
        let close = candidates.filter { $0.pid == pid && distance($0.frame) < 12 }
        let titled = close.filter { $0.title == title }
        let pool = titled.isEmpty ? close : titled
        let ranked = pool.sorted { distance($0.frame) < distance($1.frame) }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, distance(ranked[1].frame) - distance(best.frame) < 1 { return nil }
        return best.windowID
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
    /// One Tab reaches the previous window, unless the first in the list isn't the one you're already in.
    static func initial(count: Int, firstIsCurrent: Bool, backwards: Bool) -> Int {
        guard count > 0 else { return 0 }
        return backwards ? count - 1 : (firstIsCurrent ? min(1, count - 1) : 0)
    }
}

enum SwitcherOrder {
    /// Front to back, whichever app each window belongs to. Windows that aren't on screen, like minimized ones,
    /// follow in the order their apps were last used. Returns positions in the original list.
    static func positions(windowIDs: [CGWindowID?], appRanks: [Int], stack: [CGWindowID: Int]) -> [Int] {
        windowIDs.indices.sorted { first, second in
            switch (windowIDs[first].flatMap { stack[$0] }, windowIDs[second].flatMap { stack[$0] }) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): appRanks[first] != appRanks[second] ? appRanks[first] < appRanks[second] : first < second
            }
        }
    }
    /// Reading window numbers and their stacking order needs no permission.
    nonisolated static func currentStack() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let normal = list.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        return Dictionary(normal.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The panel is as wide as its windows, like the system's app switcher, and scrolls only past the screen's width.
enum SwitcherLayout {
    static let tile = CGSize(width: 150, height: 94)
    static let tileInset: CGFloat = 7
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 8
    static let labelHeight: CGFloat = 30
    /// A lone window still needs room to name itself.
    static let minimumWidth: CGFloat = 300
    static func panelSize(count: Int, available: CGFloat) -> CGSize {
        let items = CGFloat(max(0, count))
        let row = items * (tile.width + tileInset * 2) + max(0, items - 1) * spacing + padding * 2
        return CGSize(width: min(available, max(minimumWidth, row)), height: padding + tile.height + tileInset * 2 + labelHeight)
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
    var status = String(localized: "Off")
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
        guard preferences.switcherEnabled else { stop(); status = String(localized: "Off"); return }
        guard AXIsProcessTrusted() else { stop(); status = String(localized: "Accessibility permission required"); return }
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
        guard let tap else { status = String(localized: "Could not intercept shortcut. Check Accessibility and Input Monitoring."); return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = String(localized: "Ready")
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
        refitPanel()
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
        let windowID: CGWindowID?
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
                                        frame: CGRect(origin: origin, size: size), minimized: minimized, windowID: AXWindowNumber.of(element)))
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
        let (raw, stack) = await Task.detached(priority: .userInitiated) { (Self.scan(pids: pids, includeMinimized: includeMinimized), SwitcherOrder.currentStack()) }.value
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let ranks = raw.map { Self.rank($0.pid, frontmost: frontmost, recent: recentApps) }
        return SwitcherOrder.positions(windowIDs: raw.map(\.windowID), appRanks: ranks, stack: stack).compactMap { position in
            let window = raw[position]
            guard let app = byPID[window.pid] else { return nil }
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? String(localized: "Untitled")
            return SwitcherWindow(element: window.element, app: app, title: title, frame: window.frame, minimized: window.minimized, windowID: window.windowID)
        }
    }
    func present(backwards: Bool = false) async {
        guard AXIsProcessTrusted() else { status = String(localized: "Accessibility permission required"); return }
        let found = await enumerate()
        // Escape (or the tap being torn down) while windows were loading cancels the presentation.
        guard awaitingPresentation else { return }
        windows = found
        guard !windows.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let firstIsCurrent = windows.first.map { $0.app.processIdentifier == frontmost && !$0.minimized } ?? false
        selected = SwitcherSelection.initial(count: windows.count, firstIsCurrent: firstIsCurrent, backwards: backwards)
        if !windows.isEmpty { selected = ((selected + pendingSteps) % windows.count + windows.count) % windows.count }
        visible = true; onVisibilityChanged(true)
        if activateWhenReady { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { dismiss(activate: false); return }
        let panel = makePanel(on: screen)
        self.panel = panel; panel.orderFrontRegardless()
        captureTask?.cancel()
        captureTask = Task { await loadThumbnails() }
    }
    private func makePanel(on screen: NSScreen) -> NSPanel {
        let size = SwitcherLayout.panelSize(count: windows.count, available: screen.visibleFrame.width - 64)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let panel = FloatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: SwitcherView(controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
    /// Closing a window narrows the panel around its middle, so the row stays where you're looking.
    private func refitPanel() {
        guard let panel, let screen = panel.screen else { return }
        let size = SwitcherLayout.panelSize(count: windows.count, available: screen.visibleFrame.width - 64)
        panel.setFrame(NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }
    private func loadThumbnails() async {
        guard hasScreenAccess() else { return }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { status = String(localized: "Thumbnails unavailable. Window switching still works."); return }
        let candidates = content.windows.map {
            ThumbnailMatch.Candidate(windowID: $0.windowID, pid: $0.owningApplication?.processID ?? 0, title: $0.title, frame: $0.frame)
        }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        // The selected window and its neighbours first, then the rest, four at a time.
        let order = windows.indices.sorted { abs($0 - selected) < abs($1 - selected) }
        let jobs: [(SwitcherWindow, SCWindow)] = order.compactMap { index in
            let window = windows[index]
            guard !window.minimized,
                  let id = ThumbnailMatch.pick(windowID: window.windowID, pid: window.app.processIdentifier, title: window.title, frame: window.frame, from: candidates),
                  let captured = byID[id] else { return nil }
            return (window, captured)
        }
        var start = 0
        while start < jobs.count, !Task.isCancelled, visible {
            let batch = jobs[start..<min(jobs.count, start + 4)].map { job in Task { await self.capture(job.1, into: job.0) } }
            for task in batch { await task.value }
            start += 4
        }
    }
    private func capture(_ captured: SCWindow, into window: SwitcherWindow) async {
        let frame = window.frame
        let configuration = SCStreamConfiguration()
        // Twice the tile size so previews stay sharp on Retina displays.
        let scale = min(2, min(SwitcherLayout.tile.width / max(frame.width, 1), SwitcherLayout.tile.height / max(frame.height, 1)) * 2)
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: captured), configuration: configuration),
              !Task.isCancelled, visible else { return }
        window.thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
    func move(backwards: Bool) { selected = SwitcherSelection.next(selected, count: shown.count, backwards: backwards) }
    func choose(_ index: Int) { selected = index; dismiss(activate: true) }
    func dismiss(activate: Bool) {
        let list = shown
        let target = activate && list.indices.contains(selected) ? list[selected] : nil
        query = ""; searching = false
        visible = false; onVisibilityChanged(false); panel?.orderOut(nil); panel = nil; captureTask?.cancel(); windows.removeAll()
        if let target { bringForward(target) }
    }
    /// Since macOS 14 an app in the background can have `activate()` declined, so the app is also asked to come
    /// forward through Accessibility. It can then put its own last window on top, so that's checked once it settles.
    private func bringForward(_ target: SwitcherWindow) {
        let element = target.element
        let app = target.app
        func raise() {
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if app.isHidden { app.unhide() }
        if target.minimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        raise()
        app.activate()
        Task { @MainActor in
            for delay in [80, 200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { continue }
                if let focused = Self.attribute(application, kAXFocusedWindowAttribute), CFEqual(focused, element) { return }
                raise()
            }
        }
    }
}

/// Windows speak for themselves, as apps do in the system's switcher: a soft highlight and one name, the selected one's.
/// The keys are listed in Settings rather than on a panel that's only seen for a moment.
struct SwitcherView: View {
    @Bindable var controller: WindowSwitcher
    private var selectedTitle: String? {
        controller.shown.indices.contains(controller.selected) ? controller.shown[controller.selected].title : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SwitcherLayout.spacing) {
                            ForEach(Array(controller.shown.enumerated()), id: \.element.id) { index, window in
                                Button { controller.choose(index) } label: {
                                    SwitcherTile(window: window, selected: controller.selected == index)
                                }.buttonStyle(.plain).id(index)
                            }
                        }.frame(minWidth: geometry.size.width)
                    }
                }.frame(height: SwitcherLayout.tile.height + SwitcherLayout.tileInset * 2)
                .onAppear { proxy.scrollTo(controller.selected, anchor: .center) }
                .onChange(of: controller.selected) { _, selection in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection, anchor: .center) } }
            }
            caption
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(height: SwitcherLayout.labelHeight)
        }
        .padding([.horizontal, .top], SwitcherLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
    @ViewBuilder private var caption: some View {
        if controller.searching {
            Label(controller.query.isEmpty ? String(localized: "Type to search") : controller.query, systemImage: "magnifyingglass")
                .foregroundStyle(controller.query.isEmpty ? .secondary : .primary)
        } else if let selectedTitle {
            Text(verbatim: selectedTitle)
        }
    }
}

private struct SwitcherTile: View {
    let window: SwitcherWindow
    let selected: Bool
    private var appName: String { window.app.localizedName ?? String(localized: "Application") }
    var body: some View {
        Group {
            if let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = window.app.icon {
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28).offset(x: 6, y: 6)
                        }
                    }
            } else if let icon = window.app.icon {
                // No preview to show, or a minimized window: the app's icon says enough, and fades when it's put away.
                Image(nsImage: icon).resizable().frame(width: 52, height: 52).opacity(window.minimized ? 0.6 : 1)
            }
        }
        .frame(width: SwitcherLayout.tile.width, height: SwitcherLayout.tile.height)
        .padding(SwitcherLayout.tileInset)
        .background(selected ? Color.primary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(appName), \(window.title)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if DEBUG
/// The real panel with sample windows, so the smoke test can show it without Accessibility access or anyone's window titles.
extension WindowSwitcher {
    func exportPreviews(to directory: URL) async -> [String] {
        guard let screen = NSScreen.main else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard !apps.isEmpty else { return [] }
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func samples(_ count: Int, previews: Bool) -> [SwitcherWindow] {
            (0..<count).map { index in
                let app = apps[index % apps.count]
                let window = SwitcherWindow(element: element, app: app, title: "Sample window \(index + 1)", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), minimized: !previews && index == 2)
                if previews {
                    let tint = NSColor(hue: (CGFloat(index) * 0.17).truncatingRemainder(dividingBy: 1), saturation: 0.25, brightness: 0.9, alpha: 1)
                    window.thumbnail = NSImage(size: NSSize(width: 150, height: 94), flipped: false) { rect in tint.setFill(); rect.fill(); return true }
                }
                return window
            }
        }
        var rendered: [String] = []
        func capture(_ name: String, _ list: [SwitcherWindow], selected index: Int, searching isSearching: Bool = false, query text: String = "") async {
            windows = list; selected = index; searching = isSearching; query = text; visible = true
            let panel = makePanel(on: screen)
            self.panel = panel; panel.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(350))
            if let data = await SmokeCapture.png(of: panel), (try? data.write(to: directory.appendingPathComponent(name))) != nil { rendered.append(name) }
            panel.orderOut(nil); self.panel = nil; visible = false; windows.removeAll(); query = ""; searching = false; selected = 0
        }
        await capture("switcher-previews.png", samples(5, previews: true), selected: 1)
        await capture("switcher-one-window.png", samples(1, previews: true), selected: 0)
        await capture("switcher-icons-only.png", samples(5, previews: false), selected: 1)
        await capture("switcher-many-windows.png", samples(24, previews: true), selected: 23)
        await capture("switcher-searching.png", samples(5, previews: true), selected: 0, searching: true, query: "Sample")
        return rendered
    }
}
#endif

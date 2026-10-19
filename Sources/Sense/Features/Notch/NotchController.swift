import SwiftUI
import AppKit
import Observation
import ScreenCaptureKit

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandPanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

enum IslandTab { case music, files, clipboard, timer }

/// Camera clearance is measured separately from the visible activity on either side.
struct IslandLayout {
    var cutoutWidth: CGFloat
    var menuBarHeight: CGFloat
    var hasHardwareNotch: Bool
    var compactSize: CGSize {
        hasHardwareNotch
            ? CGSize(width: cutoutWidth + 104, height: menuBarHeight)
            : CGSize(width: 196, height: 38)
    }
    var expandedSize: CGSize { CGSize(width: max(408, compactSize.width), height: headerHeight + 202) }
    var headerHeight: CGFloat { hasHardwareNotch ? menuBarHeight : 38 }
    func idleHoverFrame(on screen: CGRect) -> CGRect {
        let width = hasHardwareNotch ? cutoutWidth + 24 : compactSize.width
        let height = hasHardwareNotch ? headerHeight + 8 : compactSize.height
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - topGap - height, width: width, height: height)
    }
    var topGap: CGFloat { hasHardwareNotch ? 0 : 8 }
    func frame(on screen: CGRect, expanded: Bool) -> CGRect {
        let size = expanded ? expandedSize : compactSize
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - topGap - size.height, width: size.width, height: size.height)
    }
}

enum IslandHitRegion {
    static func contains(_ point: CGPoint, frame: CGRect, radius: CGFloat, roundedTop: Bool) -> Bool {
        guard frame.contains(point) else { return false }
        let r = min(radius, min(frame.width, frame.height) / 2)
        let lower = point.y < frame.minY + r
        let upper = roundedTop && point.y > frame.maxY - r
        guard lower || upper else { return true }
        let centerY = lower ? frame.minY + r : frame.maxY - r
        let centerX: CGFloat
        if point.x < frame.minX + r { centerX = frame.minX + r }
        else if point.x > frame.maxX - r { centerX = frame.maxX - r }
        else { return true }
        return pow(point.x - centerX, 2) + pow(point.y - centerY, 2) <= r * r
    }
}

enum IslandPresentation: Equatable {
    case hidden, compact, expanded
    static func resolve(expanded: Bool, mediaEnabled: Bool, playing: Bool, hasSource: Bool, hasFeedback: Bool) -> Self {
        if expanded { return .expanded }
        return hasFeedback || (mediaEnabled && playing && hasSource) ? .compact : .hidden
    }
}

@MainActor @Observable
final class NotchController {
    var expanded = false
    let shelf = FileShelf()
    var selectedTab: IslandTab = .music { didSet { if oldValue != selectedTab { transitionPane() } } }
    private(set) var displayedTab: IslandTab = .music
    private(set) var paneOpacity = 1.0
    private(set) var surfaceReveal = 1.0
    private var systemMenuDepth = 0
    private var paneTask: Task<Void, Never>?
    private func transitionPane() {
        paneTask?.cancel()
        guard expanded, !desktopTransition, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            displayedTab = selectedTab; paneOpacity = 1; return
        }
        withAnimation(.easeOut(duration: 0.07)) { paneOpacity = 0 }
        paneTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled, let self else { return }
            self.displayedTab = self.selectedTab
            withAnimation(.easeOut(duration: 0.12)) { self.paneOpacity = 1 }
        }
    }
    var shelfSelected: Bool {
        get { selectedTab == .files }
        set { selectedTab = newValue ? .files : .music }
    }
    let clipboard = ClipboardShelf()
    let countdown = IslandTimer()
    let clock = ClockTools()
    private var powerFeedback = PowerFeedbackTracker()
    private(set) var dropTargeted = false
    private(set) var fileDragActive = false
    private var dragPollTimer: Timer?
    private var dragStartChangeCount = 0
    var feedback: String?
    var feedbackSymbol = "checkmark.circle"
    private(set) var layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 32, hasHardwareNotch: true)
    private var panel: NSPanel?
    private var displayFrame: CGRect?
    private var idleHideTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var observationGeneration = 0
    private var observingActivity = false
    private(set) var rapidTabChangesSettle = false
    private(set) var transitionsKeepPanelStable = true
    private(set) var pointerExitClosesPromptly = false
    private(set) var idleHoverOpensIsland = false
    private(set) var nativeSnapshotCount = 0
    private var preferences: Preferences?
    private var status: SystemStatus?
    private var media: MediaService?
    private var mediaVisible = false
    private struct MediaVisibilityInput: Equatable { let enabled: Bool; let playing: Bool; let hasSource: Bool }
    private var lastMediaInput: MediaVisibilityInput?
    private var mediaExitTask: Task<Void, Never>?
    private var onOpenSettings: () -> Void = {}
    private var pointerInside = false
    private var previewPointer: CGPoint?
    private(set) var hoverCheckDiagnostics: [[String: Bool]] = []
    private var suspended = false
    private(set) var desktopTransition = false
    private(set) var preparingAfterTransition = false
    private(set) var surfaceAnimationsSuppressed = false
    private let transitionMonitor = DesktopTransitionMonitor()
    private var systemSwitcherActive = false
    private var senseSwitcherActive = false
    private var switcherOverlayActive: Bool { systemSwitcherActive || senseSwitcherActive }
    private var desktopRestoreTask: Task<Void, Never>?
    private var desktopRestoreGate = DesktopRestoreGate()
    private(set) var desktopTransitionHidesIsland = false
    private(set) var systemSwitcherObserved = false
    private(set) var systemSwitcherHidIsland = false
    private var lastExternalPreference: Bool?
    var panelFrame: CGRect? { panel?.frame }
    var spaceSlideCount: Int { transitionMonitor.spaceSlideCount }
    var trackpadDeviceCount: Int { transitionMonitor.trackpadDeviceCount }
    var observedContactGestures: Int { transitionMonitor.observedContactGestures }
    var transitionDiagnostics: [String: Bool] {
        ["systemOverlay": systemSwitcherActive, "senseSwitcher": senseSwitcherActive,
         "transition": desktopTransition, "suspended": suspended, "panelVisible": panel?.isVisible ?? false]
    }
    var presentation: IslandPresentation {
        if desktopTransition { return .hidden }
        if expanded { return .expanded }
        if fileDragActive || !shelf.files.isEmpty || !clipboard.pins.isEmpty || countdown.active || clock.active || media?.sleepTimer.schedule != nil { return .compact }
        return .resolve(expanded: expanded, mediaEnabled: preferences?.mediaEnabled == true,
                 playing: mediaVisible, hasSource: media?.source != nil, hasFeedback: feedback != nil)
    }
    var compactTab: IslandTab {
        if countdown.active || clock.active { return .timer }
        if selectedTab == .files && !shelf.files.isEmpty { return .files }
        if selectedTab == .clipboard && !clipboard.pins.isEmpty { return .clipboard }
        if preferences?.mediaEnabled == true && mediaVisible { return .music }
        if !shelf.files.isEmpty { return .files }
        if !clipboard.pins.isEmpty { return .clipboard }
        return .music
    }
    var surfaceFrame: CGRect? {
        guard presentation != .hidden, let displayFrame else { return nil }
        return layout.frame(on: displayFrame, expanded: expanded)
    }
    var ignoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }


    func start(preferences: Preferences, status: SystemStatus, media: MediaService, onOpenSettings: @escaping () -> Void = {}) {
        self.preferences = preferences; self.status = status; self.media = media; self.onOpenSettings = onOpenSettings
        status.onPowerSample = { [weak self] sample in self?.receivePower(sample) }
        receivePower(PowerSample(percent: status.battery, externalPower: status.charging))
        clock.onAlarm = { [weak self] in
            guard let self else { return }
            self.selectedTab = .timer
            self.showFeedback("Alarm", symbol: "alarm")
        }
        countdown.onFinish = { [weak self] in
            guard let self else { return }
            self.selectedTab = .timer
            self.showFeedback("Timer finished", symbol: "timer")
            if !CommandLine.arguments.contains("--smoke-test") { NSSound.beep() }
        }
        if observers.isEmpty {
            for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.systemMenuDepth = max(0, self.systemMenuDepth + delta)
                        self.collapseTask?.cancel()
                        if self.systemMenuDepth == 0 {
                            self.updateInteraction(scheduleHover: false)
                            if self.expanded && !self.pointerInside { self.collapseAfterDelay() }
                        }
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuild() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.transitionMonitor.spaceDidChange()
                    self?.hideForDesktopTransition(settleDelay: .milliseconds(900))
                }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                Task { @MainActor in
                    guard let self, !self.desktopTransition, !self.preparingAfterTransition else { return }
                    // Switching ordinary apps must not retract/recreate the camera cover.
                    // Space gestures and the actual switcher own suppression separately.
                    if self.expanded { self.setExpanded(false) }
                }
            })
            // Cosmetic visibility only; loginwindow remains responsible for security.
            for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
                observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                    let locked = note.name.rawValue.hasSuffix("IsLocked")
                    Task { @MainActor in
                        self?.suspended = locked
                        if locked { self?.setExpanded(false); self?.panel?.orderOut(nil) }
                        else { self?.updateInteraction(scheduleHover: false) }
                    }
                })
            }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.expanded, !self.shelf.systemUIActive, self.systemMenuDepth == 0 else { return }
                    if !self.containsPointer(NSEvent.mouseLocation) { self.setExpanded(false) }
                }
            }
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .swipe, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.trackMouseEvent(event) }
            }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .swipe, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.trackMouseEvent(event)
                    if (event.type == .leftMouseDown || event.type == .rightMouseDown), self?.expanded == true, self?.shelf.systemUIActive == false, self?.systemMenuDepth == 0,
                       self?.containsPointer(event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation) != true { self?.setExpanded(false) }
                }
                return event
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    if self?.shelf.actions.previewVisible == true { return false }
                    if event.keyCode == 53, self?.expanded == true { self?.setExpanded(false); return true }
                    return false
                }
                return handled ? nil : event
            }
        }
        if panel == nil || lastExternalPreference != preferences.showOnExternal { rebuild() }
        lastExternalPreference = preferences.showOnExternal
        transitionMonitor.start { [weak self] active in
            self?.setSystemSwitcherActive(active)
        }
        syncMediaVisibility()
        if !observingActivity { observingActivity = true; observeActivity() }
        updateInteraction(scheduleHover: false)
    }
    private func observeActivity() {
        let generation = observationGeneration
        withObservationTracking {
            _ = preferences?.mediaEnabled
            _ = media?.playing
            _ = media?.source
            _ = media?.sleepTimer.schedule
            _ = media?.holdingScrubber
            _ = shelf.files
            _ = shelf.systemUIActive
            _ = clipboard.pins
            _ = countdown.state
            _ = clock.stopwatch.running
            _ = clock.ringing
            _ = preferences?.chargingFeedback
            _ = preferences?.chargeTarget
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observingActivity, self.observationGeneration == generation else { return }
                if let status = self.status { self.receivePower(PowerSample(percent: status.battery, externalPower: status.charging)) }
                self.syncMediaVisibility()
                self.updateInteraction()
                if !self.shelf.systemUIActive && self.expanded && !self.pointerInside { self.collapseAfterDelay() }
                self.observeActivity()
            }
        }
    }
    private func syncMediaVisibility() {
        let input = MediaVisibilityInput(enabled: preferences?.mediaEnabled == true, playing: media?.playing == true, hasSource: media?.source != nil)
        guard input != lastMediaInput else { return }
        lastMediaInput = input
        mediaExitTask?.cancel()
        guard preferences?.mediaEnabled == true, media?.source != nil else { mediaVisible = false; return }
        if media?.playing == true { mediaVisible = true; return }
        // A short pause grace prevents track changes from flashing the physical cutout.
        mediaExitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.mediaVisible = false; self?.updateInteraction()
        }
    }
    private func containsPointer(_ point: CGPoint) -> Bool {
        if presentation == .hidden {
            guard !desktopTransition, let displayFrame else { return false }
            return layout.idleHoverFrame(on: displayFrame).contains(point)
        }
        guard let frame = surfaceFrame else { return false }
        return IslandHitRegion.contains(point, frame: frame, radius: expanded ? 34 : layout.compactSize.height / 2, roundedTop: !layout.hasHardwareNotch)
    }
    private func syncPanelVisibility() {
        guard let panel else { return }
        if suspended || desktopTransition || preparingAfterTransition {
            idleHideTask?.cancel(); idleHideTask = nil; panel.alphaValue = 0; panel.orderOut(nil)
        } else if presentation != .hidden {
            idleHideTask?.cancel(); idleHideTask = nil
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        } else if panel.isVisible && idleHideTask == nil {
            // Finish the opaque 140 ms retraction, then remove the unnecessary software camera cover.
            idleHideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self, self.presentation == .hidden else { return }
                self.panel?.orderOut(nil); self.idleHideTask = nil
            }
        }
    }
    private func updateInteraction(scheduleHover: Bool = true, at location: CGPoint? = nil) {
        syncPanelVisibility()
        guard let panel else { return }
        let inside = !suspended && !desktopTransition && !preparingAfterTransition && containsPointer(location ?? previewPointer ?? NSEvent.mouseLocation)
        // The window never resizes. Transparent space outside the animated surface passes through.
        panel.ignoresMouseEvents = presentation == .hidden || !inside
        if scheduleHover && (inside != pointerInside || (inside && !expanded && hoverTask == nil && preferences?.hoverToExpand == true)) { hover(inside) }
        else { pointerInside = inside }
    }
    func stop() {
        idleHideTask?.cancel(); idleHideTask = nil
        shelf.actions.closePreview()
        systemMenuDepth = 0
        observingActivity = false; observationGeneration += 1
        transitionMonitor.stop(); systemSwitcherActive = false; senseSwitcherActive = false
        desktopRestoreTask?.cancel(); desktopRestoreTask = nil; desktopRestoreGate.reset(); desktopTransition = false; preparingAfterTransition = false; surfaceAnimationsSuppressed = false; surfaceReveal = 1
        paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1
        mediaExitTask?.cancel(); mediaVisible = false; lastMediaInput = nil
        dragPollTimer?.invalidate(); dragPollTimer = nil; fileDragActive = false; dropTargeted = false
        collapseTask?.cancel(); hoverTask?.cancel(); feedbackTask?.cancel()
        panel?.orderOut(nil); panel = nil; displayFrame = nil; expanded = false; pointerInside = false; suspended = false; feedback = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }; globalMouseMonitor = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }; localMouseMonitor = nil
    }
    func rebuild() {
        idleHideTask?.cancel(); idleHideTask = nil
        panel?.orderOut(nil); panel = nil; expanded = false; pointerInside = false
        guard let preferences, let status, let media, preferences.notchEnabled else { return }
        let notchedScreen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notchedScreen ?? (preferences.showOnExternal ? NSScreen.main : nil) else { return }
        displayFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        let cutout: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cutout = max(160, right.minX - left.maxX)
        } else { cutout = 190 }
        layout = IslandLayout(cutoutWidth: cutout, menuBarHeight: max(28, screen.safeAreaInsets.top), hasHardwareNotch: hasNotch)
        let panel = IslandPanel(contentRect: layout.frame(on: screen.frame, expanded: true), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.animationBehavior = .none
        // Status-bar level keeps the narrow activity wings visible above the menu-bar background.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false; panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true; panel.ignoresMouseEvents = true
        self.panel = panel
        let hosting = NSHostingView(rootView: IslandView(controller: self, preferences: preferences, status: status, media: media))
        // SwiftUI's intrinsic minimum must not enlarge the collapsed NSPanel.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(layout.frame(on: screen.frame, expanded: true), display: true)
        updateInteraction(scheduleHover: false)
    }
    func setExpanded(_ value: Bool) {
        collapseTask?.cancel(); hoverTask?.cancel(); hoverTask = nil
        guard panel != nil, !(desktopTransition || preparingAfterTransition) || !value, value != expanded else { return }
        // One SwiftUI animation owns the shape, content and opacity. No NSWindow animator or I/O here.
        if !value { paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1 }
        expanded = value
        updateInteraction(scheduleHover: false)
    }
    func hover(_ inside: Bool) {
        pointerInside = inside
        collapseTask?.cancel(); hoverTask?.cancel(); hoverTask = nil
        if inside && !desktopTransition && !preparingAfterTransition && !suspended && preferences?.hoverToExpand == true && !expanded {
            // A brief dwell avoids opening the island when crossing the menu bar.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }; self?.hoverTask = nil; self?.setExpanded(true)
            }
        } else if !inside && expanded { collapseAfterDelay() }
    }
    private func collapseAfterDelay(seconds: Double = 0.06) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.pointerInside == false, self?.dropTargeted == false, self?.shelf.systemUIActive == false, self?.media?.holdingScrubber != true, self?.systemMenuDepth == 0 else { return }
            self?.setExpanded(false)
        }
    }
    func setSwitcherOverlayActive(_ active: Bool) {
        guard senseSwitcherActive != active else { return }
        senseSwitcherActive = active
        hideForDesktopTransition()
    }
    private func setSystemSwitcherActive(_ active: Bool) {
        systemSwitcherActive = active
        hideForDesktopTransition(settleDelay: active ? .milliseconds(350) : .milliseconds(300))
        if active {
            systemSwitcherObserved = true
            systemSwitcherHidIsland = desktopTransition && panel?.isVisible == false
        }
    }
    /// Native transient behavior excludes the panel from Mission Control. Hide immediately for
    /// observable swipe/Space/app changes too, then restore at the physical camera after settling.
    func hideForDesktopTransition(settleDelay: Duration = .milliseconds(350)) {
        desktopRestoreTask?.cancel(); collapseTask?.cancel(); hoverTask?.cancel(); hoverTask = nil
        paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1; surfaceReveal = 0
        surfaceAnimationsSuppressed = true; preparingAfterTransition = false
        desktopTransition = true; expanded = false; pointerInside = false
        panel?.ignoresMouseEvents = true; panel?.alphaValue = 0; panel?.orderOut(nil)
        let components = settleDelay.components
        let delay = Double(components.seconds) + Double(components.attoseconds) / 1e18
        desktopRestoreGate.extend(at: ProcessInfo.processInfo.systemUptime, delay: delay)
        let remaining = desktopRestoreGate.remaining(at: ProcessInfo.processInfo.systemUptime)
        desktopRestoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self, !self.switcherOverlayActive else { return }
            self.desktopRestoreGate.reset()
            // Prepare the compact model while the native window remains fully hidden.
            self.preparingAfterTransition = true; self.desktopTransition = false
            self.panel?.contentView?.layoutSubtreeIfNeeded()
            self.panel?.contentView?.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(34))
            guard !Task.isCancelled, !self.switcherOverlayActive, !self.desktopTransition else { return }
            self.preparingAfterTransition = false
            self.updateInteraction(scheduleHover: false)
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
                self.surfaceAnimationsSuppressed = false
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.14)) { self.surfaceReveal = 1 }
            }
        }
    }
    private func trackMouseEvent(_ event: NSEvent) {
        guard systemMenuDepth == 0 else { return }
        if event.type == .swipe || (event.type == .scrollWheel && !containsPointer(NSEvent.mouseLocation) && event.hasPreciseScrollingDeltas &&
            abs(event.scrollingDeltaX) > 3 && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5) {
            hideForDesktopTransition(); return
        }
        if event.type == .leftMouseDown {
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            startDragPolling()
        } else if event.type == .leftMouseDragged {
            startDragPolling()
        } else if event.type == .leftMouseUp {
            endFileDrag()
        }
        updateInteraction()
    }
    private func startDragPolling() {
        guard dragPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFileDrag() }
        }
        dragPollTimer = timer
        // Native drag sessions run in event-tracking mode; polling must survive that mode.
        RunLoop.main.add(timer, forMode: .common)
    }
    private func pollFileDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { endFileDrag(); return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragStartChangeCount,
              board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        if !fileDragActive { fileDragActive = true }
        updateInteraction()
        guard let displayFrame else { return }
        let target = layout.frame(on: displayFrame, expanded: false).insetBy(dx: -22, dy: -14)
        if target.contains(NSEvent.mouseLocation) { setDropTargeted(true) }
    }
    private func endFileDrag() {
        dragPollTimer?.invalidate(); dragPollTimer = nil
        fileDragActive = false; dropTargeted = false
        updateInteraction(scheduleHover: false)
        if expanded && !pointerInside { collapseAfterDelay() }
    }
    func setDropTargeted(_ targeted: Bool, clipboard: Bool = false) {
        dropTargeted = targeted
        if targeted { selectedTab = clipboard ? .clipboard : .files; setExpanded(true) }
        else if !pointerInside { collapseAfterDelay() }
    }
    func finishFileDrop(clipboard: Bool = false) {
        dropTargeted = false; fileDragActive = false; selectedTab = clipboard ? .clipboard : .files
        // The shelf stays open only while hovered; retained references survive collapse and Space changes.
        updateInteraction(scheduleHover: false)
        if !pointerInside { collapseAfterDelay() }
    }
    func openTimerFromMenu() { selectedTab = .timer; openFromMenu() }
    func openClipboardFromMenu() { selectedTab = .clipboard; openFromMenu() }
    func pinClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            shelf.add(urls); selectedTab = .files
        } else { clipboard.pin(); selectedTab = .clipboard }
        openFromMenu()
    }
    private func receivePower(_ sample: PowerSample) {
        guard let preferences else { return }
        let event = powerFeedback.receive(sample, target: preferences.chargeTarget)
        guard !CommandLine.arguments.contains("--smoke-test"), preferences.chargingFeedback, !expanded, !fileDragActive, let event else { return }
        switch event {
        case .connected(let percent): showFeedback("Charging · \(percent)%", symbol: "battery.100percent.bolt")
        case .targetReached(let target): showFeedback("Battery reached \(target)%", symbol: "battery.100percent")
        }
    }
    func openShelfFromMenu() { shelfSelected = true; openFromMenu() }
    func openFromMenu() { setExpanded(true); collapseAfterDelay(seconds: 5) }
    func openSettings() { setExpanded(false); onOpenSettings() }
    func connectMedia() {
        preferences?.mediaEnabled = true
        media?.start()
    }
    func showFeedback(_ text: String, symbol: String) {
        guard preferences?.notchEnabled == true else { return }
        feedbackTask?.cancel(); feedback = text; feedbackSymbol = symbol; setExpanded(true)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
            if self?.pointerInside == false { self?.setExpanded(false) }
        }
    }
    func verifyIdleHover() async -> Bool {
        for _ in 0..<40 {
            if !desktopTransition { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        var check = transitionDiagnostics
        check["hoverEnabled"] = preferences?.hoverToExpand == true
        defer { previewPointer = nil }
        if let displayFrame {
            let target = layout.idleHoverFrame(on: displayFrame)
            // Keep the test's pointer source stable if the user moves their real mouse during capture.
            previewPointer = CGPoint(x: target.midX, y: target.minY + 2)
            check["targetInside"] = containsPointer(previewPointer!)
            updateInteraction()
        }
        try? await Task.sleep(for: .milliseconds(100))
        let opened = expanded && panel?.isVisible == true && panel?.alphaValue == 1
        check["opened"] = opened; check["transitionAfterHover"] = desktopTransition
        hoverCheckDiagnostics.append(check)
        previewPointer = nil
        hover(false); setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        return opened
    }
    func verifyFileActions() async -> [String: Bool] {
        let urls = ["Contents/Info.plist", "Contents/Resources/Sense.icns"].map { Bundle.main.bundleURL.appendingPathComponent($0) }
        shelf.add(urls); shelf.select(Set(urls)); openShelfFromMenu()
        previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        try? await Task.sleep(for: .milliseconds(500))
        func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            if let match = view as? T { return match }
            for child in view.subviews { if let match = findView(type, in: child) { return match } }
            return nil
        }
        var check: [String: Bool] = [:]
        let collection = findView(ShelfCollectionView.self, in: panel?.contentView)
        check["nativeCollectionShowsFiles"] = collection?.numberOfItems(inSection: 0) == 2
        check["multipleSelection"] = collection?.selectionIndexPaths.count == 2
        if let collection, let panel, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
            collection.keyDown(with: event)
        }
        try? await Task.sleep(for: .milliseconds(500))
        check["quickLookWindowVisible"] = shelf.actions.previewVisible
        check["quickLookHasSelectedItems"] = shelf.actions.previewItemCount == 2
        check["quickLookRetainsIslandHold"] = shelf.systemUIActive
        check["spaceOpensQuickLook"] = shelf.actions.previewVisible && shelf.actions.previewItemCount == 2 && shelf.systemUIActive
        shelf.actions.closePreview()
        check["previewClosesCleanly"] = !shelf.actions.previewVisible && !shelf.systemUIActive
        openShelfFromMenu()
        try? await Task.sleep(for: .milliseconds(400))
        if let button = findView(NSButton.self, in: panel?.contentView), button.identifier?.rawValue == "Sense.FileShare",
           let coordinator = button.target as? FileShareButton.Coordinator {
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            if let window = button.window {
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
            check["nativeSharePickerOpens"] = coordinator.servicesPrepared && coordinator.picker != nil && shelf.systemUIActive
            coordinator.close()
            try? await Task.sleep(for: .milliseconds(300))
            check["shareCancelReleasesIsland"] = !shelf.systemUIActive
        } else { check["nativeSharePickerOpens"] = false }
        shelf.clear(); previewPointer = nil; selectedTab = .music; hover(false); setExpanded(false)
        try? await Task.sleep(for: .milliseconds(300))
        return check
    }
    private func capturePanel(named name: String, in directory: URL) async -> Bool {
        guard let panel else { return false }
        var data: Data?
        // This API exposes only our own capturable windows; no Screen Recording grant is requested.
        if #available(macOS 14.4, *), presentation != .hidden {
            if let content = try? await SCShareableContent.currentProcess,
               let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(panel.frame.width * 2)
                configuration.height = Int(panel.frame.height * 2)
                configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) {
                    data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    nativeSnapshotCount += 1
                }
            }
        }
        if data == nil, let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        guard let data else { return false }
        do { try data.write(to: directory.appendingPathComponent(name)); return true }
        catch { return false }
    }
    func exportMediaPreview(_ snapshot: SystemMediaSnapshot, to directory: URL) async -> String? {
        for _ in 0..<50 {
            if !desktopTransition { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !desktopTransition, snapshot.hasMedia, let panel, let status, let originalView = panel.contentView else { return nil }
        let suite = "Sense.MediaPreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let previewPreferences = Preferences(defaults: defaults); previewPreferences.mediaEnabled = true
        let readOnlyMedia = MediaService(); readOnlyMedia.apply(snapshot)
        await readOnlyMedia.refreshPlayers()
        let hosting = NSHostingView(rootView: IslandView(controller: self, preferences: previewPreferences, status: status, media: readOnlyMedia))
        hosting.sizingOptions = []
        let originalFrame = panel.frame
        panel.contentView = hosting; panel.setFrame(originalFrame, display: true)
        let name = "now-playing-live.png"
        var captured = false
        for _ in 0..<4 {
            if desktopTransition || preparingAfterTransition {
                try? await Task.sleep(for: .milliseconds(500)); continue
            }
            selectedTab = .music; setExpanded(true)
            previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            try? await Task.sleep(for: .milliseconds(500))
            guard expanded, displayedTab == .music, paneOpacity == 1, surfaceReveal == 1, !desktopTransition else { continue }
            let exported = await capturePanel(named: name, in: directory)
            if exported && expanded && !desktopTransition && surfaceReveal == 1 { captured = true; break }
        }
        if !captured { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        readOnlyMedia.stop()
        panel.contentView = originalView; panel.setFrame(originalFrame, display: true)
        previewPointer = nil; hover(false); setExpanded(false)
        defaults.removePersistentDomain(forName: suite)
        try? await Task.sleep(for: .milliseconds(250))
        return captured ? name : nil
    }
    func exportPreview(to directory: URL) async -> [String] {
        guard let panel else { return [] }
        var result: [String] = []
        let initialFrame = panel.frame
        idleHoverOpensIsland = await verifyIdleHover()
        for preview in 0..<15 {
            let isExpanded = preview != 0 && (preview < 10 || preview >= 12)
            feedback = nil
            selectedTab = preview >= 8 ? .timer : (preview >= 4 ? .clipboard : (preview >= 2 ? .files : .music))
            if preview == 3 {
                shelf.add([Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")])
            }
            if preview == 5 {
                clipboard.add(.text("Pinned note for the rendering check"))
                clipboard.add(.link(URL(string: "https://developer.apple.com")!))
                if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Sense.icns")),
                   let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { clipboard.add(.image(png)) }
            }
            if preview == 6 { clipboard.clear(); selectedTab = .timer }
            if preview == 7 { selectedTab = .timer; countdown.start() }
            if preview == 8 { countdown.pause() }
            if preview == 9 { countdown.cancel(); feedback = "Charging feedback preview"; feedbackSymbol = "battery.100percent.bolt" }
            if preview == 10 { shelf.clear(); selectedTab = .music; countdown.start() }
            if preview == 11 { countdown.cancel(); clipboard.add(.text("Compact clipboard check")); selectedTab = .music }
            if preview == 12 { clipboard.clear(); selectedTab = .timer; clock.mode = .stopwatch }
            if preview == 13 { clock.toggleStopwatch() }
            if preview == 14 { clock.resetStopwatch(); clock.mode = .alarm }
            setExpanded(isExpanded)
            previewPointer = isExpanded ? surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) } : CGPoint(x: -10000, y: -10000)
            try? await Task.sleep(for: .milliseconds(650))
            let extras = [4: "clipboard-empty.png", 5: "clipboard-pins.png", 6: "timer-ready.png", 7: "timer-running.png", 8: "timer-paused.png", 9: "charging-preview.png", 10: "timer-compact.png", 11: "clipboard-compact.png", 12: "stopwatch-ready.png", 13: "stopwatch-running.png", 14: "alarm-ready.png"]
            let name = extras[preview] ?? (preview == 3 ? "file-shelf-items.png" : (preview == 2 ? "file-shelf-empty.png" :
                (isExpanded ? "island-expanded.png" : (presentation == .hidden ? "island-idle.png" : "island-compact.png"))))
            if await capturePanel(named: name, in: directory) { result.append(name) }
        }
        clock.mode = .timer
        feedback = nil; countdown.cancel(); clipboard.clear(); shelf.add([Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")]); selectedTab = .files; previewPointer = nil
        setSwitcherOverlayActive(true)
        try? await Task.sleep(for: .milliseconds(420))
        let stayedHidden = desktopTransition && !panel.isVisible && panel.alphaValue == 0
        setSwitcherOverlayActive(false)
        hideForDesktopTransition(settleDelay: .milliseconds(120))
        desktopTransitionHidesIsland = stayedHidden && presentation == .hidden && panel.ignoresMouseEvents && !panel.isVisible
        try? await Task.sleep(for: .milliseconds(450))
        desktopTransitionHidesIsland = desktopTransitionHidesIsland && !desktopTransition && panel.isVisible
        shelf.clear(); shelfSelected = false
        for _ in 0..<3 {
            setExpanded(false)
            try? await Task.sleep(for: .milliseconds(50))
            setExpanded(true)
            try? await Task.sleep(for: .milliseconds(50))
        }
        setExpanded(true)
        previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        for tab: IslandTab in [.files, .music, .clipboard, .timer, .files] {
            selectedTab = tab
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(250))
        rapidTabChangesSettle = displayedTab == selectedTab && selectedTab == .files && paneOpacity == 1 && panel.frame == initialFrame
        previewPointer = nil
        hover(false)
        try? await Task.sleep(for: .milliseconds(160))
        pointerExitClosesPromptly = !expanded
        setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        transitionsKeepPanelStable = panel.frame == initialFrame
        return result
    }
}

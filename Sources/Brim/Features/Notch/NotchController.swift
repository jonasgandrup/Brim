import SwiftUI
import AppKit
import Observation
import CoreAudio

extension NSWindow {
    /// The window server's ID, or nil before the window has one. `windowNumber` is negative until a
    /// window is first shown, and converting that to `CGWindowID` traps.
    var windowID: CGWindowID? { windowNumber > 0 ? CGWindowID(exactly: windowNumber) : nil }
}

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandPanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

enum IslandTab { case music, files, clipboard, timer, battery, transfers }

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
    func surfaceSize(for presentation: IslandPresentation, reveal: Double = 1, notice: Bool = false) -> CGSize {
        let camera = CGSize(width: cutoutWidth, height: menuBarHeight)
        let target = presentation == .expanded ? (notice ? noticeSize : expandedSize) : (presentation == .hidden && hasHardwareNotch ? camera : compactSize)
        guard hasHardwareNotch else { return target }
        let progress = min(1, max(0, reveal.isFinite ? reveal : 1))
        return CGSize(width: camera.width + (target.width - camera.width) * progress,
                      height: camera.height + (target.height - camera.height) * progress)
    }
    var expandedSize: CGSize { CGSize(width: max(408, compactSize.width), height: headerHeight + 202) }
    /// A line of news only needs a line's worth of island, as on iPhone.
    var noticeSize: CGSize { CGSize(width: max(340, compactSize.width), height: headerHeight + Self.noticeContentHeight + 18) }
    static let noticeContentHeight: CGFloat = 44
    static let bubbleGap: CGFloat = 6
    var headerHeight: CGFloat { hasHardwareNotch ? menuBarHeight : 38 }
    func idleHoverFrame(on screen: CGRect) -> CGRect {
        // Exactly the camera housing: browser tabs and menus sit right beside and below it.
        let width = hasHardwareNotch ? cutoutWidth : compactSize.width
        let height = hasHardwareNotch ? headerHeight : compactSize.height
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - topGap - height, width: width, height: height)
    }
    var topGap: CGFloat { hasHardwareNotch ? 0 : 8 }
    func frame(on screen: CGRect, expanded: Bool, notice: Bool = false) -> CGRect {
        let size = expanded ? (notice ? noticeSize : expandedSize) : compactSize
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

/// Tells a pointer resting on the island from one passing through or brushing its edge on the way to a tab.
/// The rest timer restarts whenever the pointer really moves, and once the island has opened and closed
/// it takes leaving and coming back to open it again.
struct HoverIntent {
    static let dwell = Duration.milliseconds(300)
    static let stillRadius: CGFloat = 10
    private var anchor: CGPoint?
    private var spent = false
    /// True when the rest timer should start over from this point.
    mutating func moved(to point: CGPoint) -> Bool {
        guard !spent else { return false }
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= Self.stillRadius { return false }
        anchor = point
        return true
    }
    mutating func spend() { anchor = nil; spent = true }
    mutating func left() { anchor = nil; spent = false }
}

enum IslandPresentation: Equatable {
    case hidden, compact, expanded
    static func resolve(expanded: Bool, mediaEnabled: Bool, playing: Bool, hasSource: Bool, hasFeedback: Bool) -> Self {
        if expanded { return .expanded }
        return hasFeedback || (mediaEnabled && playing && hasSource) ? .compact : .hidden
    }
}

/// Where the island is in hiding for, and coming back from, a Space swipe, Mission Control or a switcher.
/// One value instead of separate flags, so "hidden" and "preparing" can never both be true.
enum DesktopTransitionPhase: Equatable {
    /// Normal operation.
    case settled
    /// Hidden while the desktop moves.
    case hidden
    /// Still hidden; SwiftUI lays out the compact island before it reappears.
    case preparing
    /// Visible again; the reveal spring runs once surface animations resume.
    case revealing
}

/// A brief compact-only readout, like the iPhone's volume indicator: an icon on one side, a level on the other.
struct IslandHUD: Equatable {
    var symbol: String
    var level: Double?
    var tint: Color = .white
    var label: String
    /// Draws a battery and its percentage instead of the symbol and level.
    var battery: Int?
    var charging = false
}

/// Selects the display whose window the user is working in, from on-screen window bounds.
/// Bounds need no Screen Recording permission; titles and contents are never read.
enum ActiveDisplay {
    static func frontWindowBounds(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { continue }
            return rect
        }
        return nil
    }
    /// Converts a Quartz window rectangle (top-left origin) to AppKit space and picks the display it covers most.
    static func frame(for windowBounds: CGRect, in frames: [CGRect]) -> CGRect? {
        guard let primary = frames.first else { return nil }
        let flipped = CGRect(x: windowBounds.minX, y: primary.maxY - windowBounds.maxY, width: windowBounds.width, height: windowBounds.height)
        let best = frames.max { $0.intersection(flipped).area < $1.intersection(flipped).area }
        return best.flatMap { $0.intersects(flipped) ? $0 : nil }
    }
    static func current() -> NSScreen? {
        let screens = NSScreen.screens
        if let app = NSWorkspace.shared.frontmostApplication, let bounds = frontWindowBounds(pid: app.processIdentifier),
           let frame = frame(for: bounds, in: screens.map(\.frame)) { return screens.first { $0.frame == frame } }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Where a dragged file lands: the shelf (left half) or AirDrop (right half).
enum DropZone: Equatable {
    case shelf, airDrop
    static func at(x: CGFloat, width: CGFloat, airDropAvailable: Bool) -> Self {
        airDropAvailable && x > width / 2 ? .airDrop : .shelf
    }
}

/// Trackpad gestures on the compact island, in the direction the fingers move whatever the scrolling setting.
enum IslandGesture {
    /// Natural scrolling flips the deltas; this undoes that so "up" and "left" mean the fingers.
    static func fingers(dx: CGFloat, dy: CGFloat, inverted: Bool) -> (right: CGFloat, up: CGFloat) {
        inverted ? (dx, -dy) : (-dx, dy)
    }
    static let skipTravel: CGFloat = 50
    /// Swiping left goes to the next track, as you'd swipe a card away; right goes back.
    static func skip(rightTravel: CGFloat) -> String? {
        rightTravel <= -skipTravel ? "next track" : rightTravel >= skipTravel ? "previous track" : nil
    }
    static func volume(_ current: Double, up: CGFloat, precise: Bool) -> Double {
        min(1, max(0, current + Double(up) * (precise ? 0.004 : 0.03)))
    }
}

@MainActor @Observable
final class NotchController {
    /// Every path that collapses the island ends a keyboard session, so no key stays captured.
    var expanded = false { didSet { if !expanded { keys.stop() } } }
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
    let countdown = IslandTimer(defaults: AppEnvironment.persistentDefaults)
    let clock = ClockTools()
    let calendar = CalendarPeek()
    let transfers = TransferTracker()
    let activities = ScriptActivities()
    private let moments = SystemMoments()
    let sensors = SensorActivity()
    let bluetooth = BluetoothBatteries()
    private let brightness = BrightnessMonitor()
    let brightnessControl = BrightnessControl()
    private var powerFeedback = PowerFeedbackTracker()
    private(set) var dropTargeted = false
    /// Whether the drag over the island carries files (which can go to the shelf or AirDrop) or clipboard content.
    private(set) var dropIsFiles = false
    private(set) var dropZone = DropZone.shelf
    var airDropAvailable: Bool { NSSharingService(named: .sendViaAirDrop) != nil }
    private(set) var fileDragActive = false
    private var dragPollTimer: Timer?
    private var dragStartChangeCount = 0

    // MARK: Feedback

    var feedback: String?
    var feedbackSymbol = "checkmark.circle"
    var feedbackTint: Color = .green
    /// Optional rich content for the current feedback: a screenshot preview.
    private(set) var feedbackImage: NSImage?
    private(set) var feedbackURL: URL?
    /// An accessory that just connected, shown as a card with a battery ring per part, like AirPods on iPhone.
    private(set) var feedbackDevice: BluetoothDevice?
    /// A single button under the message, such as "Join" for a meeting that's about to start.
    private(set) var feedbackAction: (title: String, url: URL)?
    private var feedbackTask: Task<Void, Never>?
    private(set) var hud: IslandHUD?
    private var hudTask: Task<Void, Never>?

    private let screenshots = ScreenshotWatcher()
    private(set) var layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 32, hasHardwareNotch: true)
    private(set) var panel: NSPanel?
    private(set) var displayFrame: CGRect?
    private var idleHideTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pressureMonitor: Any?
    private var observationGeneration = 0
    private var observingActivity = false
    private(set) var preferences: Preferences?
    private(set) var status: SystemStatus?
    private var media: MediaService?
    private var mediaVisible = false
    /// The app in front, so its own Now Playing can step aside. Brim counts too: its windows don't show the player.
    private(set) var frontApp: String?
    private struct MediaVisibilityInput: Equatable { let enabled: Bool; let playing: Bool; let hasSource: Bool; let stepsAside: Bool }
    private var lastMediaInput: MediaVisibilityInput?
    private var mediaExitTask: Task<Void, Never>?
    private var onOpenSettings: () -> Void = {}
    private var pointerInside = false
    private var hoverIntent = HoverIntent()
    /// Replaces the real pointer location while the smoke test drives the island.
    var previewPointer: CGPoint?
    private var suspended = false
#if DEBUG
    var smoke = NotchSmokeChecks()
#endif

    // MARK: Presentation mode

    /// Hidden by the menu bar's Presentation Mode (manual) or automatically (Focus, screen sharing).
    private(set) var manualPresentation = false
    private(set) var autoHideReason: String?
    var presentationMode: Bool { manualPresentation || autoHideReason != nil }
    func setPresentationMode(_ enabled: Bool) {
        guard enabled != manualPresentation else { return }
        manualPresentation = enabled
        presentationChanged()
    }
    func setAutoHide(reason: String?) {
        guard reason != autoHideReason else { return }
        autoHideReason = reason
        presentationChanged()
    }
    private func presentationChanged() {
        toolOpenTask?.cancel()
        hoverTask?.cancel(); hoverTask = nil
        collapseTask?.cancel()
        if presentationMode {
            expanded = false
            pointerInside = false
            hudTask?.cancel(); hud = nil
            paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1
        }
        updateInteraction(scheduleHover: false)
    }

    // MARK: Compact activities

    private var mediaStepsAside: Bool { media?.stepsAside(forFrontApp: frontApp) == true }
    var hasDualActivities: Bool { preferences?.mediaEnabled == true && media?.source != nil && !mediaStepsAside && countdown.active }
    var compactLeadingTab: IslandTab { hasDualActivities ? .music : compactTab }
    var compactTrailingTab: IslandTab { countdown.active || clock.active ? .timer : compactTab }
    /// Two things at once, like the iPhone: media keeps the island and the timer moves to a bubble beside it.
    var showsActivityBubble: Bool { presentation == .compact && hasDualActivities && hud == nil }
    var bubbleFrame: CGRect? {
        guard showsActivityBubble, let frame = surfaceFrame else { return nil }
        let side = layout.compactSize.height
        return CGRect(x: frame.maxX + IslandLayout.bubbleGap, y: frame.maxY - side, width: side, height: side)
    }
    /// A small swell under the pointer says the compact island can be clicked.
    var hoverSwell: Bool { pointerInside && !expanded && presentation == .compact }
    /// Whether a section is offered. The first one is the island's home and always is; whatever is running
    /// stays reachable even with its section off, so a timer you started can still be stopped.
    func shows(_ tab: IslandTab) -> Bool {
        return switch tab {
        case .music: true
        case .files: preferences?.showFiles != false
        case .clipboard: preferences?.showClipboard != false
        case .timer: countdown.active || clock.active || clock.alarmDate != nil || preferences?.showClock != false
        case .battery: preferences?.showControls != false
        case .transfers: transfers.hasRunning || !activities.running.isEmpty || preferences?.liveTransfers == true || selectedTab == .transfers
        }
    }
    var visibleTabs: [IslandTab] {
        [.music, .files, .clipboard, .timer, .battery, .transfers].filter(shows)
    }
    /// Shelf files and clipboard pins are kept while their section is off, just not shown.
    var shelfHasFiles: Bool { shows(.files) && !shelf.files.isEmpty }
    var clipboardHasPins: Bool { shows(.clipboard) && !clipboard.pins.isEmpty }
    /// What a plain open shows: the activity under the pointer, otherwise whatever is happening now.
    private func contextTab(at location: CGPoint? = nil) -> IslandTab {
        if let location, bubbleFrame?.contains(location) == true { return .timer }
        return compactLeadingTab
    }
    /// Opens the island at what's happening now, rather than wherever it was last left.
    func openInContext() {
        guard !presentationMode else { return }
        if !expanded { selectedTab = contextTab() }
        openFromMenu()
    }
    /// Shows the camera/microphone dot only when the user asked for it.
    var sensorIndicatorVisible: Bool { preferences?.sensorIndicator == true && sensors.active }
    func openCompactActivity(_ tab: IslandTab) {
        guard !presentationMode, !recentlyForceClicked else { return }
        feedbackTask?.cancel(); feedback = nil
        selectedTab = tab; openFromMenu()
    }

    // MARK: Desktop transitions

    private(set) var transitionPhase = DesktopTransitionPhase.settled
    var desktopTransition: Bool { transitionPhase == .hidden }
    var preparingAfterTransition: Bool { transitionPhase == .preparing }
    /// True while hiding or before reappearing: the island must stay out of the way.
    private var transitioning: Bool { transitionPhase == .hidden || transitionPhase == .preparing }
    var surfaceAnimationsSuppressed: Bool { transitionPhase != .settled }
    private let transitionMonitor = DesktopTransitionMonitor()
    private var systemSwitcherActive = false
    private var brimSwitcherActive = false
    private var switcherOverlayActive: Bool { systemSwitcherActive || brimSwitcherActive }
    private var desktopRestoreTask: Task<Void, Never>?
    private var desktopRestoreGate = DesktopRestoreGate()
    private var lastScreenPreferences: [Bool]?
    var panelFrame: CGRect? { panel?.frame }
    var spaceSlideCount: Int { transitionMonitor.spaceSlideCount }
    var trackpadDeviceCount: Int { transitionMonitor.trackpadDeviceCount }
    var observedContactGestures: Int { transitionMonitor.observedContactGestures }
    var transitionDiagnostics: [String: Bool] {
        ["systemOverlay": systemSwitcherActive, "brimSwitcher": brimSwitcherActive,
         "transition": desktopTransition, "suspended": suspended, "panelVisible": panel?.isVisible ?? false]
    }
    var presentation: IslandPresentation {
        if transitioning || presentationMode { return .hidden }
        if expanded { return .expanded }
        if fileDragActive || transfers.hasRunning || !activities.running.isEmpty || shelfHasFiles || clipboardHasPins || countdown.active
            || clock.active || media?.sleepTimer.schedule != nil || hud != nil { return .compact }
        return .resolve(expanded: expanded, mediaEnabled: preferences?.mediaEnabled == true,
                        playing: mediaVisible, hasSource: media?.source != nil, hasFeedback: feedback != nil)
    }
    /// Feedback that's only words: pictures and accessory cards still get the full island.
    var showsNotice: Bool { expanded && feedback != nil && feedbackImage == nil && feedbackDevice == nil }
    var compactTab: IslandTab {
        if countdown.active || clock.active { return .timer }
        if transfers.hasRunning || !activities.running.isEmpty { return .transfers }
        if selectedTab == .files && shelfHasFiles { return .files }
        if selectedTab == .clipboard && clipboardHasPins { return .clipboard }
        if preferences?.mediaEnabled == true && mediaVisible { return .music }
        if shelfHasFiles { return .files }
        if clipboardHasPins { return .clipboard }
        return .music
    }
    var surfaceFrame: CGRect? {
        guard presentation != .hidden, let displayFrame else { return nil }
        return layout.frame(on: displayFrame, expanded: expanded, notice: showsNotice)
    }
    var ignoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }

    // MARK: Lifecycle

    func start(preferences: Preferences, status: SystemStatus, media: MediaService, onOpenSettings: @escaping () -> Void = {}) {
        self.preferences = preferences; self.status = status; self.media = media; self.onOpenSettings = onOpenSettings
        status.onPowerSample = { [weak self] sample in self?.receivePower(sample) }
        status.onVolumeChange = { [weak self] volume, muted in self?.receiveVolume(volume, muted: muted) }
        receivePower(PowerSample(percent: status.battery, externalPower: status.charging))
        configureCallbacks()
        // The scrubber needs per-second positions only while it's on screen; compact needs track changes.
        media.wantsFrequentUpdates = { [weak self] in self?.expanded == true && self?.displayedTab == .music }
        if observers.isEmpty { installObservers() }
        let screenPreferences = [preferences.showOnExternal, preferences.followActiveDisplay]
        if panel == nil || lastScreenPreferences != screenPreferences { rebuild() }
        lastScreenPreferences = screenPreferences
        transitionMonitor.start { [weak self] active in
            self?.setSystemSwitcherActive(active)
        }
        if preferences.calendarPreview { calendar.start() } else { calendar.stop() }
        shelf.actions.transfers = transfers
        if preferences.liveTransfers { transfers.start() } else { transfers.stop() }
        if preferences.clipboardHistory && shows(.clipboard) { clipboard.startHistory() } else { clipboard.stopHistory() }
        if preferences.screenshotShelf && shows(.files) { screenshots.start() } else { screenshots.stop() }
        if preferences.sensorIndicator { sensors.start() } else { sensors.stop() }
        if preferences.systemHUD { brightness.start() } else { brightness.stop() }
        if preferences.bluetoothBatteries { bluetooth.start() } else { bluetooth.stop() }
        if preferences.systemChanges { moments.start { [weak self] moment in self?.receive(moment) } } else { moments.stop() }
        configureShelfPersistence(preferences.keepShelf)
        syncMediaVisibility()
        if !observingActivity { observingActivity = true; observeActivity() }
        updateInteraction(scheduleHover: false)
    }
    private func configureCallbacks() {
        clock.wantsFineTicks = { [weak self] in self?.expanded == true && self?.displayedTab == .timer }
        clock.onAlarm = { [weak self] in
            guard let self else { return }
            self.selectedTab = .timer
            self.haptic(.finish)
            self.showFeedback("Alarm", symbol: "alarm.fill", tint: .orange)
        }
        countdown.onFinish = { [weak self] in
            guard let self else { return }
            let focus = self.countdown.focus
            self.selectedTab = .timer
            self.clock.mode = focus == nil ? .timer : .focus
            self.haptic(.finish)
            self.showFeedback(self.countdown.finishedTitle, symbol: focus == nil ? "timer" : "brain.head.profile",
                              tint: focus.map { $0.phase == .focus ? Color.red : .green } ?? .orange)
            if AppEnvironment.allowsAlerts {
                if let sound = NSSound(named: focus == nil ? "Glass" : "Hero") { sound.play() } else { NSSound.beep() }
            }
        }
        screenshots.onScreenshot = { [weak self] url in self?.receiveScreenshot(url) }
        calendar.onSoon = { [weak self] event in
            let action = event.meetingURL.map { (title: String(localized: "Join"), url: $0) }
            self?.showFeedback(String(localized: "\(event.title) · \(event.relative(at: Date()))"), symbol: "calendar", tint: .red, action: action, seconds: action == nil ? 5 : 8)
        }
        transfers.onFinished = { [weak self] activity in self?.transferFinished(activity) }
        sensors.onChange = { [weak self] camera, microphone in self?.sensorsChanged(camera: camera, microphone: microphone) }
        brightness.onChange = { [weak self] level in
            self?.brightnessControl.receive(level)
            self?.showHUD(.init(symbol: NotchController.brightnessSymbol(level), level: level, label: String(localized: "Brightness")))
        }
        bluetooth.onConnected = { [weak self] device in self?.deviceConnected(device) }
        status?.onOutputChange = { [weak self] output in self?.outputChanged(output) }
        activities.onFinish = { [weak self] activity in
            self?.haptic(.finish)
            self?.showFeedback(activity.title, symbol: "checkmark.circle.fill", tint: .green, seconds: 2.5)
        }
    }
    private func installObservers() {
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
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.transitionMonitor.spaceDidChange()
                self?.hideForDesktopTransition(settleDelay: .milliseconds(900))
            }
        })
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = activated?.bundleIdentifier
            Task { @MainActor in self?.frontApp = bundle }
            guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                guard let self, !self.transitioning else { return }
                // Switching ordinary apps must not retract/recreate the camera cover.
                // Space gestures and the actual switcher own suppression separately.
                if self.expanded { self.setExpanded(false) }
                self.followActiveDisplayIfNeeded()
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
        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .swipe, .scrollWheel]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click outside the island (in another app) dismisses it.
                if event.type == .leftMouseDown || event.type == .rightMouseDown, self.clickDismisses(at: NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
                self.trackMouseEvent(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if event.type == .scrollWheel, self.handleScroll(event, at: location) { return true }
                self.trackMouseEvent(event)
                if event.type == .leftMouseDown || event.type == .rightMouseDown, self.clickDismisses(at: location) { self.setExpanded(false) }
                return false
            }
            return used ? nil : event
        }
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
            MainActor.assumeIsolated { self?.receivePressure(event) }
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
    private func clickDismisses(at location: CGPoint) -> Bool {
        expanded && !shelf.systemUIActive && systemMenuDepth == 0 && !containsPointer(location)
    }
    private func observeActivity() {
        let generation = observationGeneration
        withObservationTracking {
            _ = preferences?.mediaEnabled
            _ = media?.playing
            _ = media?.source
            _ = media?.sleepTimer.schedule
            _ = media?.holdingScrubber
            _ = frontApp
            _ = shelf.files
            _ = shelf.systemUIActive
            _ = clipboard.pins
            _ = transfers.running
            _ = activities.running
            _ = countdown.state
            _ = clock.stopwatch.running
            _ = clock.ringing
            _ = hud
            _ = preferences?.chargingFeedback
            _ = preferences?.chargeTarget
            _ = preferences?.lowBatteryAlert
            _ = preferences?.openWhenIdle
            _ = preferences?.showFiles
            _ = preferences?.showClipboard
            _ = preferences?.showClock
            _ = preferences?.showControls
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observingActivity, self.observationGeneration == generation else { return }
                if let status = self.status { self.receivePower(PowerSample(percent: status.battery, externalPower: status.charging)) }
                self.syncMediaVisibility()
                // An activity appearing under a still pointer isn't the pointer coming to rest on it.
                self.updateInteraction(scheduleHover: false)
                if !self.shelf.systemUIActive && self.expanded && !self.pointerInside { self.collapseAfterDelay() }
                self.observeActivity()
            }
        }
    }
    private func syncMediaVisibility() {
        let input = MediaVisibilityInput(enabled: preferences?.mediaEnabled == true, playing: media?.playing == true, hasSource: media?.source != nil, stepsAside: mediaStepsAside)
        guard input != lastMediaInput else { return }
        lastMediaInput = input
        mediaExitTask?.cancel()
        guard preferences?.mediaEnabled == true, media?.source != nil, !mediaStepsAside else { mediaVisible = false; return }
        if media?.playing == true { mediaVisible = true; return }
        // A short pause grace prevents track changes from flashing the physical cutout.
        mediaExitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.mediaVisible = false; self?.updateInteraction(scheduleHover: false)
        }
    }
    func containsPointer(_ point: CGPoint) -> Bool {
        if presentation == .hidden {
            guard !desktopTransition, !presentationMode, preferences?.openWhenIdle != false, let displayFrame else { return false }
            return layout.idleHoverFrame(on: displayFrame).contains(point)
        }
        if let bubble = bubbleFrame, IslandHitRegion.contains(point, frame: bubble, radius: bubble.height / 2, roundedTop: true) { return true }
        guard let frame = surfaceFrame else { return false }
        return IslandHitRegion.contains(point, frame: frame, radius: expanded ? 34 : layout.compactSize.height / 2, roundedTop: !layout.hasHardwareNotch)
    }
    private func syncPanelVisibility() {
        guard let panel else { return }
        if suspended || presentationMode || transitioning {
            idleHideTask?.cancel(); idleHideTask = nil
            panel.alphaValue = 0; panel.orderOut(nil)
        } else if presentation != .hidden {
            idleHideTask?.cancel(); idleHideTask = nil
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        } else if panel.isVisible && idleHideTask == nil {
            // Finish the opaque 180 ms retraction, then remove the unnecessary software camera cover.
            idleHideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self, self.presentation == .hidden else { return }
                self.panel?.orderOut(nil); self.idleHideTask = nil
            }
        }
    }
    func updateInteraction(scheduleHover: Bool = true, at location: CGPoint? = nil) {
        syncPanelVisibility()
        guard let panel else { return }
        let point = location ?? previewPointer ?? NSEvent.mouseLocation
        let inside = !suspended && !presentationMode && !transitioning && containsPointer(point)
        if !inside { hoverIntent.left() }
        // The window never resizes. Transparent space outside the animated surface passes through.
        panel.ignoresMouseEvents = presentation == .hidden || !inside
        if scheduleHover && (inside != pointerInside || (inside && !expanded)) { hover(inside, at: point) }
        else { pointerInside = inside }
    }
    func stop() {
        screenshots.stop(); clipboard.stopHistory(); calendar.stop(); transfers.stop()
        sensors.stop(); brightness.stop(); bluetooth.stop(); moments.stop(); activities.clear()
        toolOpenTask?.cancel(); toolOpenTask = nil; keys.stop()
        idleHideTask?.cancel(); idleHideTask = nil
        shelf.actions.closePreview()
        systemMenuDepth = 0
        observingActivity = false; observationGeneration += 1
        transitionMonitor.stop(); systemSwitcherActive = false; brimSwitcherActive = false
        desktopRestoreTask?.cancel(); desktopRestoreTask = nil; desktopRestoreGate.reset()
        transitionPhase = .settled; surfaceReveal = 1
        paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1
        mediaExitTask?.cancel(); mediaVisible = false; lastMediaInput = nil
        dragPollTimer?.invalidate(); dragPollTimer = nil; fileDragActive = false; dropTargeted = false
        collapseTask?.cancel(); hoverTask?.cancel(); feedbackTask?.cancel(); hudTask?.cancel(); hud = nil
        panel?.orderOut(nil); panel = nil; displayFrame = nil
        expanded = false; pointerInside = false; suspended = false; feedback = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        keyMonitor = nil; globalMouseMonitor = nil; localMouseMonitor = nil; pressureMonitor = nil
    }

    // MARK: Panel

    /// The notched built-in display by default. With "Show on displays without a notch", the main display,
    /// or — when following the active display — whichever display holds the frontmost window.
    private func targetScreen() -> NSScreen? {
        guard let preferences else { return nil }
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard preferences.showOnExternal else { return notched }
        if preferences.followActiveDisplay, NSScreen.screens.count > 1, let active = ActiveDisplay.current() { return active }
        return notched ?? NSScreen.main
    }
    private func followActiveDisplayIfNeeded() {
        guard preferences?.showOnExternal == true, preferences?.followActiveDisplay == true, NSScreen.screens.count > 1,
              !expanded, let screen = targetScreen(), screen.frame != displayFrame else { return }
        Log.island.debug("Moving the island to the active display")
        rebuild()
    }
    func rebuild() {
        idleHideTask?.cancel(); idleHideTask = nil
        panel?.orderOut(nil); panel = nil; expanded = false; pointerInside = false
        guard let preferences, let status, let media, preferences.notchEnabled, let screen = targetScreen() else { return }
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
        // Clicking into the island (say, the clipboard search field) gives typing back to the panel.
        if let panelKeyObserver { NotificationCenter.default.removeObserver(panelKeyObserver) }
        panelKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keys.stop() }
        }
        let hosting = NSHostingView(rootView: IslandView(controller: self, preferences: preferences, status: status, media: media))
        // SwiftUI's intrinsic minimum must not enlarge the collapsed NSPanel.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(layout.frame(on: screen.frame, expanded: true), display: true)
        updateInteraction(scheduleHover: false)
    }
    func setExpanded(_ value: Bool) {
        collapseTask?.cancel(); hoverTask?.cancel(); hoverTask = nil
        guard panel != nil, !(transitioning || presentationMode) || !value, value != expanded else { return }
        // One SwiftUI animation owns the shape, content and opacity. No NSWindow animator or I/O here.
        if !value { paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1 }
        if value { hudTask?.cancel(); hud = nil }
        // A section that was turned off can't be opened; go to what's happening instead.
        if value && !visibleTabs.contains(selectedTab) { selectedTab = contextTab() }
        if !value { hoverIntent.spend() }
        expanded = value
        updateInteraction(scheduleHover: false)
    }
    func hover(_ inside: Bool, at point: CGPoint? = nil) {
        pointerInside = inside
        collapseTask?.cancel()
        guard inside else {
            hoverTask?.cancel(); hoverTask = nil
            if expanded { collapseAfterDelay() }
            return
        }
        // A held button means a selection or a dragged tab that happens to pass by, not a pause on the island.
        guard !presentationMode, !transitioning, !suspended, preferences?.hoverToExpand == true, !expanded, NSEvent.pressedMouseButtons == 0 else {
            hoverTask?.cancel(); hoverTask = nil
            return
        }
        guard hoverIntent.moved(to: point ?? previewPointer ?? NSEvent.mouseLocation) else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: HoverIntent.dwell)
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            if !self.expanded { self.selectedTab = self.contextTab(at: self.previewPointer ?? NSEvent.mouseLocation) }
            self.setExpanded(true)
        }
    }
    private func collapseAfterDelay(seconds: Double = 0.06) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.pointerInside, !self.dropTargeted, !self.shelf.systemUIActive,
                  self.media?.holdingScrubber != true, self.systemMenuDepth == 0 else { return }
            self.setExpanded(false)
        }
    }
    func setSwitcherOverlayActive(_ active: Bool) {
        guard brimSwitcherActive != active else { return }
        brimSwitcherActive = active
        hideForDesktopTransition()
    }
    private func setSystemSwitcherActive(_ active: Bool) {
        systemSwitcherActive = active
        hideForDesktopTransition(settleDelay: active ? .milliseconds(350) : .milliseconds(300))
#if DEBUG
        if active {
            smoke.systemSwitcherObserved = true
            smoke.systemSwitcherHidIsland = desktopTransition && panel?.isVisible == false
        }
#endif
    }
    /// Native transient behavior excludes the panel from Mission Control. Hide immediately for
    /// observable swipe/Space/app changes too, then restore at the physical camera after settling.
    func hideForDesktopTransition(settleDelay: Duration = .milliseconds(350)) {
        desktopRestoreTask?.cancel(); collapseTask?.cancel()
        hoverTask?.cancel(); hoverTask = nil
        paneTask?.cancel(); displayedTab = selectedTab; paneOpacity = 1
        surfaceReveal = 0
        transitionPhase = .hidden
        expanded = false; pointerInside = false
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
            self.transitionPhase = .preparing
            self.followActiveDisplayIfNeeded()
            self.panel?.contentView?.layoutSubtreeIfNeeded()
            self.panel?.contentView?.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(34))
            guard !Task.isCancelled, !self.switcherOverlayActive, self.transitionPhase == .preparing else { return }
            self.transitionPhase = .revealing
            self.updateInteraction(scheduleHover: false)
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self.transitionPhase = .settled
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)) { self.surfaceReveal = 1 }
        }
    }

    // MARK: Pointer and drags

    private func trackMouseEvent(_ event: NSEvent) {
        guard systemMenuDepth == 0 else { return }
        let horizontalSwipe = event.type == .scrollWheel && !containsPointer(NSEvent.mouseLocation) && event.hasPreciseScrollingDeltas
            && abs(event.scrollingDeltaX) > 3 && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
        if event.type == .swipe || horizontalSwipe {
            hideForDesktopTransition(); return
        }
        switch event.type {
        case .leftMouseDown:
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            startDragPolling()
            // With nothing on screen the panel lets clicks through, so a click on the bare notch is noticed here.
            if presentation == .hidden, containsPointer(NSEvent.mouseLocation) { openInContext() }
        case .leftMouseDragged: startDragPolling()
        case .leftMouseUp: endFileDrag()
        default: break
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
        guard shows(.files) else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragStartChangeCount,
              board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        if !fileDragActive { fileDragActive = true }
        updateInteraction(scheduleHover: false)
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
        guard !targeted || shows(clipboard ? .clipboard : .files) else { return }
        if targeted && !dropTargeted { haptic(.open); dropZone = .shelf }
        if targeted { dropIsFiles = !clipboard }
        dropTargeted = targeted
        if targeted { selectedTab = clipboard ? .clipboard : .files; setExpanded(true) }
        else if !pointerInside { collapseAfterDelay() }
    }
    func finishFileDrop(clipboard: Bool = false) {
        haptic(.land)
        dropTargeted = false; fileDragActive = false; selectedTab = clipboard ? .clipboard : .files
        // The shelf stays open only while hovered; retained references survive collapse and Space changes.
        updateInteraction(scheduleHover: false)
        if !pointerInside { collapseAfterDelay() }
    }

    /// Follows a file drag across the expanded island, so the half under the pointer lights up.
    func updateDropZone(x: CGFloat, width: CGFloat) {
        let zone = DropZone.at(x: x, width: width, airDropAvailable: dropIsFiles && airDropAvailable)
        if zone != dropZone { dropZone = zone; haptic(.open) }
    }
    /// Files dropped on the AirDrop half wait on the shelf too, then go straight to the AirDrop picker.
    func airDrop(_ providers: [NSItemProvider]) -> Bool {
        shelf.accept(providers) { [weak self] urls in
            guard let self else { return }
            self.shelf.select(Set(urls.map(\.standardizedFileURL)))
            self.shelf.actions.airDrop()
        }
    }

    // MARK: Gestures

    private var swipeTravel: CGFloat = 0
    private var swipeFired = false
    private var pressureStage = 0
    private var forceClickedAt: TimeInterval = -.infinity
    /// The click that ends a Force Click mustn't then also count as an ordinary click on the island.
    var recentlyForceClicked: Bool { ProcessInfo.processInfo.systemUptime - forceClickedAt < 0.8 }
    private var gesturesEnabled: Bool { preferences?.islandGestures == true && !expanded && presentation == .compact }
    /// Over the compact island, scrolling changes the volume and a sideways swipe skips tracks. Returns true when used.
    private func handleScroll(_ event: NSEvent, at location: CGPoint) -> Bool {
        guard gesturesEnabled, containsPointer(location) else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { swipeTravel = 0; swipeFired = false }
        // Momentum after the fingers lift would keep changing the volume; the gesture is what the fingers did.
        guard event.momentumPhase.isEmpty else { return true }
        let fingers = IslandGesture.fingers(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice)
        if abs(fingers.right) > abs(fingers.up) {
            guard event.hasPreciseScrollingDeltas, !swipeFired, let media, media.source != nil else { return true }
            swipeTravel += fingers.right
            if let command = IslandGesture.skip(rightTravel: swipeTravel) {
                swipeFired = true
                media.command(command)
                haptic(.land)
                showHUD(.init(symbol: command == "next track" ? "forward.fill" : "backward.fill", label: command == "next track" ? String(localized: "Next Track") : String(localized: "Previous Track")), seconds: 0.9)
            }
        } else if let status, status.volumeSettable, let volume = status.volume, fingers.up != 0 {
            let next = IslandGesture.volume(status.muted ? 0 : volume, up: fingers.up, precise: event.hasPreciseScrollingDeltas)
            status.setVolume(next)
            showHUD(.init(symbol: next == 0 ? "speaker.slash.fill" : next < 0.34 ? "speaker.wave.1.fill" : next < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                          level: next, label: String(localized: "Volume")))
        }
        return true
    }
    /// A Force Click on the compact island opens the quick controls, like a long press on iPhone.
    private func receivePressure(_ event: NSEvent) {
        defer { pressureStage = event.stage }
        guard event.stage == 2, pressureStage < 2, gesturesEnabled, containsPointer(NSEvent.mouseLocation) else { return }
        forceClickedAt = ProcessInfo.processInfo.systemUptime
        feedbackTask?.cancel(); clearFeedback()
        selectedTab = .battery
        setExpanded(true)
    }

    // MARK: Opening tools

    private var toolOpenTask: Task<Void, Never>?
    func openTool(_ tool: ToolShortcuts.Tool, fromKeyboard: Bool = false) {
        toolOpenTask?.cancel()
        toolOpenTask = Task { [weak self] in
            // A shortcut pressed mid-swipe opens the tool once the desktop settles.
            for _ in 0..<100 {
                guard !Task.isCancelled, let self, self.panel != nil, !self.presentationMode else { return }
                if !self.transitioning && !self.suspended {
                    switch tool {
                    case .island: self.openInContext()
                    case .nowPlaying: self.selectedTab = .music
                    case .files: self.selectedTab = .files
                    case .clipboard: self.selectedTab = .clipboard
                    case .clock: self.selectedTab = .timer
                    case .battery: self.selectedTab = .battery
                    case .transfers: self.selectedTab = .transfers
                    }
                    if tool != .island { self.openFromMenu() }
                    if fromKeyboard && self.expanded { self.startKeyboardSession() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: Keyboard

    /// Opened from the keyboard, the island takes ←, →, Return, Space and Escape until it closes, without
    /// activating Brim or taking focus from the app you're in.
    private let keys = IslandKeys()
    private var panelKeyObserver: NSObjectProtocol?
    private func startKeyboardSession() {
        collapseAfterDelay(seconds: 8)
        keys.start { [weak self] key in self?.receive(key) }
    }
    private func receive(_ key: IslandKeys.Key) {
        guard expanded else { keys.stop(); return }
        switch key {
        case .escape: setExpanded(false); return
        case .left, .right:
            let tabs = visibleTabs
            let index = tabs.firstIndex(of: selectedTab) ?? 0
            selectedTab = tabs[(index + (key == .right ? 1 : tabs.count - 1)) % tabs.count]
        case .return, .space:
            if displayedTab == .music, media?.source != nil { media?.command("playpause") }
        }
        collapseAfterDelay(seconds: 8)
    }
    func openTimerFromMenu() { selectedTab = .timer; openFromMenu() }
    func openTransfersFromMenu() { selectedTab = .transfers; openFromMenu() }
    func openBatteryFromMenu() { selectedTab = .battery; openFromMenu() }
    func openClipboardFromMenu() { selectedTab = .clipboard; openFromMenu() }
    func openShelfFromMenu() { shelfSelected = true; openFromMenu() }
    func openFromMenu() { setExpanded(true); collapseAfterDelay(seconds: 5) }
    func openSettings() { setExpanded(false); onOpenSettings() }
    func connectTransfers() { preferences?.liveTransfers = true; transfers.start() }
    func connectMedia() {
        preferences?.mediaEnabled = true
        media?.start()
    }
    func allowPlayerAccess() {
        preferences?.playerAccess = true
        media?.playerAccess = true
    }
    func startTimer(minutes: Double) {
        countdown.start(seconds: minutes * 60)
        clock.mode = .timer; selectedTab = .timer
        showHUD(.init(symbol: "timer", tint: .orange, label: String(localized: "Timer started")))
    }
    func startFocus() {
        countdown.startFocus()
        clock.mode = .focus; selectedTab = .timer
        showHUD(.init(symbol: "brain.head.profile", tint: .red, label: String(localized: "Focus started")))
    }
    func pinClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            shelf.add(urls); selectedTab = .files
        } else { clipboard.pin(); selectedTab = .clipboard }
        openFromMenu()
    }
    private func configureShelfPersistence(_ keep: Bool) {
        guard let defaults = AppEnvironment.persistentDefaults else { return }
        if keep, shelf.persistence == nil {
            shelf.restore(from: defaults)
            shelf.persistence = defaults
        } else if !keep, shelf.persistence != nil {
            shelf.persistence = nil
        }
        // Clipboard pins follow the same switch; turning it off deletes the saved copies.
        if keep, clipboard.persistence == nil, let store = ClipboardPinStore.standard {
            clipboard.restore(from: store)
            clipboard.persistence = store
        } else if !keep, clipboard.persistence != nil {
            clipboard.persistence = nil
        }
    }

    // MARK: System events

    private func transferFinished(_ activity: TransferActivity) {
        switch activity.state {
        case .finished:
            let text = switch activity.kind {
            case .airDropSend: activity.name
            case .airDropReceive: String(localized: "Received \(activity.name)")
            case .download: String(localized: "Downloaded \(activity.name)")
            }
            haptic(.finish)
            showFeedback(text, symbol: activity.symbol, tint: .blue, seconds: 3)
        case .failed(let message):
            Log.island.notice("Transfer failed: \(message, privacy: .private)")
            showFeedback(String(localized: "AirDrop didn’t finish"), symbol: "exclamationmark.circle", tint: .orange)
        case .running: break
        }
    }
    private func receivePower(_ sample: PowerSample) {
        guard let preferences else { return }
        let event = powerFeedback.receive(sample, target: preferences.chargeTarget, low: preferences.lowBatteryAlert)
        guard !AppEnvironment.isSmokeTest, !expanded, !fileDragActive, let event else { return }
        switch event {
        case .connected(let percent) where preferences.chargingFeedback:
            showHUD(.init(symbol: "battery.100percent.bolt", tint: .green, label: String(localized: "Charging"), battery: percent, charging: true), seconds: 3)
        case .targetReached(let target) where preferences.chargingFeedback:
            showHUD(.init(symbol: "battery.100percent", tint: .green, label: String(localized: "Target reached"), battery: target), seconds: 3)
        case .low(let percent):
            showHUD(.init(symbol: "battery.25percent", tint: .red, label: String(localized: "Battery low"), battery: percent), seconds: 5)
        default: break
        }
    }
    private func receiveVolume(_ volume: Double?, muted: Bool) {
        guard preferences?.systemHUD == true else { return }
        let level = muted ? 0 : (volume ?? 0)
        let symbol = muted || level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        showHUD(.init(symbol: symbol, level: volume == nil ? nil : level, label: muted ? String(localized: "Muted") : String(localized: "Volume")))
    }
    static func brightnessSymbol(_ level: Double) -> String { level < 0.5 ? "sun.min.fill" : "sun.max.fill" }
    /// Where sound is going now, as iPhone shows when you pick an AirPlay speaker. Bluetooth headphones get
    /// the accessory card instead, which says more.
    private func outputChanged(_ output: AudioOutput) {
        guard preferences?.systemChanges == true, !expanded, feedback == nil else { return }
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(output.transport)
        guard !(bluetooth && preferences?.bluetoothBatteries == true) else { return }
        showFeedback(String(localized: "Playing on \(output.name)"), symbol: output.symbol, tint: .white, seconds: 2.5)
    }
    private func receive(_ moment: SystemMoments.Moment) {
        guard preferences?.systemChanges == true else { return }
        switch moment {
        case .lowPower(let on): showHUD(.init(symbol: on ? "leaf.fill" : "leaf", tint: .yellow, label: on ? String(localized: "Low Power Mode On") : String(localized: "Low Power Mode Off")), seconds: 2)
        case .offline: showHUD(.init(symbol: "wifi.slash", tint: .orange, label: String(localized: "Offline")), seconds: 3)
        case .online: showHUD(.init(symbol: "wifi", tint: .green, label: String(localized: "Back Online")), seconds: 2)
        }
    }
    private func sensorsChanged(camera: Bool, microphone: Bool) {
        guard preferences?.sensorIndicator == true, camera || microphone else { return }
        let label = camera && microphone ? String(localized: "Camera and microphone in use") : camera ? String(localized: "Camera in use") : String(localized: "Microphone in use")
        showHUD(.init(symbol: camera ? "video.fill" : "mic.fill", tint: camera ? .green : .orange, label: label), seconds: 2.5)
    }
    private func deviceConnected(_ device: BluetoothDevice) {
        guard preferences?.bluetoothBatteries == true, device.level != nil else { return }
        haptic(.land)
        showFeedback(device.name, symbol: device.symbol, tint: .white, device: device, seconds: 4)
    }
    /// Shown compact and brief, as on iPhone. Brim learns only that a Focus is on, not which one.
    func focusChanged(on: Bool) {
        guard preferences?.focusFeedback == true else { return }
        showHUD(.init(symbol: on ? "moon.fill" : "moon", tint: .indigo, label: on ? String(localized: "Focus On") : String(localized: "Focus Off")), seconds: 2)
    }
    /// A new screenshot goes onto the file shelf and gets a brief preview, like the iPhone's corner thumbnail.
    func receiveScreenshot(_ url: URL) {
        guard preferences?.notchEnabled == true, preferences?.screenshotShelf == true, shows(.files) else { return }
        shelf.add([url]); shelf.select([url.standardizedFileURL])
        selectedTab = .files
        haptic(.land)
        showFeedback(String(localized: "Screenshot"), symbol: "camera.viewfinder", image: ScreenshotWatcher.thumbnail(for: url), url: url, seconds: 4)
    }

    // MARK: Feedback presentation

    func showFeedback(_ text: String, symbol: String, tint: Color = .green,
                      image: NSImage? = nil, url: URL? = nil, action: (title: String, url: URL)? = nil, device: BluetoothDevice? = nil, seconds: Double = 3) {
        guard preferences?.notchEnabled == true else { return }
        if preferences?.smallNotices == true, image == nil, action == nil, device == nil { showHUD(.init(symbol: symbol, tint: tint, label: text), seconds: seconds); return }
        feedbackTask?.cancel(); hudTask?.cancel(); hud = nil
        feedback = text; feedbackSymbol = symbol; feedbackTint = tint
        feedbackImage = image; feedbackURL = url; feedbackAction = action; feedbackDevice = device
        setExpanded(true)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.clearFeedback()
            if !self.pointerInside { self.setExpanded(false) }
        }
    }
    func dismissFeedback() {
        feedbackTask?.cancel()
        clearFeedback()
        if !pointerInside { setExpanded(false) }
    }
    private func clearFeedback() {
        feedback = nil; feedbackImage = nil; feedbackURL = nil; feedbackAction = nil; feedbackDevice = nil
    }
    /// The trackpad only plays this while a finger rests on it, so it's felt, never heard.
    enum Haptic { case open, land, finish }
    func haptic(_ kind: Haptic) {
        guard preferences?.haptics == true, AppEnvironment.allowsAlerts else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch kind {
        case .open: .alignment
        case .land: .generic
        case .finish: .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    /// Volume, brightness and privacy changes stay compact: they never open the island or take focus.
    func showHUD(_ value: IslandHUD, seconds: Double = 1.6) {
        guard preferences?.notchEnabled == true, !expanded, !presentationMode, !suspended else { return }
        hudTask?.cancel()
        hud = value
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
}
